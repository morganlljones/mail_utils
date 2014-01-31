#!/usr/bin/perl -w
#
use strict;
use Data::Dumper;

my $account;
if (defined $ARGV[0]) {
    $account = $ARGV[0];
} else {
    print "usage: $0 <account>";
    exit 1;
}

my %vols;
for (split /\n/, `echo "select id,path from volume;" | mysql zimbra`) {
    my ($id,$path) = split /\s+/;
    next if ($id eq "id");
    $vols{$id} = $path;
}

my $mailboxId = `zmprov getMailboxInfo $account|grep mailboxId|awk '{print \$2}'`;
if (!defined $mailboxId) {
    die "no such account $account?\n";
}

my $mboxgroup = $mailboxId % 100;

# zmprov getMailboxInfo returns a number regardless of the user's store.  Make sure the user is on this store:
my $verify_store = `echo "select id,comment from mailbox where id=$mailboxId" | mysql zimbra`;
my @verify_store = split /\n/, $verify_store;

if ($#verify_store > 1) {
    print "too many values were returned for id=$mailboxId from zimbra.mailbox database:\n";
    print $verify_store . "\n";
    exit 1;
} elsif ($#verify_store == 1) {
    my $verify_account = (split /\s+/, $verify_store[1])[1];
#    print "comparing /$account/ and /$verify_account/\n";
    if ($account ne $verify_account) {
	die "$account doesn't appear to be on this host\n";
    }
}

for (split /\n/,
	`echo "select id,mailbox_id,volume_id,mod_content,subject from mail_item where mailbox_id=$mailboxId and type!=1;" | mysql mboxgroup$mboxgroup`) {
    my ($id, $mailbox_id, $volume_id, $mod_content, $subject) = split /\s+/,$_,5;
    next if ($id eq "id");

    my $path;
    if ($volume_id ne "NULL") {
        my $num1 = $mailbox_id >> 12;
        my $num2 = $id >> 12;

        $path = $vols{$volume_id} . "/" . $num1 . "/" . $mailbox_id . "/msg/" . $num2 . "/" . $id . "-" . $mod_content . ".msg";
        print "$path,";
     } else {
        print "NULL,";
     }
     print "$id,$mailbox_id,$volume_id,$mod_content,";

     if (defined $path && -f $path) {
         print "Y,";
     } else {
         print "N,";
     }

     print "$subject\n";
}

