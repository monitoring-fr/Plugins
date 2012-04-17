#!/usr/bin/perl -w
#
# Copyright (c) 2010 Stéphane Urbanovski <stephane.urbanovski@ac-nancy-metz.fr>
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
# This plugin is heavily based on Michal Ludvig's work "smtp-cli" :
# ------
# Command line SMTP client with STARTTLS, SMTP-AUTH and IPv6 support.
# Michal Ludvig <michal@logix.cz>, 2003-2009
# See http://www.logix.cz/michal/devel/smtp-cli for details.
# ------

use strict;
use warnings;

use POSIX qw(setlocale LC_TIME LC_MESSAGES strftime);
use Locale::gettext;

use File::Basename;			# get basename()
use Nagios::Plugin;

use Sys::Hostname;
use IO::Socket::INET;
use IO::Socket::SSL;
use MIME::Base64 qw(encode_base64 decode_base64);
use Socket qw(:DEFAULT :crlf);

use Digest::HMAC_MD5;


my $VERSION = '2.0';
my $TIMEOUT = 10;
my $PROGNAME = basename($0);


# i18n :
setlocale(LC_MESSAGES, '');
textdomain('nagios-plugins-perl');

# Don't use locale format for dates :
setlocale(LC_TIME, 'C');



my $np = Nagios::Plugin->new(
	version => $VERSION,
	blurb => _gt('Nagios plugins to check smtp server. This plugins also allow you to periodicaly send a mail that could be checked by check_mail_pop.pl Nagios plugin.'),
	usage => "Usage: %s -H <smtp host> -m <mail address> [-t <timeout>] [ -c|--critical=<threshold> ] [ -w|--warning=<threshold> ]",
	timeout => $TIMEOUT+1,
	extra => &showExtra(),
);

$np->add_arg (
	spec => 'host|H=s',
	help => _gt('smtp/smtps server.'),
	required => 1,
);
$np->add_arg (
	spec => 'port=i',
	help => _gt('Server port ( default to 25 for smtp and 465 for smtps).'),
	required => 0,
	default => 0,
);
$np->add_arg (
	spec => 'proto|P=s',
	help => _gt('Protocol smtp(default)/smtps/tls.'),
	default => 'auto',
	required => 0,
);
$np->add_arg (
	spec => 'mail|m=s',
	help => _gt('Destination mail address.'),
	required => 1,
);
$np->add_arg (
	spec => 'from|sender=s',
	help => _gt('Sender mail address.'),
	required => 0,
);
$np->add_arg (
	spec => 'key|k=s',
	help => _gt('Key message (default to smtp server name)'),
	required => 0,
);

$np->add_arg (
	spec => 'user|u=s',
	help => _gt('Username (used with smtps or smtp+tls)'),
	required => 0,
);
$np->add_arg (
	spec => 'password|p=s',
	help => _gt('Password (used with smtps or smtp+tls)'),
	required => 0,
);

$np->getopts;

my $smtp_server = $np->opts->get('host');
my $port = $np->opts->get('port');

my $proto = $np->opts->get('proto');

my $mail_sender = $np->opts->get('from');
my $mail_addr = $np->opts->get('mail');
my $pop_key = $np->opts->get('key');

my $user = $np->opts->get('user');
my $pass = $np->opts->get('password');

my $verbose = $np->opts->verbose;


my $hostname = hostname();


## Accept hostname with port number as host:port
if ($smtp_server =~ /^(.*):(.*)$/) {
	$smtp_server = $1;
	$port = $2;
}

# a valid sender address is often required :
$mail_sender = $mail_sender || $mail_addr || $ENV{USER}."@".$hostname ;
my $mail_sender_full = $mail_sender;
if ( $mail_sender !~ /<.*>/ ) {
	$mail_sender_full = "$PROGNAME <".$mail_sender.">";
}

# pop keys is placed in the the subject of the message
# it will be detected by check_mail_imap/check_mail_pop associated plugin
$pop_key = $pop_key || $smtp_server;


