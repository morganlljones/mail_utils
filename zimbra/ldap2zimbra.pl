#!/usr/bin/perl -w
#
# Author: Morgan Jones (morgan@morganjones.org)
# Id:     $Id$
#
# Search an enterprise ldap and add/sync/delete users to a Zimbra
# infrastructure
#
# One way sync: define attributes mastered by LDAP, sync them to
# Zimbra.  attributes mastered by Zimbra do not go to LDAP.


# TODO: move and generalize get_z2l()
#       generalize build_zmailhost()
#       correct hacks.  Search in script for "hack."

##########
# examples
# 
# dev:
# ldap2zimbra.pl -n -w ldap-pass -m dev.domain.org -p zimbra-pass -z dmail01.domain.org
# 
# prod:
# ldap2zimbra.pl -n -s `cat /usr/local/users_in_zimbra.txt` -w ldap-pass -m domain.org -p zimbra-pass -z mail01.domain.org
# ldap2zimbra.pl -n -s `cat /usr/local/users_in_zimbra.txt` -w ldap-pass -m domain.org -p zimbra-pass -z mail01.domain.org




##################################################################
#### Site-specific settings
#
# The Zimbra SOAP libraries.  Download and uncompress the Zimbra
# source code to get them.
use lib "/usr/local/zcs-5.0.2_GA_1975-src/ZimbraServer/src/perl/soap";
# these accounts will never be added, removed or modified
#   It's a perl regex
my $zimbra_special = 
    '^admin|wiki|spam\.[a-z]+|ham\.[a-z]+|'. # Zimbra supplied
               # accounts. This will cause you trouble if you have users that 
               # start with ham or spam  For instance: ham.let.  Unlikely 
               # perhaps.
    'ser|'.
#    'mlehmann|gab|morgan|cferet|'.  
               # Steve, Matt, Gary, Feret and I
    'sjones|aharris|'.        # Gary's test users
    'hammy|spammy$';          # Spam training users 
# run case fixing algorithm (fix_case()) on these attrs.
#   Basically upcase after spaces and certain chars
my @z_attrs_2_fix_case = qw/cn displayname sn givenname/;

# attributes that will not be looked up in ldap when building z2l hash
# (see sub get_z2l() for more detail)
my @z2l_literals = qw/( )/;

# max delete recurse depth -- how deep should we go before giving up
# searching for users to delete:
# 5 == aaaaa*
my $max_recurse = 5;

# hostname for zimbra store.  It can be any of your stores.
# it can be overridden on the command line.
my $default_zimbra_svr = "dmail01.domain.org";
# zimbra admin password
my $default_zimbra_pass  = "pass";

# default domain, used every time a user is created and in some cases
# modified.  Can be overridden on the command line.
my $default_domain       = "dev.domain.org";

# default ldap settings, can be overridden on the command line
my $default_ldap_host    = "ldap0.domain.org";
my $default_ldap_base    = "dc=domain,dc=org";
my $default_ldap_bind_dn = "cn=Directory Manager";
my $default_ldap_pass    = "pass";
# my $default_ldap_filter = 
#     "(|(orghomeorgcd=9500)(orghomeorgcd=8020)(orghomeorgcd=5020))";
# my $default_ldap_filter = "(|(orghomeorgcd=9500)(orghomeorgcd=8020))";
#my $default_ldap_filter            = "(objectclass=posixAccount)";
my $default_ldap_filter            = 
    "(objectclass=orgZimbraPerson)";

#### End Site-specific settings
#############################################################




use strict;
use Getopt::Std;
use Net::LDAP;
use Data::Dumper;
use XmlElement;
use XmlDoc;
use Soap;
$|=1;

sub print_usage();
sub get_z2l();
sub add_user($);
sub sync_user($$);
sub get_z_user($);
sub fix_case($);
sub build_target_z_value($$);
sub delete_not_in_ldap();
sub delete_in_range($$$);
sub parse_and_del($);

