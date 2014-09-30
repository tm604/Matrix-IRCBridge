#!/usr/bin/env perl 
use strict;
use warnings;
use 5.010; # //
use IO::Socket::SSL qw(SSL_VERIFY_NONE);
use IO::Async::Loop;
use Net::Async::IRC;
use Net::Async::Matrix 0.08;
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

my %ROOM_FOR_CHANNEL;
my %CHANNEL_FOR_ROOM;
foreach ( @{ $CONFIG{bridge} } ) {
	my $room    = $_->{"matrix-room"};
	my $channel = $_->{"irc-channel"};

	$ROOM_FOR_CHANNEL{$channel} = $room;
	$CHANNEL_FOR_ROOM{$room} = $channel;
}

my %IRC_CONFIG = %{ $CONFIG{irc} };

my $bot_matrix = Net::Async::Matrix->new(
	%MATRIX_CONFIG,
	on_log => sub { warn "log: @_\n" },
	on_room_new => sub {
		my ($matrix, $room) = @_;

		warn "[Matrix] have a room ID: " . $room->room_id . "\n";

		$room->configure(
			on_message => \&on_room_message,
		);
	},
	on_error => sub {
		print STDERR "Matrix failure: @_\n";
	},
);
$loop->add( $bot_matrix );

# Incoming Matrix room messages only have the (opaque) room ID, so we'll need
# to remember what alias we joined those rooms by
my %room_alias_for_id;

sub on_room_message
{
	my ($room, $from, $content) = @_;

	my $room_alias = $room_alias_for_id{$room->room_id} or return;
	warn "[Matrix] in $room_alias: " . $content->{body} . "\n";

	my $irc_channel = $CHANNEL_FOR_ROOM{$room_alias} or return;

	my $msg = $content->{body};
	my $msgtype = $content->{msgtype};

	# Mangle the Matrix user_id into something that might work on an IRC channel
	my ($irc_user) = $from->user->user_id =~ /^\@([^:]+):/;
	$irc_user =~ s{[^a-z0-9A-Z]+}{_}g;

	# so this would want to be changed to match on content instead, if we
	# want users to be able to use IRC and Matrix users interchangeably
	return if $irc_user =~ /^irc_/;

	# Prefix the IRC username to make it clear they came from Matrix
	$irc_user = "$CONFIG{'irc-user-prefix'}-$irc_user";

	my $emote;
	if( $msgtype eq 'm.text' ) {
		$emote = 0;
	}
	elsif( $msgtype eq 'm.emote' ) {
		$emote = 1;
	}
	else {
		warn "  [Matrix] Unknown message type '$msgtype' - ignoring";
		return;
	}

	warn "  [Matrix] sending message for $irc_user - $msg\n";
	$room->adopt_future( send_irc_message(
		irc_user => $irc_user,
		channel  => $irc_channel,
		message  => $msg,
		emote    => $emote,
	));
}

my $bot_irc = Net::Async::IRC->new(
	on_message_ctcp_ACTION => sub {
		my ( $self, $message, $hints ) = @_;
		my $channel = $hints->{target_name};
		my $matrix_room = $ROOM_FOR_CHANNEL{$channel} or return;

		my $matrix_id = "irc_" . $hints->{prefix_name};
		my $msg = $hints->{ctcp_args};

		warn "[IRC] CTCP action in $channel: $msg\n";
		return if is_irc_user($hints->{prefix_name});

		warn "  [IRC] sending emote for $matrix_id - $msg\n";
		$self->adopt_future( send_matrix_message(
			user_id => $matrix_id,
			room_id => $matrix_room,
			type    => 'm.emote',
			body    => $msg,
		));
	},
	on_message_text => sub {
		my ( $self, $message, $hints ) = @_;
		my $channel = $hints->{target_name};
		my $matrix_room = $ROOM_FOR_CHANNEL{$channel} or return;

		my $matrix_id = "irc_" . $hints->{prefix_name};
		my $msg = $hints->{text};

		warn "[IRC] Text message in $channel: $msg\n";
		return if $hints->{is_notice};
		return if is_irc_user($hints->{prefix_name});

		warn "  [IRC] sending text for $matrix_id - $msg\n";
		$self->adopt_future( send_matrix_message(
			user_id => $matrix_id,
			room_id => $matrix_room,
			type    => 'm.text',
			body    => $msg,
		));
	},
	on_error => sub {
		my ( undef, $failure, $name, @args ) = @_;
		print STDERR "IRC failure: $failure\n";
		if( defined $name and $name eq "http" ) {
			my ($response, $request) = @args;
			print STDERR "HTTP failure details:\n" .
				"Requested URL: ${\$request->method} ${\$request->uri}\n" .
				"Response ${\$response->status_line}\n";
			print STDERR " | $_\n" for split m/\n/, $response->decoded_content;
		}
	},
);
$loop->add( $bot_irc );