if ( defined($user) && !defined($pass) ) {
	$np->add_message(WARNING, sprintf(_gt('%s option defined without %s'),'--user','--pass') );
	$user = undef;
	
} elsif ( defined($pass) && !defined($user) ) {
	$np->add_message(WARNING, sprintf(_gt('%s option defined without %s'),'--pass','--user') );
	$pass = undef;
}


my $date = &getDate();

my $addr_family = AF_UNSPEC;
# my $hello_host = $hostname;

## IO::Socket::INET6 and Socket6 are optional
my $have_ipv6 = eval { require IO::Socket::INET6; require Socket6; 1; };


if ($proto ne 'smtp') {
	# Do Net::SSLeay initialization
	Net::SSLeay::load_error_strings();
	Net::SSLeay::SSLeay_add_ssl_algorithms();
	Net::SSLeay::randomize();
	
	if ( $proto eq 'smtps' ) {
		$port ||= 465;
	}
}

$port ||= 25;


my $smtpHandler = new SMTP::All (
	smtp_server => $smtp_server,
	port => $port,
	proto => $proto,
	timeout => $TIMEOUT,
);

if ( !$smtpHandler->connect() ) {
	$np->nagios_exit(CRITICAL, _gt("SMTP connection failled: ").$smtpHandler->getErrorMsg() );
}
if ( !$smtpHandler->hello() ) {
	$np->nagios_exit(CRITICAL, _gt("SMTP hello failled: ").$smtpHandler->getErrorMsg() );
}

if ( ($proto eq 'tls' || $proto eq 'auto' ) &&  $smtpHandler->hasFeature('STARTTLS') ) {
	if ( !$smtpHandler->startTls() ) {
		$np->nagios_exit(CRITICAL, _gt("STARTTLS connection failled: ").$smtpHandler->getErrorMsg() );
	}
	if ( !$smtpHandler->hello() ) {
		$np->nagios_exit(CRITICAL, _gt("STARTTLS hello failled: ").$smtpHandler->getErrorMsg() );
	}
	$proto = 'tls';
	
} elsif ($proto eq 'tls') {
	$np->nagios_exit(CRITICAL, _gt("TLS not supported by server"));
}



if ($smtpHandler->isSecure() ) {
	$smtpHandler->checkSSL();
}

if ( defined($user) ) {
	if ($smtpHandler->isSecure() ) {
		if ( !$smtpHandler->auth($user,$pass) ) {
			$np->nagios_exit(CRITICAL, _gt("AUTH failled: ").$smtpHandler->getErrorMsg() );
		}
	} else {
		$np->add_message(WARNING, _gt("AUTH disabled on insecure connection") );
	}
}

if ( !$smtpHandler->envelope($mail_sender,$mail_addr) ) {
	$np->nagios_exit(CRITICAL, $smtpHandler->getErrorMsg() );

}


my @message_body = (
	"To: $mail_addr",
	"From: $mail_sender_full",
	"Subject: $pop_key",
	"Date: ".$date,
	"",
	sprintf(_gt("Description: Test message send by '%s'."),$hostname),
	"Key:  $pop_key",
	"Date: ".$date,
	"Host: ".$hostname,
);


if ( !$smtpHandler->data(@message_body) ) {
	$np->nagios_exit(CRITICAL, $smtpHandler->getErrorMsg() );

}

$np->add_message(OK, sprintf(_gt("Message #%s sent to %s"),$smtpHandler->getLastMsgId(),$mail_addr) );

if ( !$smtpHandler->quit() ) {
	$np->add_message(WARNING, _gt("QUIT command failled: ").$smtpHandler->getErrorMsg() );
}



my ($status, $message) = $np->check_messages('join' => ' ');
$np->nagios_exit($status, $message );


