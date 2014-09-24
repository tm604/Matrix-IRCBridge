#!/usr/bin/env perl 
use strict;
use warnings;
use IO::Socket::SSL qw(SSL_VERIFY_NONE);
use IO::Async::Loop;
use Net::Async::IRC;
use Net::Async::Matrix 0.07;
use YAML;
use Getopt::Long;
use Digest::SHA qw( hmac_sha1_base64 );

my $loop = IO::Async::Loop->new;

GetOptions(
   'C|config=s' => \my $CONFIG,
) or exit 1;

defined $CONFIG or die "Must supply --configfile\n";

my %CONFIG = %{ YAML::LoadFile( $CONFIG ) };

my %MATRIX_CONFIG = %{ $CONFIG{matrix} };
# No harm in always applying this
$MATRIX_CONFIG{SSL_verify_mode} = SSL_VERIFY_NONE;

my $MATRIX_ROOM = $CONFIG{bridge}{"matrix-room"};

my %IRC_CONFIG = %{ $CONFIG{irc} };

my $IRC_CHANNEL = $CONFIG{bridge}{"irc-channel"};

my $bot_matrix = Net::Async::Matrix->new(
	%MATRIX_CONFIG,
	on_log => sub { warn "log: @_\n" },
	on_room_new => sub {
		my ($matrix, $room) = @_;
		warn "Have a room: " . $room->name . "\n";

		$room->configure(
			on_message => sub {
				my ($room, $from, $content) = @_;
				warn "Message in " . $room->name . ": " . $content->{body};

				my $msg = $content->{body};
				my $msgtype = $content->{msgtype};

				# Mangle the Matrix user_id into something that might work on an IRC channel
				my ($irc_user) = $from->user->user_id =~ /^\@([^:]+):/;
				$irc_user =~ s{[^a-z0-9A-Z]+}{_}g;

				# so this would want to be changed to match on content instead, if we
				# want users to be able to use IRC and Matrix users interchangeably
				if($irc_user =~ /^irc_/) {
					warn "this was a message from an IRC user, ignoring\n";
					return
				} 

				# Prefix the IRC username to make it clear they came from Matrix
				$irc_user = "Mx-$irc_user";

				warn "Queue message for IRC as $irc_user\n";
				my $f = get_or_make_irc_user($irc_user)->then(sub {
					my ($user_irc) = @_;
					warn "sending message for $irc_user - $msg\n";
					if($msgtype eq 'm.text') {
						return $user_irc->send_message( "PRIVMSG", undef, $IRC_CHANNEL, $msg);
					} elsif($msgtype eq 'm.emote') {
						return $user_irc->send_ctcp(undef, $IRC_CHANNEL, "ACTION", $msg);
					} else {
						warn "unknown type $msgtype\n";
					}
				});
				$room->adopt_future( $f );
			}
		);
	},
	on_error => sub {
		print STDERR "Matrix failure: @_\n";
	},
);
$loop->add( $bot_matrix );

my $bot_irc = Net::Async::IRC->new(
	on_message_ctcp_ACTION => sub {
		my ( $self, $message, $hints ) = @_;
		warn "CTCP action";
		return if is_irc_user($hints->{prefix_name});
		warn "we think we should do this one";
		my $matrix_id = "irc_" . $hints->{prefix_name};
		my $msg = $hints->{ctcp_args};
		my $f = get_or_make_matrix_user( $matrix_id )->then(sub {
			my ($user_matrix) = @_;
			$user_matrix->join_room($MATRIX_ROOM);
		})->then( sub {
			my ($room) = @_;
			warn "Sending emote $msg\n";
			$room->send_message(
				type => 'm.emote',
				body => $msg,
			)
		});
		$self->adopt_future( $f );
	},
	on_message_text => sub {
		my ( $self, $message, $hints ) = @_;
		warn "text message";
		return if $hints->{is_notice};
		return if is_irc_user($hints->{prefix_name});
		warn "we think we should do this one";
		my $matrix_id = "irc_" . $hints->{prefix_name};
		my $msg = $hints->{text};
		my $f = get_or_make_matrix_user( $matrix_id )->then(sub {
			my ($user_matrix) = @_;
			$user_matrix->join_room($MATRIX_ROOM);
		})->then( sub {
			my ($room) = @_;
			warn "Sending text $msg\n";
			$room->send_message(
				type => 'm.text',
				body => $msg,
			)
		});
		$self->adopt_future( $f );
	},
	on_error => sub {
		print STDERR "IRC failure: @_\n";
	},
);
$loop->add( $bot_irc );