my $opts;
getopts('hl:D:w:b:em:ndz:s:p:', \%$opts);

$opts->{h}                     && print_usage();
my $ldap_host = $opts->{l}     || $default_ldap_host;
my $ldap_base = $opts->{b}     || $default_ldap_base;
my $binddn =    $opts->{D}     || $default_ldap_bind_dn;
my $bindpass =  $opts->{w}     || $default_ldap_pass;
my $zimbra_svr = $opts->{z}    || $default_zimbra_svr;
my $zimbra_domain = $opts->{m} || $default_domain;
my $zimbra_pass = $opts->{p}   || $default_zimbra_pass;
my $subset_str = $opts->{s};

my $fil = $default_ldap_filter;

# url for zimbra store.  It can be any of your stores
# my $url = "https://dmail01.domain.org:7071/service/admin/soap/";
my $url = "https://" . $zimbra_svr . ":7071/service/admin/soap/";

my $ACCTNS = "urn:zimbraAdmin";
my $MAILNS = "urn:zimbraAdmin";
my $SOAP = $Soap::Soap12;

# has ref to store a list of users added/modified to extra users can
# be deleted from zimbra.
my $all_users;

my $subset;
if (defined $subset_str) {
    for my $u (split /\s*,\s*/, $subset_str) {$subset->{lc $u} = 0;}
    print "\nlimiting to subset of users:\n", join (', ', keys %$subset), "\n";
}


print "\nstarting at ", `date`;
### keep track of accounts in ldap and added.
### search out every account in ldap.

# bind to ldap
my $ldap = Net::LDAP->new($ldap_host);
my $rslt = $ldap->bind($binddn, password => $bindpass);
$rslt->code && die "unable to bind as $binddn: $rslt->error";

# authenticate to Zimbra admin url
my $d = new XmlDoc;
$d->start('AuthRequest', $ACCTNS);
$d->add('name', undef, undef, "admin");
$d->add('password', undef, undef, $zimbra_pass);
$d->end();

# get back an authResponse, authToken, sessionId & context.
my $authResponse = $SOAP->invoke($url, $d->root());
my $authToken = $authResponse->find_child('authToken')->content;
my $sessionId = $authResponse->find_child('sessionId')->content;
my $context = $SOAP->zimbraContext($authToken, $sessionId);

# search users out of ldap
print "searching out users $fil\n";
$rslt = $ldap->search(base => "$ldap_base", filter => $fil);
$rslt->code && die "problem with search $fil: ".$rslt->error;

# increment through users returned from ldap
print "\nadd/modify phase..\n";
for my $lusr ($rslt->entries) {
    my $usr = lc $lusr->get_value("uid");

    if (defined $subset_str) { next unless exists ($subset->{$usr}); }

    print "\nworking on $usr..\n" if exists $opts->{d};

    $all_users->{$usr} = 1;

    # skip special users
    if ($usr =~ /$zimbra_special/) {
	print "skipping special user $usr\n"
	    if (exists $opts->{d});
	next;
    }

    ### check for a corresponding zimbra account
    my $zu_h = get_z_user($usr);

    if (!defined $zu_h) {
 	add_user($lusr);
    } else {
 	sync_user($zu_h, $lusr)
    }
}

if (exists $opts->{e}) {
    print "\ndelete phase..\n";
    delete_not_in_ldap();
} else {
    print "\ndelete phase skipped (enable with -e)\n";
}


### get a list of zimbra accounts, compare to ldap accounts, delete
### zimbra accounts no longer in in LDAP.

$rslt = $ldap->unbind;

print "finished at ", `date`;