sub getDate {
	my $time = $_[0] || time();
# 	return strftime('%A %e %B %Y %H:%M:%S', localtime($time))
# 	return strftime('%a, %d %b %Y %H:%M:%S GMT', gmtime($time));
	return strftime('%a, %d %b %Y %H:%M:%S %z', localtime($time));
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
(c)2003-2009 Michal Ludvig <michal\@logix.cz>
(c)2010 Stéphane Urbanovski <s.urbanovski\@ac-nancy-metz.fr>

Note :

	This plugin is design to run whith check_mail_(pop|imap) plugin.
	It send a mail with a special "tag" in the subject. This tag is checked by
	check_mail_(pop|imap) plugin to test your messaging system.
	
	Use a dedicated mailbox for this check.
	
EOT
}



package SMTP::All;


use strict;
use warnings;


use POSIX qw(mktime);
# use Locale::gettext;

use Sys::Hostname;
use IO::Socket::INET;
use IO::Socket::SSL;
use MIME::Base64 qw(encode_base64 decode_base64);
use Socket qw(:DEFAULT :crlf);


use Data::Dumper;
sub new {
	my $class = shift;
	
	my %args = @_;
	
	my $self = {
		'use_ipv6' => 0,
		'smtp_server' => undef,
		'port' => 0,
		'proto' => 'auto',
		'timeout' => 20,
		'helloCmd' => 'EHLO',
		'helloHost' => hostname() || 'localhost',
		'srvFeatures' => {},
		'isSecure' => 0,
		'msgId' => '??',
		'errmsg' => '',
		'_sock' => undef,
	};
	
	foreach my $arg ( keys(%args) ) {
		if ( exists($self->{$arg}) ) {
			$self->{$arg} = $args{$arg};
		}
	}
	
	if ( $self->{'port'} == 0 && $self->{'proto'} eq 'smtps' ) {
		$self->{'port'} = 465;
	}
	
	bless $self, $class;
	return $self;
}


# Store all server's ESMTP features to a hash.
sub hello {
	my ($self) = @_;
	
	$self->send_line ($self->{'helloCmd'}.' '.$self->{'helloHost'});
	my ($code, $text, $more) = $self->get_one_line ();

	# Empty the hash
	$self->{'srvFeatures'} = {};
	
	# Load all features presented by the server into the hash
	while ($more == 1) {
		if ($code != 250) {
			$self->{'errmsg'} = "$code '$text'";
			return 0;
		}
		my ($feat, $param) = ($text =~ /^(\w+)[= ]*(.*)$/);
		$self->{'srvFeatures'}->{$feat} = $param;
		($code, $text, $more) = $self->get_one_line ();
	}

	return 1;
}

# check if a server feature is present (from hello response)
sub hasFeature ($) {
	my ($self,$feat) = @_;
	return exists($self->{'srvFeatures'}->{$feat});
}

# is SSL/TLS active ?
sub isSecure () {
	my ($self) = @_;
	return $self->{'isSecure'};
}

# get last error message
sub getErrorMsg () {
	my ($self) = @_;
	return $self->{'errmsg'};
}

# get last message id (received by server)
sub getLastMsgId () {
	my ($self) = @_;
	return $self->{'msgId'};
}

