#!/usr/bin/perl -w
#
# Copyright (c) 2011 Stéphane Urbanovski <stephane.urbanovski@ac-nancy-metz.fr>
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty
# of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# you should have received a copy of the GNU General Public License
# along with this program (or with Nagios);  if not, write to the
# Free Software Foundation, Inc., 59 Temple Place - Suite 330,
# Boston, MA 02111-1307, USA
#


use strict;
use warnings;

use POSIX qw(setlocale LC_TIME LC_MESSAGES strftime);
use Locale::gettext;

use File::Basename;			# get basename()
use Nagios::Plugin;

# use Sys::Hostname;
use Mail::IMAPClient;
use POSIX qw(strftime);

use Data::Dumper;


my $VERSION = '1.0';
my $TIMEOUT = 10;
my $PROGNAME = basename($0);

my $INBOX = 'INBOX';


# From DateTime::Format::Mail :
my $loose_RE = qr{
	\;\s*
    (?i:
        (?:Mon|Tue|Wed|Thu|Fri|Sat|Sun|[A-Z][a-z][a-z]) ,? # Day name + comma
    )?
        # (empirically optional)
    \s*
    (\d{1,2})  # day of month
    [-\s]*
    (?i: (Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec) ) # month
    [-\s]*
    ((?:\d\d)?\d\d) # year
    \s+
    (\d?\d):(\d?\d) (?: :(\d?\d) )? # time
    (?:
        \s+ "? (
            [+-] \d{4}  # standard form
            | [A-Z]+    # obsolete form (mostly ignored)
            | GMT [+-] \d+      # empirical (converted)
            | [A-Z]+\d+ # bizarre empirical (ignored)
            | [a-zA-Z/]+        # linux style (ignored)
            | [+-]{0,2} \d{3,5} # corrupted standard form
            ) "? # time zone (optional)
    )?
        (?: \s+ \([^\)]+\) )? # (friendly tz name; empirical)
    \s* \.? $
}x;


# i18n :
setlocale(LC_MESSAGES, '');
textdomain('nagios-plugins-perl');

# Don't use locale format for dates :
# setlocale(LC_TIME, 'C');

my $np = Nagios::Plugin->new(
	version => $VERSION,
	blurb => _gt('Nagios plugins to check imap server. This plugins also allow you to periodicaly check a mail previously sent by check_mail_pop.pl Nagios plugin.'),
	usage => "Usage: %s -H <imap host> -u <user> -p <password> [-t <timeout>] [ -c|--critical=<threshold> ] [ -w|--warning=<threshold> ]",
	timeout => $TIMEOUT+1,
	extra => &showExtra(),
);

$np->add_arg (
	spec => 'host|H=s',
	help => _gt('imap/imaps server.'),
	required => 1,
);
$np->add_arg (
	spec => 'user|u=s',
	help => _gt('Username'),
	required => 1,
);
$np->add_arg (
	spec => 'password|p=s',
	help => _gt('User password'),
	required => 1,
);
$np->add_arg (
	spec => 'port=i',
	help => _gt('Server port ( default to 143 for imap and 993 for imaps).'),
	required => 0,
	default => 0,
);
$np->add_arg (
	spec => 'proto|P=s',
	help => _gt('Protocol imap(default)/imaps/tls.'),
	default => 'auto',
	required => 0,
);
$np->add_arg (
	spec => 'key|k=s',
	help => _gt('Subject key to search (see check_mail_smtp.pl)'),
	required => 1,
);


$np->getopts;
my $verbose = $np->opts->verbose;

my $server = $np->opts->get('host');
my $user = $np->opts->get('user');
my $password = $np->opts->get('password');

my $port = $np->opts->get('port');
my $proto = $np->opts->get('proto');

my $key = $np->opts->get('key');


my $imap = Mail::IMAPClient->new();


$imap->Server($server);

if ( $proto eq 'imaps' ) {
	$imap->Ssl(1);
	$imap->Port(993);
}

# Used for date parsing :
my %months = do { my $i = 1;
	map { $_, $i++ } qw( Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec );
};


logD("Connecting to '$server' with protocol '$proto'...");
if ( !$imap->connect() ) {
	$np->nagios_exit(CRITICAL, sprintf(_gt('Failled to connect to \'%s\' : %s'),$server,$imap->LastError) );
}