######
sub add_user($) {
    my $lu = shift;

    print "\nadding: ", $lu->get_value("uid"), ", ",
        $lu->get_value("cn"), "\n";

    my $z2l = get_z2l();

    # org hack
    unless (defined build_target_z_value($lu, "orgghrsintemplidno")) {
	print "\t***no orgghrsintemplidno, not adding.\n";
	return;
    }

    my $d = new XmlDoc;
    $d->start('CreateAccountRequest', $MAILNS);
    $d->add('name', $MAILNS, undef, $lu->get_value("uid")."@".$zimbra_domain);
    for my $zattr (sort keys %$z2l) {
	my $v = build_target_z_value($lu, $zattr);
	$d->add('a', $MAILNS, {"n" => $zattr}, $v);
    }
    $d->end();

    my $o;
    if (exists $opts->{d}) {
	print "here's what we're going to change:\n";
	$o = $d->to_string("pretty")."\n";
	$o =~ s/ns0\://g;
	print $o."\n";
    }

    my $r = $SOAP->invoke($url, $d->root(), $context)
	if (!exists $opts->{n});


    if (exists $opts->{d} && !exists $opts->{n}) {
	$o = $r->to_string("pretty");
	$o =~ s/ns0\://g;
	print $o."\n";
    }
}

######
sub sync_user($$) {
    my ($zu, $lu) = @_;

    my $z2l = get_z2l();

    my $d = new XmlDoc();
    $d->start('ModifyAccountRequest', $MAILNS);
    $d->add('id', $MAILNS, undef, (@{$zu->{zimbraid}})[0]);

    my $diff_found=0;

    for my $zattr (sort keys %$z2l) {
	my $l_val_str = "";
	my $z_val_str = "";

	if (!exists $zu->{$zattr}) {
	    $z_val_str = "";
	} else {
	    $z_val_str = join (' ', sort @{$zu->{$zattr}});
	}

	# build the values from ldap using zimbra capitalization
	$l_val_str = build_target_z_value($lu, $zattr);

	# too much noise with a lot of users
        # if (exists $opts->{d}) {
        #     print "comparing values for $zattr:\n".
	# 	"\tldap:   $l_val_str\n".
	# 	"\tzimbra: $z_val_str\n";
	# }

	if ($l_val_str ne $z_val_str) {
	    if (exists $opts->{d}) {
		print "different values for $zattr:\n".
		    "\tldap:   $l_val_str\n".
		    "\tzimbra: $z_val_str\n";
	    }

	    # org hack!
	    if ($zattr =~ /^\s*zimbramailhost\s*$/) {
		print "zimbraMailHost difference found! Skipping:\n".
		    "\tldap:   $l_val_str\n".
		    "\tzimbra: $z_val_str\n";
		next;
	    }


	    # if the values differ push the ldap version into Zimbra
	    $d->add('a', $MAILNS, {"n" => $zattr}, $l_val_str);
	    $diff_found++;
	}
    }

    $d->end();

    if ($diff_found) {

	print "\nsyncing ", $lu->get_value("uid"), ", ",
            $lu->get_value("cn"),"\n";

	my $o;
	print "changes:\n";
	$o = $d->to_string("pretty");
	$o =~ s/ns0\://g;
	print $o;

	if (!exists $opts->{n}) {
	    my $r = $SOAP->invoke($url, $d->root(), $context);

	    if (exists $opts->{d}) {
		print "response:\n";
		$o = $r->to_string("pretty");
		$o =~ s/ns0\://g;
		print $o."\n";
	    }
	}
    }
}