# Check server SSL certificate (CN / notAfter).
sub checkSSL {
	my ($self) = @_;

# 		$self->logD ("Using cipher: ". $self->{'_sock'}->get_cipher ());
# 		$self->logD ( $self->{'_sock'}->dump_peer_certificate());
# 		
  		my $ssl = $self->{'_sock'}->_get_ssl_object();
 
		my $x509_cert = Net::SSLeay::get_peer_certificate($ssl);
		
		my $x509_subject = Net::SSLeay::X509_NAME_oneline(Net::SSLeay::X509_get_subject_name($x509_cert));
		
		if ( $x509_subject =~ /cn=([^\/]+)/i ) {
			$self->{'cert_CN'} = $1;
			$self->logD ( 'cert_CN='.$self->{'cert_CN'} ) ;
		}
		
		
		my $x509_notAfter = Net::SSLeay::P_ASN1_UTCTIME_put2string(Net::SSLeay::X509_get_notAfter($x509_cert));
		$self->logD ( 'cert_notAfter='.$x509_notAfter); # Apr  8 15:05:33 2012 GMT
		
		
		my %month = (
			'jan' => 0,
			'feb' => 1,
			'mar' => 2,
			'apr' => 3,
			'may' => 4,
			'jun' => 5,
			'jul' => 6,
			'aug' => 7,
			'sep' => 8,
			'oct' => 9,
			'nov' => 10,
			'dec' => 11,
			
		);
		
		my $naTime = 0;
		if ( $x509_notAfter =~ /^(\w+)\s+(\d+)\s+(\d+):(\d+):(\d+)\s+(\d+)\s+GMT$/ ) {
			#                      1       2       3     4     5       6
			if ( exists($month{lc($1)}) ) {
				$naTime = mktime($5,$4,$3,$2,$month{lc($1)},$6-1900);
			} else {
				$self->logD ( 'bad format for cert_notAfter !'); 
			}
		} else {
			$self->logD ( 'bad format for cert_notAfter 2!'); 
		}
		
		
		$self->logD ( 'cert_notAfter='.localtime($naTime)); 
}

# Connect to the SMTP server.
sub connect {
	my ($self) = @_;
	
	my %connect_args = (
 		PeerAddr => $self->{'smtp_server'},
		PeerPort => $self->{'port'},
		Proto => 'tcp',
		Timeout => $self->{'timeout'},
		);
	
	$self->logD("Connect to ".$self->{'smtp_server'}.':'.$self->{'port'}.' ('.$self->{'proto'}.')');
	
	if ($self->{'use_ipv6'}) {
		$connect_args{'Domain'} = $addr_family;
		$self->{'_sock'} = IO::Socket::INET6->new(%connect_args);
		
	} elsif ($self->{'proto'} eq 'smtps') {
	
		$self->{'_sock'} = IO::Socket::SSL->new(%connect_args);
		if (! $self->{'_sock'} ) {
			$self->{'errmsg'} = "SMTPS: ".IO::Socket::SSL::errstr();
			return 0;
		}

		
		
	} else {
		$self->{'_sock'} = IO::Socket::INET->new(%connect_args);
	}
	
	if ( !$self->{'_sock'} ) {
		$self->{'errmsg'} = "Connect failed: ".$@;
		$self->logW ($self->{'errmsg'});
		return 0;
	}
	
	# TODO: check this
	# 	my $addr_fmt = "%s";
	# 	$addr_fmt = "[%s]" if ($sock->sockhost() =~ /:/); ## IPv6 connection
	
	$self->logD(sprintf ("Connection from %s:%s to %s:%s", $self->{'_sock'}->sockhost(), $self->{'_sock'}->sockport(), $self->{'_sock'}->peerhost(), $self->{'_sock'}->peerport()) );
	
	# Wait for the welcome message of the server.
	my ($code, $text) = $self->get_line ();
	if ($code != 220) {
		$self->{'errmsg'} = "Unknown welcome string: $code '$text'";
		$self->logW ($self->{'errmsg'});
		return 0;
	}
	
	if ($self->{'proto'} eq 'smtps') {
		$self->{'isSecure'} = 1;
	}
	
	if ($text !~ /ESMTP/) {
		$self->{'helloCmd'} = 'HELO';
	}

	return 1;

}


