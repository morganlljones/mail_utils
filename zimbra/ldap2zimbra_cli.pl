#!/usr/bin/perl -w
#

# Author: Morgan Jones (morgan@morganjones.org)
# Id:     $Id$
#
# Search an enterprise ldap and add/sync/delete users to a Zimbra
# infrastructure
#
# run as 'zimbra' user on one of the stores.
#
# One way sync: define attributes mastered by LDAP, sync them to
# Zimbra.  attributes mastered by Zimbra do not go to LDAP.


use strict;
use Getopt::Std;
use Net::LDAP;

sub print_usage();
sub get_z2l_map();
sub add_user($);
sub sync_user($$);
sub build_zu_h($);


my $opts;
getopts('h:D:w:b:ed:', \%$opts);

$|=1;

# these accounts will never be removed or modified
my @zimbra_special = qw/admin wiki spam* ham*/;


my $ldap_host = $opts->{h}     || print_usage();
my $ldap_base = $opts->{b}     || "dc=domain,dc=org";
my $binddn =    $opts->{D}     || "cn=Directory Manager";
my $bindpass =  $opts->{w}     || "pass";
my $zimbra_domain = $opts->{d} || "dmail02.domain.org";
my $zimbra_default_pass = $opts->{p} || "pass";
my $fil = "(objectclass=posixAccount)";


print "starting at ", `date`;
### keep track of accounts in ldap and added.
### search out every account in ldap.
my $ldap = Net::LDAP->new($ldap_host);
my $rslt = $ldap->bind($binddn, password => $bindpass);
$rslt->code && die "unable to bind as $binddn: $rslt->error";

print "searching out users $fil\n";
$rslt = $ldap->search(base => "$ldap_base", filter => $fil);
$rslt->code && die "problem with search $fil: ".$rslt->error;

for my $lusr ($rslt->entries) {
    my $usr = $lusr->get_value("uid");

    ### check for a corresponding zimbra account
    my $zmprov_ga_out = `zmprov ga $usr 2>&1`;

    if ($zmprov_ga_out =~ /ERROR: account.NO_SUCH_ACCOUNT/) {
	### if not, add	
	print "\nadding: ",$lusr->get_value("cn")," ($usr)\n";
	add_user($lusr);
    } elsif ($zmprov_ga_out =~ /^ERROR/) {
	print "Unexpected error on $usr, skipping: $zmprov_ga_out\n";
    }else {
	### if so, sync
	
	my $zu_h = build_zu_h($zmprov_ga_out);
	print "syncing ",$lusr->get_value("cn"),"\n";
	sync_user($zu_h, $lusr)
    }
}


### get a list of zimbra accounts, compare to ldap accounts, delete
### zimbra accounts no longer in in LDAP.


$rslt = $ldap->unbind;

print "finished at ", `date`;


######
# Build a hash ref of a user entry.
# lhs (left hand side):  attribute
# rhs (right hand side): list of values
sub build_zu_h($) {
    my $zmprov_ga = shift;

    my $h;

    my @a = split (/\n/, $zmprov_ga);

    map {
	if (/^[^:]+:[^:]+/) {
	    my ($lhs, $rhs) = split /:\s+/, $_;
	    push @{$h->{lc $lhs}}, $rhs;
	}
    } @a;

    return $h;
}

######
sub add_user($) {
    my $lu = shift;

    my $zmprov_cmd = "zmprov createAccount ". $lu->get_value("uid").
	"@" . $zimbra_domain . " $zimbra_default_pass ";

    my $z2l = get_z2l_map();
   
    for my $zattr (sort keys %$z2l) {
	$zmprov_cmd .= "$zattr ";
	$zmprov_cmd .= "\"".$lu->get_value($z2l->{$zattr}). "\" ";
    }

    print $zmprov_cmd . "\n";
    #system $zmprov_cmd;
}

######
sub sync_user($$) {
    my ($zu, $lu) = @_;

    my $z2l = get_z2l_map();

    my $zmprov_suffix;
    for my $zattr (sort keys %$z2l) {
	my $l_val_str = "";
	my $z_val_str = "";
	$l_val_str = join (' ', sort $lu->get_value($z2l->{$zattr}));
	$z_val_str = join (' ', sort @{$zu->{$zattr}}) 
	    unless !exists($zu->{$zattr});
# 	print "comparing: ($zattr) $z2l->{$zattr}\n".
# 	    "\t$z2l->{$zattr}: $l_val_str\n".
# 	    "\t$zattr: $z_val_str\n";
	if ($l_val_str ne $z_val_str) {
	    print "difference: ($zattr) $z2l->{$zattr}\n".
		"\t$z2l->{$zattr}: $l_val_str\n".
		"\t$zattr: $z_val_str\n";
	    map {
		$zmprov_suffix .= " " . $zattr . " " . $_
	    } $lu->get_value($z2l->{$zattr});
	}
    }
    
    if (defined $zmprov_suffix) {
	my $zmprov_ma = "zmprov ma ". shift(@{$zu->{mail}}) . $zmprov_suffix;
	print $zmprov_ma . "\n";
	#system $zmprov_ma;
    }
}



######
sub print_usage() {
    print "\n";
    print "usage: $0 [-h] [-e] <ldap host> [-b <basedn>] [-D <binddn>] ".
	"[-w <bindpass>] [-d <Zimbra domain>] [-p <default pass>]\n";
    print "\n";
    print "\toptions in [] are optional\n";
    print "\t-D <binddn> Must have unlimited sizelimit, lookthroughlimit\n".
	"\t\tnearly Directory Manager privilege to view users.\n";
    print "\t-e exhaustive search.  Search out all Zimbra users and delete\n".
	"\tany that are not in your enterprise ldap.  This is probably safe\n".
	"\tunless you have more than tens of thousands of users.\n";
    print "\n";
    print "example: $0 -h ldap.domain.com -b dc=domain,dc=com -w pass\n";
    print "\n";

    exit 0;
}




sub get_z2l_map() {
    # left (lhs):  zimbra ldap attribute
    # right (rhs): corresponding enterprise ldap attribute.
    # 
    # It's safe to duplicate attributes on rhs.

    return {
	"cn" =>                    "cn",
	"displayname" =>           "cn",
	"zimbrapreffromdisplay" => "cn",
	"sn" =>                    "sn",
        "givenname" =>             "givenname"
	};
}
    
    