# Track every Room object, so we can ->leave them all on shutdown
my @all_matrix_rooms;

Future->needs_all(
	$bot_matrix->login( %{ $CONFIG{"matrix-bot"} } )->then( sub {
		$bot_matrix->start;
	})->then( sub {
		Future->wait_all( map {
			my $room_alias = $_;
			$bot_matrix->join_room($room_alias)->on_done( sub {
				my ( $room ) = @_;
				push @all_matrix_rooms, $room;
				$room_alias_for_id{$room->room_id} = $room_alias;
			})
		} values %ROOM_FOR_CHANNEL );
	}),

	$bot_irc->login( %IRC_CONFIG, %{ $CONFIG{"irc-bot"} } )->then(sub {
		Future->wait_all( map {
			$bot_irc->send_message( "JOIN", undef, $_);
		} values %CHANNEL_FOR_ROOM );
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

		warn "[Matrix] making new Matrix user for $matrix_id\n";

		# Generate a password for this user
		my $password = hmac_sha1_base64($matrix_id, $CONFIG{"matrix-password-key"});

		my $user_matrix = Net::Async::Matrix->new(
			%MATRIX_CONFIG,
			on_room_new => sub {
				my ($user_matrix, $room) = @_;
				push @all_matrix_rooms, $room;
			},
		);
		$bot_matrix->add_child( $user_matrix );

		return $matrix_users{$matrix_id} = (
			# Try first to log in as an existing user
			$user_matrix->login(
				user_id => $matrix_id,
				password => $password,
			)
		)->else( sub {
			my ($failure) = @_;
			warn "[Matrix] login as existing user failed - $failure\n";

			# If it failed, try to register an account
			$user_matrix->register(
				user_id => $matrix_id,
				password => $password,
				%{ $CONFIG{"matrix-register"} || {} },
			)
		})->then( sub {
			$user_matrix->start->then_done( $user_matrix );
		})->on_done(sub {
			warn "[Matrix] new Matrix user ready\n";
		})->on_fail(sub {
			my ($failure) = @_;
			warn "[Matrix] failed to register or login for new user - $failure\n";
		});
	}

	my %matrix_user_rooms;
	sub send_matrix_message
	{
		my %args = @_;

		my $user_id = $args{user_id};
		my $room_id = $args{room_id};
		my $type    = $args{type};
		my $body    = $args{body};

		get_or_make_matrix_user( $user_id )->then( sub {
			my ($user_matrix) = @_;
			return $matrix_user_rooms{$user_id}{$room_id} //=
				$user_matrix->join_room( $room_id );
		})->then( sub {
			my ($room) = @_;
			$room->send_message(
				type => $type,
				body => $body,
			)
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

		warn "[IRC] making new IRC user for $irc_user\n";

		my $user_irc = Net::Async::IRC->new(
			user => $irc_user
		);
		$bot_irc->add_child( $user_irc );

		$irc_users{lc $irc_user} = $user_irc->login(
			nick => $irc_user,
			%IRC_CONFIG,
		)->on_done(sub {
			warn "[IRC] new IRC user ready\n";
		});
	}

	my %irc_user_channels;
	sub send_irc_message
	{
		my %args = @_;

		my $user    = $args{irc_user};
		my $channel = $args{channel};
		my $emote   = $args{emote};
		my $message = $args{message};

		get_or_make_irc_user( $user )->then( sub {
			my ($user_irc) = @_;
			return $irc_user_channels{$user}{$channel} //=
				$user_irc->send_message( "JOIN", undef, $channel )->then_done( $user_irc );
		})->then( sub {
			my ($user_irc) = @_;

			$emote
				? $user_irc->send_ctcp( undef, $channel, "ACTION", $message )
				: $user_irc->send_message( "PRIVMSG", undef, $channel, $message );
		});
	}
}