sub startTls () {
	my ($self) = @_;
	
	if ( $self->hasFeature('STARTTLS') || $self->hasFeature('TLS') ) {
		$self->logD ("Starting TLS...");
	
		$self->send_line ('STARTTLS');
		my ($code, $text) = $self->get_line ();
		
		if ($code != 220) {
			$self->{'errmsg'} = "Unknown STARTTLS response : $code '$text'." ;
			return 0;
		}
		
		if (! IO::Socket::SSL::socket_to_SSL($self->{'_sock'}, SSL_version => 'SSLv3 TLSv1')) {
			$self->{'errmsg'} = "STARTTLS: ".IO::Socket::SSL::errstr();
			return 0;
		}
		
# 		$self->logD ("Using cipher: ".$self->{'_sock'}->get_cipher ());
# 		$self->logD ( $self->{'_sock'}->dump_peer_certificate());

		$self->{'isSecure'} = 1;

		return 1;
		
	} else {
		$self->{'errmsg'} = "STARTTLS unsupported by server";
		$self->logW ($self->{'errmsg'});
		return 0;
	}
}


sub auth {
	my ($self,$user,$pass) = @_;
	
	# See if we should authenticate ourself
	if ( !$self->hasFeature('AUTH')) {
		$self->{'errmsg'} = "AUTH unsupported by server";
		$self->logW ($self->{'errmsg'});
		return 0;
	}
	
	$self->logD ("AUTH methods: ". $self->{'srvFeatures'}{'AUTH'});

	if ( $self->{'srvFeatures'}{'AUTH'} =~ /CRAM-MD5/i ) {
		# Try CRAM-MD5 if supported by the server
		my $authMethod = 'AUTH CRAM-MD5';
		
		$self->logD ("using $authMethod");
				
		$self->send_line($authMethod);
		my ($code, $text) = $self->get_line();
		
		if ($code != 334) {
			$self->{'errmsg'} = "$authMethod command failed: $code '$text'";
			$self->logW ($self->{'errmsg'});
			return 0;
		}

		my $response = $self->encode_cram_md5($text, $user, $pass);
		$self->send_line ($response);
		
		($code, $text) = $self->get_line();
		if ($code != 235) {
			$self->{'errmsg'} = "$authMethod chalenge failed: $code '$text'";
			$self->logW ($self->{'errmsg'});
			return 0;
		}
		
	} elsif ($self->{'srvFeatures'}{'AUTH'} =~ /LOGIN/i ) {
		# Eventually try LOGIN method
		
		my $authMethod = 'AUTH LOGIN';
		
		$self->logD ("using $authMethod");
				
		$self->send_line ($authMethod);
		my ($code, $text) = $self->get_line();
		
		if ($code != 334) {
			$self->{'errmsg'} = "$authMethod command failed: $code '$text'";
			$self->logW ($self->{'errmsg'});
			return 0;
		}

		$self->send_line(encode_base64 ($user, ""));
		($code, $text) = $self->get_line();
		
		if ($code != 334) {
			$self->{'errmsg'} = "$authMethod chalenge failed: $code '$text'";
			$self->logW ($self->{'errmsg'});
			return 0;
		}
		
		$self->send_line(encode_base64 ($pass, ""));
		($code, $text) = $self->get_line();
		
		if ($code != 235) {
			$self->{'errmsg'} = "$authMethod chalenge failed: $code '$text'";
			$self->logW ($self->{'errmsg'});
			return 0;
		}
		
		
	} elsif ($self->{'srvFeatures'}{'AUTH'} =~ /PLAIN/i ) {
		# Or finally PLAIN if nothing else was supported.
		
		my $authMethod = 'AUTH PLAIN';
		
		$self->logD ("using $authMethod");
		
		$self->send_line("AUTH PLAIN ". encode_base64 ("$user\0$user\0$pass", ""));
		my ($code, $text) = $self->get_line();
		
		if ($code != 235) {
			$self->{'errmsg'} = "$authMethod chalenge failed: $code '$text'";
			$self->logW ($self->{'errmsg'});
			return 0;
		}
		
	} else {
		# Complain otherwise.
		
		$self->{'errmsg'} = "No supported authentication method advertised by the server.";
		$self->logW ($self->{'errmsg'});
		return 0;
	}
		
	$self->logD ("Authentication of $user\@$smtp_server succeeded");
	return 1;

}