if ( $proto eq 'imaps' ) {
	my $socket = $imap->Socket();
	my $error = &checkSSL($socket);
	if ( $error ne 'OK' ) {
		$np->nagios_exit(WARNING, sprintf(_gt('SSL checks failed : %s'),$error) );
	}
}


logD('Retrieving capabilities ...');
my $capabilities = $imap->capability;
if ( !$capabilities ) {
	$np->nagios_exit(CRITICAL, sprintf(_gt('Failled to get IMAP capabilities : %s'),$imap->LastError) );
}
logD('  Capabilities: '.join(',',@{$capabilities}));

my $canTLS = 0;
foreach my $cap (@{$capabilities}) {
	if ($cap eq 'STARTTLS') {
		$canTLS = 1;
		last;
	}
}
if ( $proto eq 'tls' ) {
	if ( $canTLS == 0 ) {
		$np->nagios_exit(CRITICAL, _gt('Server has no STARTTLS capabilitiy') );
	}
	if ( !$imap->starttls() ) {
		$np->nagios_exit(CRITICAL, sprintf(_gt('STARTTLS failed : %s'),imap->LastError) );
	}
}


logD("Login with user '$user' ...");
$imap->User($user);
$imap->Password($password);
if ( !$imap->login() ) {
	$np->nagios_exit(CRITICAL, sprintf(_gt("Enable to login with user '%s' : %s"),$user,$imap->LastError) );
}


my $msgcount = $imap->message_count($INBOX);
logD("  Found $msgcount messages in '$INBOX'");
if ( !$msgcount ) {
	$np->nagios_exit(CRITICAL, sprintf(_gt("Failled to get message count in folder '%s' for user '%s' : %s"),$INBOX,$user,$imap->LastError) );
}


if ( !$imap->select( $INBOX ) ) {
	$np->nagios_exit(CRITICAL, sprintf(_gt("Failled to select '%s' folder for user '%s' : %s"),$INBOX,$user,$imap->LastError) );
}

logD("Searching messages with '$key' key ...");
my $search = $imap->search('TEXT "'.$key.'"');
# print Dumper($search);

if ( @{$search} == 0 ) {
	$np->nagios_exit(CRITICAL, sprintf(_gt("No message with key '%s' found in folder '%s'"),$key,$INBOX) );
}

logD("  Found ".@{$search}." messages with '$key' key");



my @toDelete = ();
my $lastTimeSent = { 'TS' => -1};
my ($lastMsgId,$lastHeader) = (-1,undef);

foreach my $msgId ( @{$search}) {

	my $header = $imap->parse_headers($msgId,'Date','Received','Subject');
	
 	logD(sprintf ("MSG %7i : '%s'",$msgId,$header->{'Subject'}[0]) );
	if ($header->{'Subject'}[0] ne $key) {
		# not an exact match ...
		next;
	}
	
	if ( !defined($header->{'Date'}[0]) ) {
		logW('  Sent date not defined !');
		next;
	}
	logD('  Date: '.$header->{'Date'}[0]);
	my $timeSent = parseRFC2882Date(';'.$header->{'Date'}[0]);
	
	if ( !defined($timeSent) ) {
		logW('  Can\'t parse sent date: '.$header->{'Date'}[0]);
		next;		
	}
	logD('  Sent date: '.strftime('%F %T',$timeSent->{'S'},$timeSent->{'M'},$timeSent->{'H'},$timeSent->{'d'},$timeSent->{'m'}-1,$timeSent->{'Y'}-1900));
	
	if ( $timeSent->{'TS'} > $lastTimeSent->{'TS'} ) {
		$lastTimeSent = $timeSent;
		$lastMsgId = $msgId;
		$lastHeader = $header;
	}

	push(@toDelete, $msgId);
	
}

if ( !defined($lastHeader) ) {
	$np->nagios_exit(CRITICAL, _("No message using key '%s' found !"),$key);
}


my $tt = -1; # travel time (from sent to last received)

my $timeReceived = parseRFC2882Date($lastHeader->{'Received'}[0]);
if ( $timeReceived ) {
	logD('  Received date: '.strftime('%F %T',$timeReceived->{'S'},$timeReceived->{'M'},$timeReceived->{'H'},$timeReceived->{'d'},$timeReceived->{'m'}-1,$timeReceived->{'Y'}-1900)).' '.$timeReceived->{'tz'};
	if ( $lastTimeSent->{'tz'} eq $timeReceived->{'tz'}) {
		$tt = $timeReceived->{'TS'} - $lastTimeSent->{'TS'};
		logD("Travel time : ${tt}s");
		
		$np->add_perfdata(
			'label' => 'TravelTime',
			'value' => $tt,
			'min' => 0,
			'uom' => 's',
			'threshold' => $np->threshold()
		);
	} else {
		logW('Different timezone : '.$lastTimeSent->{'tz'}.' / '.$timeReceived->{'tz'});
	}
}