######
sub print_usage() {
    print "\n";
    print "usage: $0 [-n] [-d] [-e] [-h] -l <ldap host> -b <basedn>\n".
	"\t-D <binddn> -w <bindpass> -m <zimbra domain> -z zimbra host\n".
	"\t[-s \"user1,user2, .. usern\"] -p <zimbra admin user pass>\n";
    print "\n";
    print "\toptions in [] are optional, but all can have defaults\n".
	"\t(see script to set defaults)\n";
    print "\t-n print, don't make changes\n";
    print "\t-d debug\n";
    print "\t-e exhaustive search.  Search out all Zimbra users and delete\n".
	"\t\tany that are not in your enterprise ldap.  Steps have been \n".
	"\t\tto make this scale arbitrarily high.  It's been tested on \n".
	"\t\ttens of thousands successfully.\n";
    print "\t-h this usage\n";
    print "\t-D <binddn> Must have unlimited sizelimit, lookthroughlimit\n".
	"\t\tnearly Directory Manager privilege to view users.\n";
    print "\t-s \"user1, user2, .. usern\" provision a subset, useful for\n".
	"\t\tbuilding dev environments out of your production ldap or\n".
	"\t\tfixing a few users without going through all users\n".
	"\t\tIf you specify -e as well all other users will be deleted\n";
    print "\n";
    print "example: ".
	"$0 -l ldap.morganjones.org -b dc=morganjones,dc=org \\\n".
	"\t\t-D cn=directory\ manager -w pass -z zimbra.morganjones.org \\\n".
        "\t\t-m morganjones.org\n";
    print "\n";

    exit 0;
}


#######
sub get_z2l() {
    # left  (lhs): zimbra ldap attribute
    # right (rhs): corresponding enterprise ldap attribute.
    # 
    # It's safe to duplicate attributes on rhs.
    #
    # These need to be all be lower case
    #
    # You can use literals (like '(' or ')') but you need to identify
    # them in @z2l_literals at the top of the script.

    return {
	"cn" =>                    ["cn"],
	"zimbrapreffromdisplay" => ["givenname", "sn"],
        "givenname" =>             ["givenname"],
	"sn" =>                    ["sn"],
	"displayname" =>           ["givenname", "sn"],
		#		    "(", "orgoccupationalgroup", ")"],
	"zimbramailhost" =>        ["placeholder.."], # fix this, also hacked in
	                                              # build_target_z_value()
        "zimbramailcanonicaladdress" => ["placeholder.."]  # fix this too. 
    };

# A15 ULC-SHORT-NAME          /TELECOM & NTWRK/
#  Telecom & Ntwrk
}
    

sub build_zmailhost($) {
    my $org_id = shift;

    my @i = split //, $org_id;

    my $n = pop @i;

    if ($n =~ /^[01]{1}$/) {
	return "mail01.domain.org";
    } elsif ($n =~ /^[23]{1}$/) {
	return "mail02.domain.org";
    } elsif ($n =~ /^[45]{1}$/) {
	return "mail03.domain.org";
    } elsif ($n =~ /^[67]{1}$/) {
	return "mail04.domain.org";
    } elsif ($n =~ /^[89]{1}$/) {
	return "mail05.domain.org";
    }
}


#######
sub get_z_user($) {
    my $u = shift;

    my $ret = undef;
    my $d = new XmlDoc;
    $d->start('GetAccountRequest', $MAILNS); 
    { $d->add('account', $MAILNS, { "by" => "name" }, $u);} 
    $d->end();

    my $resp = $SOAP->invoke($url, $d->root(), $context);

    my $middle_child = $resp->find_child('account');
     #my $delivery_addr_element = $resp->find_child('zimbraMailDeliveryAddress');

    # user entries return a list of XmlElements
    return undef if !defined $middle_child;
    for my $child (@{$middle_child->children()}) {
	# TODO: check for multiple attrs.  The data structure allows
	#     it but I don't think it will ever happen.
	#print "content: " . $child->content() . "\n";
	#print "attrs: ". (values %{$child->attrs()})[0];
	# print ((values %{$child->attrs()})[0], ": ", $child->content(), "\n");
	push @{$ret->{lc ((values %{$child->attrs()})[0])}}, $child->content();
     }

     #my $acct_info = $response->find_child('account');

    return $ret;
}



