#!/usr/bin/env perl 
use strict;
use warnings;
use IO::Socket::SSL qw(SSL_VERIFY_NONE);
use JSON::MaybeXS;
use IO::Async::Loop;
use Net::Async::IRC;
use Net::Async::Matrix;

my $loop = IO::Async::Loop->new;

# Matrix->new parameters for the main bot connection
my @matrix_bot_config = (
	user_id => '@ircbot:perlsite.co.uk',
	access_token => 'QGlyY2JvdDpwZXJsc2l0ZS5jby51aw...vqXrGLqdZgrzBPNXUg',
);

# IRC instances corresponding to Matrix IDs
my %irc;
# Matrix room instances corresponding to IRC nicks
my %matrix;

my $json = JSON::MaybeXS->new(
	utf8 => 1,
	pretty => 1
);

# Users we already have - without ->login in NaMatrix we need to retain access tokens
my %previous_matrix_users = %{
	$json->decode(do {
		local $/;
		open my $fh, '<', 'matrix_users.json' or return '{ }';
		<$fh>
	})
};

# The hardcoded Matrix room we're interested in proxying traffic for
my $target_room = '!AMenDtYvPiDsZiBxRz:perlsite.co.uk';

# Predeclare way ahead of time, we may want to be sending messages on this eventually
my $irc;

# if we need to log in... password for the matrix bot is currently ohfei4Ki
my @matrix_param =  (
	server => 'matrix.perlsite.co.uk',
	SSL => 1,
	SSL_verify_mode => SSL_VERIFY_NONE,
);
my $ready = 0;
$loop->add(
	my $main = Net::Async::Matrix->new(
		@matrix_param,
		@matrix_bot_config,
		on_log => sub { warn "log: @_\n" },
		on_room_new => sub {
			my ($matrix, $room) = @_;
			warn "Have a room: " . $room->name . "\n";

			# Ideally we wouldn't do the initial sync... but for various reasons we do a sync,
			# then throw away initial messages, we expect to be running longterm so it's only
			# a hit on startup
			$room->configure(
				# Use this flag to indicate we're throwing away messages
				on_synced_messages => sub { $ready = 1 },
				on_message => sub {
					# ... and here's where we skip initial sync junk
					return unless $ready;

					eval {
						my ($room, $from, $content) = @_;
						warn "Message in " . $room->name . ": " . $content->{body};

						# Mangle the Matrix user_id into something that might work on an IRC channel
						my ($irc_user) = $from->user->user_id =~ /^\@([^:]+):/;
						$irc_user =~ s{[^a-z0-9A-Z]+}{_}g;

						# so this would want to be changed to match on content instead, if we
						# want users to be able to use IRC and Matrix users interchangeably
						if($irc_user =~ /^irc_/) {
							warn "this was a message from an IRC user, ignoring\n";
							return
						} 

						# the "user IRC" connection
						my $ui;
						unless(exists $irc{lc $irc_user}) {
							warn "Creating new IRC user for $irc_user\n";
							$ui = Net::Async::IRC->new(
								user => $irc_user
							);
							$loop->add($ui);
							$irc{lc $irc_user} = $ui->login(
								nick => $irc_user,
								host => 'localhost',
							)->then(sub {
								Future->needs_all(
									$ui->send_message( "JOIN", undef, "#matrixtest"),
									# could notify someone if we want to track user creation
									# $ui->send_message( "PRIVMSG", undef, "tom_m", "i exist" )
								)
							})->transform(
								done => sub { $ui },
								fail => sub { warn "something went wrong... @_"; 1 }
							)
						}
						my $msg = $content->{body};
						my $msgtype = $content->{msgtype};
						warn "Queue message for IRC as $irc_user\n";
						my $f = $irc{lc $irc_user}->then(sub {
							my $ui = shift;
							warn "sending message for $irc_user - $msg\n";
							if($msgtype eq 'm.text') {
								return $ui->send_message( "PRIVMSG", undef, '#matrixtest', $msg);
							} elsif($msgtype eq 'm.emote') {
								return $ui->send_ctcp(undef, "#matrixtest", "ACTION", $msg);
							} else {
								warn "unknown type $msgtype\n";
							}
						}, sub { warn "unexpected error - @_\n"; Future->done });
						$f->on_ready(sub { undef $f });
						1
					} or warn ":: failure in on_message - $@";
				}
			);
		}
	)
);