logD('  Now: '.strftime('%F %T %z',localtime()));
my $age = strftime('%s',localtime()) - $lastTimeSent->{'TS'};  # delta time (from sent to now)
logD("Age : ${age}s");



# Delete all messages except the last one
for ( my $i = 0, my $maxi = scalar(@toDelete); $i < $maxi; $i++ )  {
	if ( $toDelete[$i] == $lastMsgId ) {
		# keep last message
		delete($toDelete[$i]);
		next;
	}
	logD("Delete msg: ".$toDelete[$i]);
}
if ( scalar(@toDelete) ) {
	if ( !$imap->delete_message(\@toDelete) ) {
		$np->add_message(WARNING, sprintf(_gt('Delete old messages failed: %s'),$@) );
	}

	if ( !$imap->expunge($INBOX) ) {
		$np->add_message(WARNING, sprintf(_gt('Expunge deleted messages on \'%s\' failed: %s'),$INBOX,$@) );
	}
}

$imap->logout;

$np->add_message(OK, sprintf(_gt('Mail system works fine (key %s, age %s)'),$key,printAge($age)) );

my ($status, $message) = $np->check_messages('join' => ' ');
$np->nagios_exit($status, $message );


sub parseRFC2882Date {
	# Sun, 20 Mar 2011 13:10:35 +0100 (CET)
	my ($date) = @_;
	my @parsed = $date =~ $loose_RE;
	if ( @parsed ) {
		my %when;
		@when{qw( d m Y H M S tz)} = @parsed;
		$when{'m'} =  $months{"\L\u".$when{'m'}};
		$when{'S'} ||= 0;
		map {$_+0} ($when{'Y'},$when{'m'},$when{'d'});
		$when{'TS'} = strftime('%s',$when{'S'},$when{'M'},$when{'H'},$when{'d'},$when{'m'}-1,$when{'Y'}-1900);
		return \%when;
	}
	return undef;
}


sub checkSSL {
	my ($socket) = @_;
	if ( ref($socket) ne 'IO::Socket::SSL' ) {
		return _gt('No an IO::Socket::SSL socket ! ');
	}
	my $cn = $socket->peer_certificate('commonName');
	logD('SSL CN='.$cn);
	
	if ($cn ne $server) {
		return _gt('SSL CN does not match server name : '.$cn);
	}
	my $issuer = $socket->peer_certificate('authority');
	logD('SSL issuer='.$issuer);
	return 'OK';
}

sub printAge {
	my ($sec) = @_;
	my ($s,$d,$h,$m) = ($sec,0,0,0);
	my $ret = '';
	if ( $s / (3600*24) > 1) {
		$d = int($s / (3600*24));
		$s = $s % (3600*24);
		$ret .= " $d "._gt("days");
	}
	if ( $s / (3600) > 1) {
		$h = int($s / 3600);
		$s = $s % 3600;
		$ret .= " $h "._gt("h");
	}
	if ( $s / (60) > 1) {
		$m = int($s / 60);
		$s = $s % 60;
		$ret .= " $m "._gt("mn");
	}
	$ret .= " $s "._gt("s");
	return $ret;
}



sub logD {
	print STDERR 'DEBUG:   '.$_[0]."\n" if ($verbose);
}
sub logW {
	print STDERR 'WARNING: '.$_[0]."\n" if ($verbose);
}
# Gettext wrapper
sub _gt {
	return gettext($_[0]);
}

sub showExtra {
	return <<EOT;
(c)2011 Stéphane Urbanovski <s.urbanovski\@ac-nancy-metz.fr>

Note:

	This plugin is design to run whith check_mail_smtp plugin.
	It send a mail with a special "tag" in the subject. This tag is checked by
	check_mail_(pop|imap) plugin to test your messaging system.
	
	Use a dedicated mailbox for this check.
	
Example:
	check_mail_imap.pl -H imap.example.org -u testbox1 -p pass -k 'key-testbox1-from-outside' --proto imaps

EOT
}