######
sub fix_case($) {
    my $s = shift;

    # upcase the first character after each
    my $uc_after_exp = '\s\-\/\.&\'\(\)'; # exactly as you want it in [] 
                                      #   (char class) in regex
    # upcase these when they're standing alone
    my @uc_clusters = qw/hs hr ms es avts pd/;

    # upcase char after if a word starts with this
    my @uc_after_if_first = qw/mc/;


    # uc anything after $uc_after_exp characters
    $s = ucfirst(lc($s));
    my $work = $s;
    $s = '';
    while ($work =~ /[$uc_after_exp]+([a-z]{1})/) {
	$s = $s . $` . uc $&;

	my $s1 = $` . $&;
	# parentheses and asterisks confuse regexes if they're not escaped.
	#   we specifically use parenthesis and asterisks in the cn
	$s1 =~ s/([\*\(\)]{1})/\\$1/g;

	#$work =~ s/$`$&//;
	$work =~ s/$s1//;

    }
    $s .= $work;


    # uc anything in @uc_clusters
    for my $cl (@uc_clusters) {
	$s = join (' ', map ({
	    if (lc $_ eq lc $cl){
		uc($_);
	    } else {
		    $_;
	    } } split(/ /, $s)));
    }

    
    # uc anything after @uc_after_first
    for my $cl2 (@uc_after_if_first) {

	$s = join (' ', map ({ 
 	    if (lc $_ =~ /^$cl2([a-z]{1})/i) {

		
		my $pre =   ucfirst (lc $cl2);
		my $thing = uc $1;
		my $rest =  $_;
		$rest =~ s/$cl2$thing//i;
		$_ = $pre . $thing . $rest;
 	    } else {
 		$_;
 	    }}
 	    split(/ /, $s)));
	
    }

    return $s;
}


######
#sub build_value($$$) {
#    my ($type, $lu, $zattr) = @_;
sub build_target_z_value($$) {
    my ($lu, $zattr) = @_;
    
    my $z2l = get_z2l();

    # hacks to get through a deadline
    return build_zmailhost($lu->get_value("orgghrsintemplidno"))
	if ($zattr eq "zimbramailhost");

    return $lu->get_value("uid") . "\@domain.org"
	if ($zattr eq "zimbramailcanonicaladdress");
    
    my $ret = join ' ', (
	map {
    	    my @ldap_v;
	    my $v = $_;

	    map {
		if ($v eq $_) {
		    $ldap_v[0] = $v;
		}
	    } @z2l_literals;

	    if ($#ldap_v < 0) {
		@ldap_v = $lu->get_value($v);
		map { fix_case ($_) } @ldap_v;
	    } else {
		@ldap_v;
	    }

	} @{$z2l->{$zattr}}   # get the ldap side of z2l hash
    );

    # special case rule to remove space before after open parentheses
    # and after close parentheses.  I don't think there's a better
    # way/place to do this.
    $ret =~ s/\(\s+/\(/;
    $ret =~ s/\s+\)/\)/;
    # if just () remove.. another hack for now.
    $ret =~ s/\s*\(\)\s*//g;

    return $ret;
}


######
sub delete_not_in_ldap() {
    my $d = new XmlDoc;
    $d->start('SearchDirectoryRequest', $MAILNS,
	{'sortBy' => "uid",
	 'attrs'  => "uid",
	 'types'  => "accounts"}
    ); 
    { $d->add('query', $MAILNS, { "types" => "accounts" });} 
    $d->end();


    my $r = $SOAP->invoke($url, $d->root(), $context);

    if ($r->name eq "Fault") {
	# break down the search by alpha/numeric
	print "\tFault! ..recursing deeper to return fewer results.\n";
	delete_in_range(undef, "a", "z");
	return;
    }
    

    if ($r->name ne "account") {
	print "skipping delete, unknown record type returned: ", $r->name, "\n";
	return;
    }

    print "returned ", $r->num_children, " children\n";

    parse_and_del($r);
}



