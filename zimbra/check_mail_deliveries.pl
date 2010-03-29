#!/usr/bin/perl -w
#
# name: check_mail_deliveries.pl


# description: parse a bizanga log for 2xx, 4xx and 5xx return codes
#     and report back on percentage of 4xx and 5xx to total deliveries
#     in a format in which Nagios can parse and notify.
# author: Morgan Jones (morgan@01.com)
# date: 3/26/10

# Designed to work on a combined log of all bizanga bizimp log entries
# sent through syslog.  It may work on logs written directly by the
# bizimp but that has not been tested.  If running on separate logs
# this would only need the smtpout log.

use strict;
use Getopt::Std;
require "timelocal.pl";

sub get_hostname($);
sub print_usage();
sub get_concise_time($);

my %opts;
getopts('f:p:dw:c:', \%opts);

my $filename = $opts{f} || print_usage();
my $time_period = $opts{p} || print_usage(); # start parsing $time_period 
    #minutes before the date of the last line line the log file.
my $warn_level = $opts{w} || 5;
my $critical_level = $opts{c} || 5;

if (exists $opts{d}) {
    print "-d used, printing debugging..\n\n";
    !exists $opts{w} && print "warn level not specified, ".
        "defaulting to ${warn_level}%\n";
    !exists $opts{c} && print "critical level not specified, ".
        "defaulting to ${critical_level}%\n";
    print "\n";
}

# keep track of deliveries, deferrals and refusals by domain.
my %deliver;
my %defer;
my %refuse;

my %mon2num = qw( Jan 0  Feb 1  Mar 2  Apr 3  May 4  Jun 5 Jul 6 Aug 7 Sep 8 
                  Oct 9 Nov 10 Dec 11 );

# get the last line of the log to know what time to start parsing.
my $last_line = `tail -1 $filename`;
print "last line: $last_line\n"
    if (exists $opts{d});

# format we're parsing: Mar 16 23:59:59
my ($mon, $day, $hour, $min, $sec) = 
    ($last_line =~ /([a-z]{3})\s(\d{2})\s(\d{2}):(\d{2}):(\d{2})/i);
my $year = (localtime(time()))[5] + 1900;
my $end_time = timelocal($sec, $min, $hour, $day, $mon2num{$mon}, $year);

my $start_time;

open IN, $filename || die "can't open $filename";

while (<IN>) {
    chomp;

    if (/IMP: smtpout/) {
        chomp;

        my ($l_mon, $l_day, $l_hour, $l_min, $l_sec) = 
            /([a-z]{3})\s(\d{2})\s(\d{2}):(\d{2}):(\d{2})/i;
        my $line_time = 
            timelocal($l_sec, $l_min, $l_hour, $l_day, $mon2num{$l_mon}, $year);

        # Skip log entries that aren't $time_period seconds from the
        # bottom of the log.
        next unless ($line_time > ($end_time - ($time_period * 60)));
        $start_time = $line_time unless defined $start_time;

        if (/smtp=[^:]+:([245]{1}[^\s]+)\s+/) {
            my $status = $1;
            
            my ($ip) = /dip=([^\s]+)\s/i;

            my $h = get_hostname($ip);
            next
                if ($h =~ /not found/i);
            $h =~ s/\.$//;
            chomp $h;
            my @h = split /\s/, $h;
            my @h2 = split /\./, $h[$#h];
            my $domain = join '.', $h2[$#h2-1], $h2[$#h2];
            if ($status =~ /^2/) {
                print "deliver, $domain: /$_/\n"
                    if (exists $opts{d});
                $deliver{lc $domain}++;
            } elsif ($status =~ /^4/) {
                print "defer, $domain: /$_/\n"
                    if (exists $opts{d});
                $defer{lc $domain}++;
            } elsif ($status =~ /^5/) {
                print "refuse, $domain: /$_/\n"
                    if (exists $opts{d});
                $refuse{lc $domain}++;
            }
        } else {
            # TODO?
            # Mar 16 00:00:21 dsmdc-mail-bxga4/dsmdc-mail-bxga4 IMP: smtpout 
            #   id=th0L1d00711nQh501h0Ly7 state="Sent" dip=74.125.113.27 dport=25
            # print "no delivery status: /$_/\n";
        }
    }
}

# http://nagiosplug.sourceforge.net/developer-guidelines.html#AEN33
my $rc = 0;
my $deferred;
my $refused;

for my $k (sort keys %defer) {
    my $total = $defer{$k};
    $total += $deliver{$k} if (exists $deliver{$k});
    $total += $refuse{$k}  if (exists $refuse{$k});

    my $per_deferred = sprintf "%.f", ($defer{$k} / $total) * 100;

    if ($per_deferred > 0) {
        $deferred .= " "
            unless (!defined $deferred);
        $deferred .= "$k=$per_deferred%";
    }

    $rc = 1 
        if (($per_deferred > $warn_level) && ($rc < 1));
}

for my $k (sort keys %refuse) {
    my $total = $refuse{$k};
    $total += $deliver{$k} if (exists $deliver{$k});
    $total += $defer{$k}  if (exists $defer{$k});

    my $per_refused = sprintf "%.f", ($refuse{$k} / $total) * 100;

    if ($per_refused > 0) {
        $refused .= " "
            unless (!defined $refused);
        $refused .= "$k=$per_refused%";
    }

    $rc = 2
        if (($per_refused > $critical_level) && ($rc < 2));
}

print "\n"
    if exists $opts{d};

if ($rc == 0) {
    print "OK";
} elsif ($rc == 1) {
    print "WARN";
} elsif ($rc == 2) {
    print "CRITICAL";
} else {
    print "UNKNOWN";
}

print " - " if (defined $refused || defined $deferred);

print get_concise_time($start_time), " to ", get_concise_time($end_time), " ";

if (defined $refused) {
    print "refused: $refused";
} 
if (defined $deferred) {
    print " - " if (defined $refused);
    print "deferred: $deferred";
}
print "\n";

exit $rc;

######
sub get_concise_time($) {
    my $t = shift;

    my @t = (localtime($t))[0..4];

    for my $v ((@t)[0..3]) {  # skip mon
        $v = "0".$v
            if ($v =~ /^\d{1}$/);
    }

    my ($sec, $min, $hour, $mday, $mon) = @t;
    $mon++;

    return $mon."/".$mday." ".$hour.":".$min.":".$sec;
}


######
{
    # maintain a local cache of ip address to host mappings so we
    # don't need to look up the same value twice.  Host name lookups
    # are the slowest part of this process.
    my %host_cache;

    sub get_hostname($) {
        my $ip = shift;
        
        my $h;
        if (!exists $host_cache{$ip}) {
            $h = (split /\n/, `host $ip`)[0];
            $host_cache{$ip} = $h;
        }
        return $host_cache{$ip};
    }
}

######
sub print_usage() {
    print "\n";
    print "usage: $0 [-d] -f <filename> -p <timeperiod> -w <\n";
    print "\t[-d] print debug output, optional\n";
    print "\t-f <filename> log filename to open\n";
    print "\t-p <timeperiod> time in minutes to begin parsing from bottom of log\n";
    print "\t-w <level> warn percent: only applies to deferrals\n";
    print "\t-c <level> critial percent: only applies to refusals\n";
    print "\n";
    
    exit;
}
