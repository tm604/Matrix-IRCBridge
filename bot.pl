#!/usr/bin/env perl 
use strict;
use warnings;
use 5.010; # //
use Future::Utils qw( try_repeat );
use IO::Socket::SSL qw(SSL_VERIFY_NONE);
use IO::Async::Loop;
use Net::Async::IRC;
use Net::Async::Matrix 0.13; # $room->invite; ->join_room bugfix
use Net::Async::Matrix::Utils qw( parse_formatted_message build_formatted_message );
use JSON;
use YAML;
use Getopt::Long;
use Digest::SHA qw( hmac_sha1_base64 );
use String::Tagged::IRC 0.02; # Formatting

use constant MAX_IRC_LINE => 460; # Some number comfortably away from 512

binmode STDOUT, ":encoding(UTF-8)";
binmode STDERR, ":encoding(UTF-8)";

my $loop = IO::Async::Loop->new;
# Net::Async::HTTP + SSL + IO::Poll doesn't play well. See
#   https://rt.cpan.org/Ticket/Display.html?id=93107
ref $loop eq "IO::Async::Loop::Poll" and
    warn "Using SSL with IO::Poll causes known memory-leaks!!\n";

GetOptions(
   'C|config=s' => \my $CONFIG,
   'eval-from=s' => \my $EVAL_FROM,
) or exit 1;

if( defined $EVAL_FROM ) {
    # An emergency 'eval() this file' hack
    $SIG{HUP} = sub {
        my $code = do {
            open my $fh, "<", $EVAL_FROM or warn( "Cannot read - $!" ), return;
            local $/; <$fh>
        };

        eval $code or warn "Cannot eval() - $@";
    };
}

defined $CONFIG or die "Must supply --configfile\n";

my %CONFIG = %{ YAML::LoadFile( $CONFIG ) };

my %MATRIX_CONFIG = %{ $CONFIG{matrix} };
# No harm in always applying this
$MATRIX_CONFIG{SSL_verify_mode} = SSL_VERIFY_NONE;

my %ROOM_FOR_CHANNEL;
my %ROOM_NEEDS_INVITE;
my %CHANNEL_FOR_ROOM;
foreach ( @{ $CONFIG{bridge} } ) {
    my $room    = $_->{"matrix-room"};
    my $channel = $_->{"irc-channel"};

    $ROOM_FOR_CHANNEL{$channel} = $room;
    $CHANNEL_FOR_ROOM{$room} = $channel;

    $ROOM_NEEDS_INVITE{$room}++ if $_->{"matrix-needs-invite"};
}

my %IRC_CONFIG = %{ $CONFIG{irc} };