#######
# a, b, c, d, .. z
# a, aa, ab, ac .. az, ba, bb .. zz
# a, aa, aaa, aab, aac ... zzz
sub delete_in_range($$$) {
    my ($prfx, $beg, $end) = @_;

#     print "deleting ";
#     print "${beg}..${end} ";
#     print "w/ prfx $prfx " if (defined $prfx);
#     print "\n";

    for my $l (${beg}..${end}) {
	my $fil = 'uid=';
	$fil .= $prfx if (defined $prfx);
	$fil .= "${l}\*";

	print "searching $fil\n";
	my $d = new XmlDoc;
	$d->start('SearchDirectoryRequest', $MAILNS);
	$d->add('query', $MAILNS, undef, $fil);
	$d->end;
	
	my $r = $SOAP->invoke($url, $d->root(), $context);
# debugging:
# 	if ($r->name eq "Fault" || !defined $prfx || 
#	    scalar (split //, $prfx) < 6 ) {
 	if ($r->name eq "Fault") {
# 	    # TODO: limit recursion depth
	    print "\tFault! ..recursing deeper to return fewer results.\n";
	    my $prfx2pass = $l;
	    $prfx2pass = $prfx . $prfx2pass if defined $prfx;

	    increment_del_recurse();
	    if (get_del_recurse() > $max_recurse) {
		print "\tmax recursion ($max_recurse) hit, backing off..\n";
		decrement_del_recurse();
		return 1; #return failure so caller knows to return
			  #and not keep trying to recurse to this
			  #level

	    }
 	    my $rc = delete_in_range ($prfx2pass, $beg, $end);
	    decrement_del_recurse();
	    return if ($rc);  # should cause us to drop back one level
			      # in recursion
 	} else {

	    parse_and_del($r);

        }
    }
}



# static variable to limit recursion depth
BEGIN {
    my $del_recurse_counter = 0;

    sub increment_del_recurse() {
	$del_recurse_counter++;
    }

    sub decrement_del_recurse() {
	$del_recurse_counter--;
    }
    
    sub get_del_recurse() {
	return $del_recurse_counter;
    }
}


#######
sub parse_and_del($) {

    my $r = shift;

#    my $children = $r->children();

    for my $child (@{$r->children()}) {
	my ($uid, $z_id);

	for my $attr (@{$child->children}) {
  	    if ((values %{$attr->attrs()})[0] eq "uid") {
  		$uid = $attr->content();
 	    }
  	    if ((values %{$attr->attrs()})[0] eq "zimbraId") {
  		$z_id = $attr->content();
  	    }
 	}
 	if (defined $uid && defined $z_id && 
	    !exists $all_users->{$uid} && $uid !~ $zimbra_special) {
 	    print "deleting $uid, $z_id..\n";

 	    my $d = new XmlDoc;
 	    $d->start('DeleteAccountRequest', $MAILNS);
 	    $d->add('id', $MAILNS, undef, $z_id);
 	    $d->end();

 	    if (!exists $opts->{n}){
#		my $r = $SOAP->invoke($url, $d->root(), $context);

		if (exists $opts->{d}) {
		    my $o = $r->to_string("pretty");
		    $o =~ s/ns0\://g;
		    print $o."\n";
		}
	    }
	}
    }
}
    




# ModifyAccount example:
#
# <soap:Envelope xmlns:soap="http://www.w3.org/2003/05/soap-envelope">
#     <soap:Header>
#         <context xmlns="urn:zimbra">
#             <userAgent name="ZimbraWebClient - FF2.0 (Linux)"/>
#             <sessionId id="3106"/>
#             <authToken>
#                 0_b70de391fdcdf4b0178bd2ea98508fee7ad8f422_69643d33363a61383836393466312d656131662d346462372d613038612d3939313766383737313532623b6578703d31333a313139363333333131363139373b61646d696e3d313a313b747970653d363a7a696d6272613b
#             </authToken>
#             <format type="js"/>
#         </context>
#     </soap:Header>
#     <soap:Body>
#         <ModifyAccountRequest xmlns="urn:zimbraAdmin">
#             <id>
#                 a95351c1-7590-46e2-9532-de20f2c5a046
#             </id>
#             <a n="displayName">
#                 morgan jones (director of funny walks)
#             </a>
#         </ModifyAccountRequest>
#     </soap:Body>
# </soap:Envelope>