# send SMTP envelope
sub envelope {
	my ($self,$mail_sender,$mail_addr) = @_;
	# We can do a relay-test now if a recipient was set.

	$self->send_line("MAIL FROM: <$mail_sender>");
	my ($code, $text) = $self->get_line();
	
	if ($code != 250) {
		$self->{'errmsg'} = "MAIL FROM <".$mail_sender."> failed: $code '$text'";
		$self->logW ($self->{'errmsg'});
		return 0;
	}

	$self->send_line("RCPT TO: <$mail_addr>");
	($code, $text) = $self->get_line();
	
	if ($code != 250) {
		$self->{'errmsg'} = "RCPT TO <".$mail_addr."> failed: $code '$text'";
		$self->logW ($self->{'errmsg'});
		return 0;
	}
	return 1;
}

# send SMTP envelope
sub data {
	my ($self,@data) = @_;
	
	$self->send_line("DATA");
	my ($code, $text) = $self->get_line();
	
	if ($code != 354) {
		$self->{'errmsg'} = "DATA failed: $code '$text'";
		$self->logW ($self->{'errmsg'});
		return 0;
	}
	
	foreach my $line (@data) {
		$line =~ s/^\.$/\. /; # escape single point
		$self->send_line($line);
	}

	# End DATA
	$self->send_line('.');
	($code, $text) = $self->get_line();
	
	if ($code != 250) {
		$self->{'errmsg'} = "DATA not send: $code '$text'";
		$self->logW ($self->{'errmsg'});
		return 0;
	}
	
	if ($text =~ /queued as ([A-Z0-9]+)/) {
		$self->{'msgId'} = $1;
	}
	
	return 1;
}


# Good bye...
sub quit ($) {
	my ($self) = @_;
	
	$self->send_line('QUIT');
	my ($code, $text) = $self->get_line();
	
	if ($code != 221) {
		$self->{'errmsg'} = "Unknown QUIT response: $code '$text'";
		$self->logW ($self->{'errmsg'});
		return 0;
	}
	return 1;
}


# Get one line of response from the server.
sub get_one_line ($) {
	my ($self) = @_;
	my ($code, $sep, $text) = ($self->{'_sock'}->getline() =~ /(\d+)(.)([^\r]*)/);
	my $more = ($sep eq "-");
	$self->logD("[$code] '$text'");
	return ($code, $text, $more);
}

# Get concatenated lines of response from the server.
sub get_line () {
	my ($self) = @_;
	my ($firstcode, $text, $more) = $self->get_one_line();
	while ($more) {
		my ($code, $line);
		($code, $line, $more) = $self->get_one_line();
		$text .= " $line";
		# FIXME: handle this properly
		die ("Error code changed from $firstcode to $code. That's illegal.\n") if ($firstcode ne $code);
	}
	return ($firstcode, $text);
}

# Send one line back to the server
sub send_line ($) {
	my ($self,$l) = @_;
	$self->logD( "> $l");
 	$l =~ s/\n/$CRLF/g;
	return $self->{'_sock'}->print ($l.$CRLF);
}

sub encode_cram_md5 ($$$) {
	my ($self,$ticket64, $username, $password) = @_;
	my $ticket = decode_base64($ticket64);
	if ( !$ticket ) {
		$self->{'errmsg'} = "Unable to decode Base64 encoded string '$ticket64'";
		$self->logW ($self->{'errmsg'});
		return 0;
	}
	
# 	print "Decoded CRAM-MD5 challenge: $ticket\n" if ($verbose > 1);
	my $password_md5 = Digest::HMAC_MD5::hmac_md5_hex($ticket, $password);
	return encode_base64 ("$username $password_md5", "");
}


sub logD {
	my ($self) = shift;
	print STDERR 'DEBUG:   '.$_[0]."\n" if ($verbose);
}
sub logW {
	my ($self) = shift;
	print STDERR 'WARNING: '.$_[0]."\n" if ($verbose);
}

1;