my $bot_matrix = Net::Async::Matrix->new(
    %MATRIX_CONFIG,
    on_log => sub { warn "log: @_\n" },
    on_room_new => sub {
        my ($matrix, $room) = @_;

        $room->configure(
            on_message => \&on_room_message,
        );
    },
    on_error => sub {
        my ( undef, $failure, $name, @args ) = @_;
        print STDERR "Matrix failure: $failure\n";
        if( defined $name and $name eq "http" ) {
            my ($response, $request) = @args;
            print STDERR "HTTP failure details:\n" .
                "Requested URL: ${\$request->method} ${\$request->uri}\n";
            if($response) {
                print STDERR "Response ${\$response->status_line}\n";
                print STDERR " | $_\n" for split m/\n/, $response->decoded_content;
            }
            else {
                print STDERR "No response\n";
            }
        }
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

    my $msg = parse_formatted_message( $content );
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
    elsif( $msgtype eq 'm.image' ) {
        # We can't directly post an image URL onto IRC as the ghost user,
        # without it being unspoofable. Instead we'll have the bot user
        # /itself/ report on this fact
        #
        # Additionally, if the URL is an mxc://... URL, we'll have to convert
        # it to the HTTP content repository URL for non-matrix clients
        my $uri = URI->new( $content->{url} );
        if( $uri->scheme eq "mxc" ) {
            $uri = "https://$MATRIX_CONFIG{server}/_matrix/media/v1/download/" . $uri->authority . $uri->path;
        }

        $room->adopt_future( send_irc_as_bot(
            channel => $irc_channel,
            message => "<$irc_user> posted image: $uri - $msg",
        ) );
        return;
    }
    else {
        warn "  [Matrix] Unknown message type '$msgtype' - ignoring";
        return;
    }

    # IRC cannot cope with linefeeds
    foreach my $line ( $msg->split( qr/\n/ ) ) {
        $line = substr( $line, 0, MAX_IRC_LINE-3 ) . "..." if
            length( $line ) > MAX_IRC_LINE;

        warn "  [Matrix] sending message for $irc_user - $line\n";
        $room->adopt_future( send_irc_message(
            irc_user => $irc_user,
            channel  => $irc_channel,
            message  => $line,
            emote    => $emote,
        ));
    }
}

my $reconnect_delay = 5;

my $bot_irc = Net::Async::IRC->new(
    encoding => "UTF-8",
    on_message_ctcp_ACTION => sub {
        my ( $self, $message, $hints ) = @_;
        my $channel = $hints->{target_name};
        my $matrix_room = $ROOM_FOR_CHANNEL{$channel} or return;

        $reconnect_delay = 5;

        my $matrix_id = "irc_" . $hints->{prefix_name};
        my $msg = String::Tagged::IRC->parse_irc( $hints->{ctcp_args} );

        warn "[IRC] CTCP action in $channel: $msg\n";
        return if is_irc_user($hints->{prefix_name});

        warn "  [IRC] sending emote for $matrix_id - $msg\n";
        $self->adopt_future( send_matrix_message(
            user_id     => $matrix_id,
            displayname => "(IRC $hints->{prefix_nick})",
            room_id     => $matrix_room,
            type        => 'm.emote',
            message     => $msg->as_formatted,
        ));
    },
    on_message_text => sub {
        my ( $self, $message, $hints ) = @_;
        my $channel = $hints->{target_name};
        my $matrix_room = $ROOM_FOR_CHANNEL{$channel} or return;

        $reconnect_delay = 5;

        my $matrix_id = "irc_" . $hints->{prefix_name};
        my $msg = String::Tagged::IRC->parse_irc( $hints->{text} );

        warn "[IRC] Text message in $channel: $msg\n";
        return if $hints->{is_notice};
        return if is_irc_user($hints->{prefix_name});

        warn "  [IRC] sending text for $matrix_id - $msg\n";
        $self->adopt_future( send_matrix_message(
            user_id     => $matrix_id,
            displayname => "(IRC $hints->{prefix_nick})",
            room_id     => $matrix_room,
            type        => 'm.text',
            message     => $msg->as_formatted,
        ));
    },
    on_error => sub {
        my ( undef, $failure, $name, @args ) = @_;
        print STDERR "IRC failure: $failure\n";
        if( defined $name and $name eq "http" ) {
            my ($response, $request) = @args;
            print STDERR "HTTP failure details:\n" .
                "Requested URL: ${\$request->method} ${\$request->uri}\n";
            if($response) {
                print STDERR "Response ${\$response->status_line}\n";
                print STDERR " | $_\n" for split m/\n/, $response->decoded_content;
            }
            else {
                print STDERR "No response\n";
            }
        }
    },
    on_closed => sub {
        my ( $self ) = @_;

        $loop->delay_future( after => $reconnect_delay )->then( sub {
            $reconnect_delay *= 2 if $reconnect_delay < 300; # ramp up to 5 minutes

            $self->adopt_future( connect_irc() );
        });
    },
);
$loop->add( $bot_irc );

sub connect_irc
{
    my $delay = 0;

    $bot_irc->login( %IRC_CONFIG, %{ $CONFIG{"irc-bot"} } )->then(sub {
        Future->wait_all( map {
            my $channel = $_;
            $loop->delay_future( after => $delay++ )->then( sub {
                $bot_irc->send_message( "JOIN", undef, $channel )->on_done( sub {
                    warn "[IRC] joined $channel\n";
                });
            });
        } values %CHANNEL_FOR_ROOM );
    }),
}

# Track every Room object, so we can ->leave them all on shutdown
my %bot_matrix_rooms;
my @user_matrix_rooms;

sub try_repeat_with_delay(&)
{
    my ( $code ) = @_;

    my $retries_remaining = 5;

    try_repeat {
        $code->()->else_with_f( sub {
            my ( $f ) = @_;
            return $f unless $retries_remaining--;

            warn $f->failure . "; $retries_remaining attempts remaining...\n";

            $loop->delay_future( after => 5 )
                ->then( sub { $f } )
        })
    } while => sub { shift->failure and $retries_remaining };
}

sub connect_matrix
{
    my $login_f = try_repeat_with_delay {
        $bot_matrix->login( %{ $CONFIG{"matrix-bot"} } )->then( sub {
            $bot_matrix->start;
        });
    };

    # Stagger room joins to avoid thundering-herd on the server
    my $delay = 0;

    $login_f->then( sub {
        Future->wait_all( map {
            my $room_alias = $_;

            $loop->delay_future( after => $delay++ )->then( sub {
                try_repeat_with_delay {
                    $bot_matrix->join_room($room_alias)
                }
            })->on_done( sub {
                my ( $room ) = @_;
                warn "[Matrix] joined $room_alias\n";
                $bot_matrix_rooms{$room_alias} = $room;
                $room_alias_for_id{$room->room_id} = $room_alias;
            })
        } values %ROOM_FOR_CHANNEL );
    })
}

print STDERR "**********\nMatrix <-> IRC bridge starting...\n**********\n";

Future->needs_all(
    connect_matrix(),
    connect_irc(),
)->get;

print STDERR "*****\nNow connected\n*****\n";

$loop->attach_signal(
    PIPE => sub { warn "pipe\n" }
);
$loop->attach_signal(
    INT => sub { $loop->stop },
);
$loop->attach_signal(
    TERM => sub { $loop->stop },
);

my $running = 1;
$loop->run;

END {
    return unless $running;

    print STDERR "**********\nMatrix <-> IRC bridge shutting down...\n**********\n";

    # When the bot gets shut down, have it leave the rooms so it's clear to observers
    # that it is no longer running.
    if( $CONFIG{"remove-users-on-shutdown"} // 1 ) {
        print STDERR "Removing ghost users from Matrix rooms...\n";
        Future->wait_all( map { $_->leave->else_done() } @user_matrix_rooms )->get;
    }
    else {
        print STDERR "Leaving ghost users in Matrix rooms.\n";
    }

    if( $CONFIG{"remove-bot-on-shutdown"} // 1 ) {
        print STDERR "Removing bot from Matrix rooms...\n";
        Future->wait_all( map { $_->leave->else_done() } values %bot_matrix_rooms )->get;
    }
    else {
        print STDERR "Leaving bot users in Matrix rooms.\n";
    }
}


{
    my %matrix_users;
    sub get_or_make_matrix_user
    {
        my ($matrix_id, $displayname) = @_;
        return $matrix_users{$matrix_id} ||= _make_matrix_user($matrix_id, $displayname)
            ->on_fail( sub { delete $matrix_users{$matrix_id} } );
    }

    sub is_matrix_user
    {
        my ($matrix_id) = @_;
        return defined $matrix_users{$matrix_id};
    }

    sub _make_matrix_user
    {
        my ($matrix_id, $displayname) = @_;

        warn "[Matrix] making new Matrix user for $matrix_id\n";

        # Generate a password for this user
        my $password = hmac_sha1_base64($matrix_id, $CONFIG{"matrix-password-key"});

        my $user_matrix = Net::Async::Matrix->new(
            %MATRIX_CONFIG,
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
            $user_matrix->set_displayname( $displayname );
        })->then( sub {
            $user_matrix->start->then_done( $user_matrix );
        })->on_done(sub {
            warn "[Matrix] new Matrix user ready\n";
        })->on_fail(sub {
            my ($failure) = @_;
            warn "[Matrix] failed to register or login for new user - $failure\n";
        });
    }

    sub _join_matrix_user_to_room
    {
        my ($user_matrix, $room_id) = @_;

        ( $ROOM_NEEDS_INVITE{$room_id} ?
            # Inviting an existing member causes an error; we'll have to ignore it
            $bot_matrix_rooms{$room_id}->invite( $user_matrix->myself->user_id )
                ->else_done() : # TODO(paul): a finer-grained error ignoring condition
            Future->done
        )->then( sub {
            $user_matrix->join_room( $room_id );
        })->on_done( sub {
            my ( $room ) = @_;
            push @user_matrix_rooms, $room;
        });
    }

    my %matrix_user_rooms;
    sub send_matrix_message
    {
        my %args = @_;

        my $user_id = $args{user_id};
        my $room_id = $args{room_id};
        my $type    = $args{type};
        my $message = $args{message};

        get_or_make_matrix_user( $user_id, $args{displayname} )->then( sub {
            my ($user_matrix) = @_;
            return $matrix_user_rooms{$user_id}{$room_id} //= _join_matrix_user_to_room($user_matrix, $room_id)
                ->on_fail( sub { delete $matrix_user_rooms{$user_id}{$room_id} } );
        })->then( sub {
            my ($room) = @_;
            $room->send_message(
                type => $type,
                %{ build_formatted_message( $message ) },
            )
        })->on_fail( sub {
            my ( $failure ) = @_;
            # If the ghost user isn't actually in the room, or was kicked and
            # we didn't notice (TODO: notice kicks), then this send will fail.
            # We won't bother retrying this but we should at least forget the
            # ghost's membership in the room, so next attempt will try to join
            # again.

            # SPEC TODO: we really need a nicer way to determine this.
            return unless @_ > 1 and $_[1] eq "http";
            my $resp = $_[2];
            return unless $resp and $resp->code == 403;
            my $err = eval { JSON->new->decode( $resp->decoded_content ) } or return;
            $err->{error} =~ m/^User \S+ not in room / or return;

            # Send failed because user wasn't in the room
            warn "[Matrix] User isn't in the room after all\n";
            delete $matrix_user_rooms{$user_id}{$room_id};
        });
    }
}