$main->join_room($target_room)->get;

$irc = Net::Async::IRC->new(
	on_message_ctcp_ACTION => sub {
		my ( $self, $message, $hints ) = @_;
		warn "CTCP action";
		return if exists $irc{lc $hints->{prefix_name}};
		warn "we think we should do this one";
		my $irc_user = "irc_" . $hints->{prefix_name};
		my $msg = $hints->{ctcp_args};
		setup_irc_user($irc_user);

		my $f = $matrix{$irc_user}->then(sub {
			my ($room) = @_;
			warn "Sending emote $msg\n";
			$room->send_message(
				type => 'm.emote',
				body => $msg,
			)
		});
		$f->on_ready(sub { undef $f });
	},
	on_message_text => sub {
		my ( $self, $message, $hints ) = @_;
		warn "text message";
		return if $hints->{is_notice};
		return if exists $irc{lc $hints->{prefix_name}};
		warn "we think we should do this one";
		my $irc_user = "irc_" . $hints->{prefix_name};
		my $msg = $hints->{text};
		setup_irc_user($irc_user);

		my $f = $matrix{$irc_user}->then(sub {
			my ($room) = @_;
			warn "Sending text $msg\n";
			$room->send_message(
				type => 'm.text',
				body => $msg,
			)
		});
		$f->on_ready(sub { undef $f });
	},
);

$loop->add( $irc );

# These parameters would normally be configurable
my $f;
$f = $irc->login(
	user => "matrixbot",
	nick => "matrixbot",
	host => "localhost",
)->then(sub {
	$irc->send_message( "JOIN", undef, "#matrixtest");
})->on_ready(sub { undef $f });
$main->start;

END {
	open my $fh, '>', 'matrix_users.json' or warn "could not save user list - $!";
	print $json->encode(\%previous_matrix_users);
}

$loop->attach_signal(
	PIPE => sub { warn "pipe\n" }
);
$loop->attach_signal(
	INT => sub { $loop->stop },
);
$loop->attach_signal(
	TERM => sub { $loop->stop },
);
$loop->run;
exit 0;

# this bit establishes the per-user IRC connection
sub setup_irc_user {
	my ($irc_user) = @_;
	unless(exists $matrix{$irc_user}) {
		if(exists $previous_matrix_users{$irc_user}) {
			warn "Using prior matrix user for $irc_user";
			$loop->add(my $mat = Net::Async::Matrix->new(
				@matrix_param,
				user_id => $previous_matrix_users{$irc_user}[0],
				access_token => $previous_matrix_users{$irc_user}[1],
				on_room_new => sub {
					my (undef, $room) = @_;
					warn "Room new thingey appeared: " . $room->name . "\n";
					# $matrix{$irc_user}->done($room);
				}
			));
			# we need to join before we can send to a room
			$matrix{$irc_user} = $mat->join_room($target_room);
		} else {
			warn "Creating new matrix user for $irc_user\n";
			$loop->add(my $m = Net::Async::Matrix->new(
				@matrix_param,
				user_id => $previous_matrix_users{$irc_user}[0],
				access_token => $previous_matrix_users{$irc_user}[1],
				on_room_new => sub {
					my (undef, $room) = @_;
					warn "Room: " . $room->name . "\n";
					$matrix{$irc_user}->done($room);
				}
			));
			$matrix{$irc_user} = $m->register($irc_user, 'nothing')->then(sub {
				my ($user_id, $access_token) = @_;
				warn "!!! Could not register $irc_user\n" unless defined $user_id;
				warn "New user: $user_id with AT $access_token\n";
				$previous_matrix_users{$irc_user} = [ $user_id, $access_token ];
				$m->join_room($target_room)
			}, sub {
				warn "failure... @_";
				return 1;
			})->on_done(sub {
				my ($room) = @_;
				warn "New Matrix user ready with room: $room\n";
			});
		}
	}
}