# CreateAccount example:
#
# <soap:Envelope xmlns:soap="http://www.w3.org/2003/05/soap-envelope">
#     <soap:Header>
#         <context xmlns="urn:zimbra">
#             <userAgent name="ZimbraWebClient - FF2.0 (Linux)"/>
#             <sessionId id="331"/>
#             <authToken>
#                 0_d34449e3f2af2cd49b7ece9fb6dd1e2153cc55b8_69643d33363a61383836393466312d656131662d346462372d613038612d3939313766383737313532623b6578703d31333a313139363232333436303236343b61646d696e3d313a313b747970653d363a7a696d6272613b
#             </authToken>
#             <format type="js"/>
#         </context>
#     </soap:Header>
#     <soap:Body>
#         <CreateAccountRequest xmlns="urn:zimbraAdmin">
#             <name>
#                 morgan03@dmail02.domain.org
#             </name>
#             <a n="zimbraAccountStatus">
#                 active
#             </a>
#             <a n="displayName">
#                 morgan jones
#             </a>
#             <a n="givenName">
#                 morgan
#             </a>$
#             <a n="sn">
#                 jones
#             </a>
#         </CreateAccountRequest>
#     </soap:Body>
# </soap:Envelope>



# GetAccount example:
#
# <soap:Envelope xmlns:soap="http://www.w3.org/2003/05/soap-envelope">
#     <soap:Header>
#         <context xmlns="urn:zimbra">
#             <userAgent name="ZimbraWebClient - FF2.0 (Linux)"/>
#             <sessionId id="325"/>
#             <authToken>
#                 0_d34449e3f2af2cd49b7ece9fb6dd1e2153cc55b8_69643d33363a61383836393466312d656131662d346462372d613038612d3939313766383737313532623b6578703d31333a313139363232333436303236343b61646d696e3d313a313b747970653d363a7a696d6272613b
#             </authToken>
#             <format type="js"/>
#         </context>
#     </soap:Header>
#     <soap:Body>
#         <GetAccountRequest xmlns="urn:zimbraAdmin" applyCos="0">
#             <account by="id">
#                 74faaafb-13db-40e4-bd0f-576069035521
#             </account>
#         </GetAccountRequest>
#     </soap:Body>
# </soap:Envelope>