{
    my %irc_users; # {$user_name} = Future of $user_irc
    sub _canonise_irc_name
    {
        my $maxlen = $bot_irc->isupport( 'NICKLEN' ) // 9;
        return lc substr $_[0], 0, $maxlen;
    }

    sub get_or_make_irc_user
    {
        my ($irc_user) = @_;
        my $irc_user_canon = _canonise_irc_name $irc_user;

        return $irc_users{$irc_user_canon} ||= _make_irc_user($irc_user)
            ->on_fail( sub { delete $irc_users{$irc_user_canon} } );
    }

    sub is_irc_user
    {
        my ($irc_user) = @_;
        $irc_user = _canonise_irc_name $irc_user;

        return defined $irc_users{$irc_user};
    }

    sub _make_irc_user
    {
        my ($user_name) = @_;
        my $user_name_canon = _canonise_irc_name $user_name;

        warn "[IRC] making new IRC user for $user_name\n";

        use Data::Dump 'pp';

        my $user_irc = Net::Async::IRC->new(
            encoding => "UTF-8",
            user => $user_name,

            on_message_KICK => sub {
                my ( $user_irc, $message, $hints ) = @_;

                # TODO: Get NaIRC to add kicked_is_me hint
                my $kicked_is_me = $user_irc->is_nick_me( $hints->{kicked_nick} );

                _on_irc_kicked( $user_name_canon, $hints->{target_name} ) if $kicked_is_me;
            },

            on_closed => sub {
                _on_irc_closed( $user_name_canon );
            },
        );
        $bot_irc->add_child( $user_irc );

        $irc_users{$user_name_canon} = $user_irc->login(
            nick => $user_name,
            %IRC_CONFIG,
        )->on_done(sub {
            warn "[IRC] new IRC user ready\n";
        });
    }

    my %irc_user_channels; # {$user_name}{$channel_name} = Future of $user_irc
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
                $user_irc->send_message( "JOIN", undef, $channel )->then_done( $user_irc )
                ->on_fail( sub { delete $irc_user_channels{$user}{$channel} } );
        })->then( sub {
            my ($user_irc) = @_;

            my $rawmessage = ref $message ?
                String::Tagged::IRC->new_from_formatted( $message )->build_irc :
                $message;

            $emote
                ? $user_irc->send_ctcp( undef, $channel, "ACTION", $rawmessage )
                : $user_irc->send_message( "PRIVMSG", undef, $channel, $rawmessage );
        });
    }

    sub send_irc_as_bot
    {
        my %args = @_;

        my $channel = $args{channel};
        my $emote   = $args{emote};
        my $message = $args{message};

        my $rawmessage = ref $message ?
            String::Tagged::IRC->new_from_formatted( $message )->build_irc :
            $message;

        $emote
            ? $bot_irc->send_ctcp( undef, $channel, "ACTION", $rawmessage )
            : $bot_irc->send_message( "PRIVMSG", undef, $channel, $rawmessage );
    }

    sub _on_irc_kicked
    {
        my ($user_name, $channel_name) = @_;
        warn "[IRC] user $user_name got kicked from $channel_name\n";

        delete $irc_user_channels{$user_name}{$channel_name};
    }

    sub _on_irc_closed
    {
        my ($user_name) = @_;
        warn "[IRC] user $user_name connection lost\n";

        delete $irc_user_channels{$user_name};
        delete $irc_users{$user_name};
    }
}