# Track every Room object, so we can ->leave them all on shutdown
my @all_matrix_rooms;

Future->needs_all(
	$bot_matrix->login( %{ $CONFIG{"matrix-bot"} } )->then( sub {
		$bot_matrix->start;
	})->then( sub {
		$bot_matrix->join_room($MATRIX_ROOM)
	})->on_done( sub {
		my ( $room ) = @_;
		push @all_matrix_rooms, $room;
	}),

	$bot_irc->login( %IRC_CONFIG, %{ $CONFIG{"irc-bot"} } )->then(sub {
		$bot_irc->send_message( "JOIN", undef, $IRC_CHANNEL);
	}),
)->get;

$loop->attach_signal(
	PIPE => sub { warn "pipe\n" }
);
$loop->attach_signal(
	INT => sub { $loop->stop },
);
$loop->attach_signal(
	TERM => sub { $loop->stop },
);
eval {
   $loop->run;
} or my $e = $@;

# When the bot gets shut down, have it leave the rooms so it's clear to observers
# that it is no longer running.
Future->wait_all( map { $_->leave->else_done() } @all_matrix_rooms )->get;

die $e if $e;

exit 0;

{
	my %matrix_users;
	sub get_or_make_matrix_user
	{
		my ($matrix_id) = @_;
		return $matrix_users{$matrix_id} ||= _make_matrix_user($matrix_id);
	}

	sub is_matrix_user
	{
		my ($matrix_id) = @_;
		return defined $matrix_users{$matrix_id};
	}

	sub _make_matrix_user
	{
		my ($matrix_id) = @_;

		# Generate a password for this user
		my $password = hmac_sha1_base64($matrix_id, $CONFIG{"matrix-password-key"});
		warn "Password for $matrix_id is $password\n";

		my $user_matrix = Net::Async::Matrix->new(
			%MATRIX_CONFIG,
			on_room_new => sub {
				my ($user_matrix, $room) = @_;
				push @all_matrix_rooms, $room;
			},
		);
		$bot_matrix->add_child( $user_matrix );

		return $matrix_users{$matrix_id} = (
			# Try to register a new user
			$user_matrix->register(
				user_id => $matrix_id,
				password => $password,
				%{ $CONFIG{"matrix-register"} || {} },
			)
		)->else( sub {
			# If it failed, log in as existing one
			$user_matrix->login(
				user_id => $matrix_id,
				password => $password,
			)
		})->then( sub {
			$user_matrix->start->then_done( $user_matrix );
		})->on_done(sub {
			warn "New Matrix user ready\n";
		});
	}
}

{
	my %irc_users;
	sub get_or_make_irc_user
	{
		my ($irc_user) = @_;
		return $irc_users{lc $irc_user} ||= _make_irc_user($irc_user);
	}

	sub is_irc_user
	{
		my ($irc_user) = @_;
		return defined $irc_users{lc $irc_user};
	}

	sub _make_irc_user
	{
		my ($irc_user) = @_;

		warn "Creating new IRC user for $irc_user\n";
		my $user_irc = Net::Async::IRC->new(
			user => $irc_user
		);
		$bot_irc->add_child( $user_irc );

		$irc_users{lc $irc_user} = $user_irc->login(
			nick => $irc_user,
			%IRC_CONFIG,
		)->then(sub {
			$user_irc->send_message( "JOIN", undef, $IRC_CHANNEL)
				->then_done( $user_irc );
		})->on_done(sub {
			warn "New IRC user ready\n";
		});
	}
}