# SearchDirectoryRequest for all users:
#
# <soap:Envelope xmlns:soap="http://www.w3.org/2003/05/soap-envelope">
#     <soap:Header>
#         <context xmlns="urn:zimbra">
#             <userAgent name="ZimbraWebClient - FF2.0 (Linux)"/>
#             <sessionId id="3481"/>
#             <authToken>
#                 0_8b41a60cf6a7dc8cb7c7e00fc66f939ce66cad5f_69643d33363a38373834623434372d346562332d343934342d626230662d6362373734303061303466653b6578703d31333a313139383930323638303831343b61646d696e3d313a313b747970653d363a7a696d6272613b
#             </authToken>
#             <format type="js"/>
#         </context>
#     </soap:Header>
#     <soap:Body>
#         <SearchDirectoryRequest xmlns="urn:zimbraAdmin" offset="0" limit="25" sortBy="name" sortAscending="1" attrs="displayName,zimbraId,zimbraMailHost,uid,zimbraAccountStatus,zimbraLastLogonTimestamp,description,zimbraMailStatus,zimbraCalResType,zimbraDomainType,zimbraDomainName" types="accounts">
#             <query/>
#         </SearchDirectoryRequest>
#     </soap:Body>
# </soap:Envelope>
#
#
# search directory request for a pattern:
# <soap:Envelope xmlns:soap="http://www.w3.org/2003/05/soap-envelope">
#     <soap:Header>
#         <context xmlns="urn:zimbra">
#             <userAgent name="ZimbraWebClient - FF2.0 (Linux)" version="undefined"/>
#             <sessionId id="277"/>
#             <authToken>
#                 0_93974500ed275ab35612e0a73d159fa8ba460f2a_69643d33363a30616261316231362d383364352d346663302d613432372d6130313737386164653032643b6578703d31333a313230363539303038353132383b61646d696e3d313a313b
#             </authToken>
#             <format type="js"/>
#         </context>
#     </soap:Header>
#     <soap:Body>
#         <SearchDirectoryRequest xmlns="urn:zimbraAdmin" offset="0" limit="25" sortBy="name" sortAscending="1" attrs="displayName,zimbraId,zimbraMailHost,uid,zimbraAccountStatus,description,zimbraMailStatus,zimbraCalResType,zimbraDomainType,zimbraDomainName" types="accounts">
#             <query>
#                 (|(uid=*morgan*)(cn=*morgan*)(sn=*morgan*)(gn=*morgan*)(displayName=*morgan*)(zimbraId=morgan)(mail=*morgan*)(zimbraMailAlias=*morgan*)(zimbraMailDeliveryAddress=*morgan*)(zimbraDomainName=*morgan*))
#             </query>
#         </SearchDirectoryRequest>
#     </soap:Body>
# </soap:Envelope>


# DeleteAccountRequest:
# <soap:Envelope xmlns:soap="http://www.w3.org/2003/05/soap-envelope">
#     <soap:Header>
#         <context xmlns="urn:zimbra">
#             <userAgent name="ZimbraWebClient - FF2.0 (Linux)"/>
#             <sessionId id="318864"/>
#             <format type="js"/>
#             <authToken>
#                 0_7b49e3d97c1a15ef72f5a0a344bfe417b82fc9a6_69643d33363a38323539616631392d313031302d343366392d613338382d6439393038363234393862623b6578703d31333a313230353830353735353338343b61646d696e3d313a313b747970653d363a7a696d6272613b6d61696c686f73743d31363a3137302e3233352e312e3234313a38303b
#             </authToken>
#         </context>
#     </soap:Header>
#     <soap:Body>
#         <DeleteAccountRequest xmlns="urn:zimbraAdmin">
#             <id>
#                 74c747fb-f209-475c-82c0-04fa09c5dedb
#             </id>
#         </DeleteAccountRequest>
#     </soap:Body>
# </soap:Envelope>


# search out all users in the store:
# <soap:Envelope xmlns:soap="http://www.w3.org/2003/05/soap-envelope">
#     <soap:Header>
#         <context xmlns="urn:zimbra">
#             <userAgent name="ZimbraWebClient - FF2.0 (Linux)"/>
#             <sessionId id="3174"/>
#             <format type="js"/>
#             <authToken>
#                 0_af79e67ac4da7ae8e7a298d97392b4f82bdd8f03_69643d33363a38323539616631392d313031302d343366392d613338382d6439393038363234393862623b6578703d31333a313230353931313737363633303b61646d696e3d313a313b747970653d363a7a696d6272613b6d61696c686f73743d31363a3137302e3233352e312e3234313a38303b
#             </authToken>
#         </context>
#     </soap:Header>
#     <soap:Body>
#         <SearchDirectoryRequest xmlns="urn:zimbraAdmin" offset="0" limit="25" sortBy="name" sortAscending="1" 
#         attrs="displayName,zimbraId,zimbraMailHost,uid,zimbraAccountStatus,zimbraLastLogonTimestamp,description,zimbraMailStatus,zimbraCalResType,zimbraDomainType,zimbraDomainName" types="accounts">
#             <query/>
#         </SearchDirectoryRequest>
#     </soap:Body>
# </soap:Envelope>
