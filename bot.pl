#!/usr/bin/env perl 
use strict;
use warnings;
use IO::Socket::SSL qw(SSL_VERIFY_NONE);
use JSON::MaybeXS;
use IO::Async::Loop;
use Net::Async::IRC;
use Net::Async::Matrix 0.07;
use YAML;
use Getopt::Long;

my $loop = IO::Async::Loop->new;

GetOptions(
   'C|config=s' => \(my $CONFIG = "bot.yaml"),
) or exit 1;

my %CONFIG = %{ YAML::LoadFile( $CONFIG ) };

my %MATRIX_CONFIG = %{ $CONFIG{matrix} };
# No harm in always applying this
$MATRIX_CONFIG{SSL_verify_mode} = SSL_VERIFY_NONE;

my $MATRIX_ROOM = $CONFIG{bridge}{"matrix-room"};

my %IRC_CONFIG = %{ $CONFIG{irc} };

my $IRC_CHANNEL = $CONFIG{bridge}{"irc-channel"};

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
		my $fh;
		open $fh, '<', 'matrix_users.json' and <$fh> or '{ }';
	})
};

# Predeclare way ahead of time, we may want to be sending messages on this eventually
my $irc;

my %matrix_rooms;

$loop->add(
	my $main = Net::Async::Matrix->new(
		%MATRIX_CONFIG,
		on_log => sub { warn "log: @_\n" },
		on_room_new => sub {
			my ($matrix, $room) = @_;
			warn "Have a room: " . $room->name . "\n";

			$matrix_rooms{$room->room_id} = $room;

			$room->configure(
				on_message => sub {
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

						# Prefix the IRC username to make it clear they came from Matrix
						$irc_user = "Mx-$irc_user";

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
								%IRC_CONFIG,
							)->then(sub {
								Future->needs_all(
									$ui->send_message( "JOIN", undef, $IRC_CHANNEL),
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
								return $ui->send_message( "PRIVMSG", undef, $IRC_CHANNEL, $msg);
							} elsif($msgtype eq 'm.emote') {
								return $ui->send_ctcp(undef, $IRC_CHANNEL, "ACTION", $msg);
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

$main->login( %{ $CONFIG{"matrix-bot"} } )->get;
$main->start->get; # await room initialSync

# We should now be started up
$matrix_rooms{$MATRIX_ROOM} or
	$main->join_room($MATRIX_ROOM)->get;

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
	%IRC_CONFIG,
	%{ $CONFIG{"irc-bot"} },
)->then(sub {
	$irc->send_message( "JOIN", undef, $IRC_CHANNEL);
})->on_ready(sub { undef $f });
$main->start;

END {
	open my $fh, '>', 'matrix_users.json' or warn "could not save user list - $!";
	print $fh $json->encode(\%previous_matrix_users);
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
				%MATRIX_CONFIG,
				user_id => $previous_matrix_users{$irc_user}[0],
				access_token => $previous_matrix_users{$irc_user}[1],
				on_room_new => sub {
					my (undef, $room) = @_;
					warn "Room new thingey appeared: " . $room->name . "\n";
					# $matrix{$irc_user}->done($room);
				}
			));
			# we need to join before we can send to a room
			$matrix{$irc_user} = $mat->join_room($MATRIX_ROOM);
		} else {
			warn "Creating new matrix user for $irc_user\n";
			$loop->add(my $m = Net::Async::Matrix->new(
				%MATRIX_CONFIG,
				user_id => $previous_matrix_users{$irc_user}[0],
				access_token => $previous_matrix_users{$irc_user}[1],
				on_room_new => sub {
					my (undef, $room) = @_;
					warn "Room: " . $room->name . "\n";
					$matrix{$irc_user}->done($room);
				}
			));
			$matrix{$irc_user} = $m->register(
				user_id => $irc_user,
				password => 'nothing',
			)->then(sub {
				my ($user_id, $access_token) = @_;
				warn "!!! Could not register $irc_user\n" unless defined $user_id;
				warn "New user: $user_id with AT $access_token\n";
				$previous_matrix_users{$irc_user} = [ $user_id, $access_token ];
				$m->join_room($MATRIX_ROOM)
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
