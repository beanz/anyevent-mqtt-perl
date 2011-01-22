use strict;
use warnings;
package AnyEvent::MQTT;

# ABSTRACT: AnyEvent module for an MQTT client

=head1 SYNOPSIS

  use AnyEvent::MQTT;
  my $mqtt = AnyEvent::MQTT->new;
  my $cv = $mqtt->subscribe(topic => '/topic',
                            callback => sub {
                                 my ($topic, $message) = @_;
                                 print $topic, ' ', $message, "\n"
                               });
  my $qos = $cv->recv; # subscribed, negotiated QoS == $qos

  # publish a simple message
  my $cv = $mqtt->publish(message => 'simple message',
                          topic => '/topic');
  $cv->recv; # sent

  # publish line-by-line from file handle
  $cv =  $mqtt->publish(handle => \*STDIN,
                        topic => '/topic');
  $cv->recv; # sent

  # publish from AnyEvent::Handle
  $cv = $mqtt->publish(handle => AnyEvent::Handle->new(...),
                       topic => '/topic');
  $cv->recv; # sent

=head1 DESCRIPTION

AnyEvent module for MQTT client.

B<IMPORTANT:> This is an early release and the API is still subject to
change.

=head1 DISCLAIMER

This is B<not> official IBM code.  I work for IBM but I'm writing this
in my spare time (with permission) for fun.

=cut

use constant DEBUG => $ENV{ANYEVENT_MQTT_DEBUG};
use AnyEvent;
use AnyEvent::Handle;
use Net::MQTT::Constants;
use Net::MQTT::Message;
use Carp qw/croak carp/;

=method C<new(%params)>

Constructs a new C<AnyEvent::MQTT> object.  The supported parameters
are:

=over

=item C<host>

The server host.  Defaults to C<127.0.0.1>.

=item C<port>

The server port.  Defaults to C<1883>.

=item C<timeout>

The timeout for responses from the server.

=item C<keep_alive_timer>

The keep alive timer.

=item C<will_topic>

Set topic for will message.  Default is undef which means no will
message will be configured.

=item C<will_qos>

Set QoS for will message.  Default is 'at-most-once'.

=item C<will_retain>

Set retain flag for will message.  Default is 0.

=item C<will_message>

Set message for will message.  Default is the empty message.

=item C<clean_session>

Set clean session flag for connect message.  Default is 1 but
it is set to 0 when reconnecting after an error.

=item C<client_id>

Sets the client id for the client overriding the default which
is C<Net::MQTT::Message[NNNNN]> where NNNNN is the process id.

=back

=cut

sub new {
  my ($pkg, %p) = @_;
  my $self =
    bless {
           socket => undef,
           host => '127.0.0.1',
           port => '1883',
           timeout => 30,
           wait => 'nothing',
           keep_alive_timer => 120,
           qos => MQTT_QOS_AT_MOST_ONCE,
           message_id => 1,
           user_name => undef,
           password => undef,
           will_topic => undef,
           will_qos => MQTT_QOS_AT_MOST_ONCE,
           will_retain => 0,
           will_message => '',
           client_id => undef,
           clean_session => 1,
           write_queue => [],
           %p,
          }, $pkg;
}

sub DESTROY {
  $_[0]->cleanup;
}

=method C<cleanup()>

This method attempts to destroy any resources in the event of a
disconnection or fatal error.

=cut

sub cleanup {
  my $self = shift;
  print STDERR "cleanup\n" if DEBUG;
  delete $self->{handle};
  delete $self->{connected};
  delete $self->{wait};
  delete $self->{_keep_alive_handle};
  delete $self->{_keep_alive_waiting};
  $self->{write_queue} = [];
}

sub _error {
  my ($self, $fatal, $message, $reconnect) = @_;
  $self->cleanup($message);
  $self->{on_error}->($fatal, $message) if ($self->{on_error});
  $self->_reconnect() if ($reconnect);
}

=method C<publish( %parameters )>

This method is used to publish to a given topic.  It returns an
L<AnyEvent::condvar> which is notified when the publish is complete
(written to the kernel or ack'd depending on the QoS level).  The
parameter hash must included at least a B<topic> value and one of:

=over

=item B<message>

  with a string value which is published to the topic,

=item B<handle>

 the value of which must either be an L<AnyEvent::Handle> or will be
 passed to an L<AnyEvent::Handle> constructor as the C<fh> argument.
 The L<push_read()> method is called on the L<AnyEvent::Handle> with a
 callback that will publish each chunk read to the topic.

=back

The parameter hash may also keys for:

=over

=item C<qos>

  to set the QoS level for published messages (default
  MQTT_QOS_AT_MOST_ONCE),

=item C<handle_args>

  a reference to a list to pass as arguments to the
  L<AnyEvent::Handle> constructor in the final case above (defaults to
  an empty list reference), or

=item C<push_read_args>

  a reference to a list to pass as the arguments to the
  L<AnyEvent::Handle#push_read> method (defaults to ['line'] to read,
  and subsequently publish, a line at a time.

=back

=cut

sub publish {
  my ($self, %p) = @_;
  my $topic = exists $p{topic} ? $p{topic} :
    croak ref $self, '->publish requires "topic" parameter';
  my $qos = exists $p{qos} ? $p{qos} : MQTT_QOS_AT_MOST_ONCE;
  my $cv = exists $p{cv} ? delete $p{cv} : AnyEvent->condvar;
  my $message = $p{message};
  if (defined $message) {
    print STDERR "publish: message[$message] => $topic\n" if DEBUG;
    my $mid = $self->{message_id}++;
    return $self->_send(message_type => MQTT_PUBLISH,
                        qos => $qos,
                        topic => $topic,
                        message_id => $mid,
                        message => $message,
                        cv => $cv);
  }
  my $handle = exists $p{handle} ? $p{handle} :
    croak ref $self, '->publish requires "message" or "handle" parameter';
  unless ($handle->isa('AnyEvent::Handle')) {
    my @args = @{$p{handle_args}||[]};
    print STDERR "publish: IO[$handle] => $topic @args\n" if DEBUG;
    $handle = AnyEvent::Handle->new(fh => $handle, @args);
  }
  my $error_sub = $handle->{on_error}; # Hack: There is no accessor api
  $handle->on_error(sub {
                      $error_sub->(@_) if ($error_sub);
                      $handle->destroy;
                      undef $handle;
                      $cv->send(1);
                    });
  my @push_read_args = @{$p{push_read_args}||['line']};
  my $sub; $sub = sub {
    my ($hdl, $chunk, @args) = @_;
    print STDERR "publish: $chunk => $topic\n" if DEBUG;
    my $mid = $self->{message_id}++;
    $self->_send(message_type => MQTT_PUBLISH,
                 qos => $qos,
                 topic => $topic,
                 message_id => $mid,
                 message => $chunk);
    $handle->push_read(@push_read_args => $sub);
    return;
  };
  $handle->push_read(@push_read_args => $sub);
  return $cv;
}

=method C<subscribe( %parameters )>

This method is subscribes to the given topic.  The parameter hash
may contain values for the following keys:

=over

=item B<topic>

  for the topic to subscribe to (this is required),

=item B<callback>

  for the callback to call with messages (this is required),

=item B<qos>

  QoS level to use (default is MQTT_QOS_AT_MOST_ONCE),

=item B<cv>

  L<AnyEvent> condvar to use to signal the subscription is complete.
  The received value will be the negotiated QoS level.

=back

This method returns the value of the B<cv> parameter if it was
supplied or an L<AnyEvent> condvar created for this purpose.

=cut

sub subscribe {
  my ($self, %p) = @_;
  my $topic = exists $p{topic} ? $p{topic} :
    croak ref $self, '->subscribe requires "topic" parameter';
  my $sub = exists $p{callback} ? $p{callback} :
    croak ref $self, '->subscribe requires "callback" parameter';
  my $qos = exists $p{qos} ? $p{qos} : MQTT_QOS_AT_MOST_ONCE;
  my $cv = exists $p{cv} ? delete $p{cv} : AnyEvent->condvar;
  my $mid = $self->_add_subscription($topic, $sub, $cv);
  if (defined $mid) { # not already subscribed/subscribing
    $self->_send(message_type => MQTT_SUBSCRIBE,
                 message_id => $mid,
                 topics => [[$topic, $qos]]);
  }
  $cv
}

sub _add_subscription {
  my ($self, $topic, $sub, $cv) = @_;
  my $rec = $self->{_sub}->{$topic};
  if ($rec) {
    print STDERR "Add $sub to existing $topic subscription\n" if DEBUG;
    push @{$rec->{cb}}, $sub;
    $cv->send($rec->{qos});
    return;
  }
  $rec = $self->{_sub_pending}->{$topic};
  if ($rec) {
    print STDERR "Add $sub to existing pending $topic subscription\n" if DEBUG;
    push @{$rec->{cb}}, $sub;
    push @{$rec->{cv}}, $cv;
    return;
  }
  my $mid = $self->{message_id}++;
  print STDERR "Add $sub as pending $topic subscription (mid=$mid)\n" if DEBUG;
  $self->{_sub_pending_by_message_id}->{$mid} = $topic;
  $self->{_sub_pending}->{$topic} = { cb => [ $sub ], cv => [ $cv ] };
  $mid;
}

sub _confirm_subscription {
  my ($self, $mid, $qos) = @_;
  my $topic = delete $self->{_sub_pending_by_message_id}->{$mid};
  unless (defined $topic) {
    carp "Got SubAck with no pending subscription for message id: $mid\n";
    return;
  }
  my $re = topic_to_regexp($topic); # convert MQTT pattern to regexp
  my $rec;
  if ($re) {
    $rec = $self->{_subre}->{$topic} = delete $self->{_sub_pending}->{$topic};
    $rec->{re} = $re;
  } else {
    $rec = $self->{_sub}->{$topic} = delete $self->{_sub_pending}->{$topic};
  }
  $rec->{qos} = $qos;

  foreach my $cv (@{$rec->{cv}}) {
    $cv->send($qos);
  }
}

sub _send {
  my $self = shift;
  my %p = @_;
  my $cv = delete $p{cv};
  my $msg = Net::MQTT::Message->new(%p);
  $self->{connected} ?
    $self->_queue_write($msg, $cv) : $self->connect($msg, $cv);
}

sub _queue_write {
  my ($self, $msg, $cv) = @_;
  my $queue = $self->{write_queue};
  print STDERR 'Queuing: ', $msg->string, "\n" if DEBUG;
  push @{$queue}, [$msg, $cv];
  $self->_write_now unless (defined $self->{_waiting});
  $cv;
}


sub _write_now {
  my $self = shift;
  my ($msg, $cv);
  undef $self->{_waiting};
  if (@_) {
    ($msg, $cv) = @_;
  } else {
    my $args = shift @{$self->{write_queue}} or return;
    ($msg, $cv) = @$args;
  }
  $self->_reset_keep_alive_timer();
  print STDERR "Sending: ", $msg->string, "\n" if DEBUG;
  $self->{_waiting} = [$msg, $cv];
  $self->{handle}->push_write($msg->bytes);
  $cv;
}

sub _reset_keep_alive_timer {
  my ($self, $wait) = @_;
  undef $self->{_keep_alive_handle};
  my $method = $wait ? '_keep_alive_timeout' : '_send_keep_alive';
  $self->{_keep_alive_waiting} = $wait;
  $self->{_keep_alive_handle} =
    AnyEvent->timer(after => $self->{keep_alive_timer},
                    cb => sub { $self->$method(@_) });
}

sub _send_keep_alive {
  my $self = shift;
  print STDERR "Sending: keep alive\n" if DEBUG;
  $self->_send(message_type => MQTT_PINGREQ);
  $self->_reset_keep_alive_timer(1);
}

sub _keep_alive_timeout {
  my $self = shift;
  print STDERR "keep alive timeout\n" if DEBUG;
  undef $self->{_keep_alive_waiting};
  $self->{handle}->destroy;
  $self->_error(0, 'keep alive timeout', 1);
}

sub _keep_alive_received {
  my $self = shift;
  print STDERR "keep alive received\n" if DEBUG;
  return unless (defined $self->{_keep_alive_waiting});
  $self->_reset_keep_alive_timer();
}

=method C<connect( [ $msg ] )>

This method starts the connection to the server.  It will be called
lazily when required publish or subscribe so generally is should not
be necessary to call it directly.

=cut

sub connect {
  my ($self, $msg, $cv) = @_;
  print STDERR "connect\n" if DEBUG;
  $self->{_waiting} = 'connect';
  if ($msg) {
    $cv = AnyEvent->condvar unless ($cv);
    $self->_queue_write($msg, $cv);
  } else {
    $self->{connect_cv} = AnyEvent->condvar unless (exists $self->{connect_cv});
    $cv = $self->{connect_cv};
  }
  return $cv if ($self->{handle});
  my $hd;
  $hd = $self->{handle} =
    AnyEvent::Handle->new(connect => [$self->{host}, $self->{port}],
                          on_error => sub {
                            my ($handle, $fatal, $message) = @_;
                            print STDERR "handle error $_[1]\n" if DEBUG;
                            $handle->destroy;
                            $self->_error($fatal, $message, 0);
                          },
                          # on_eof => ... no eof as there is no QUIT so
                          # there is always a waiting reader
                          on_timeout => sub {
                            $self->_error(0, $self->{wait}.' timeout', 1);
                            $self->{wait} = 'nothing';
                          },
                          on_connect => sub {
                            print STDERR "TCP handshake complete\n" if DEBUG;
                            my $msg =
                              Net::MQTT::Message->new(
                                message_type => MQTT_CONNECT,
                                keep_alive_timer => $self->{keep_alive_timer},
                                client_id => $self->{client_id},
                                clean_session => $self->{clean_session},
                                will_topic => $self->{will_topic},
                                will_qos => $self->{will_qos},
                                will_retain => $self->{will_retain},
                                will_message => $self->{will_message},
                              );
                            $self->_write_now($msg);
                            $hd->timeout($self->{timeout});
                            $self->{wait} = 'connack';
                            $hd->push_read(ref $self => sub {
                                             $self->_handle_message(@_);
                                             return;
                                           });
                          });
  return $cv
}

sub _reconnect {
  my $self = shift;
  print STDERR "reconnecting:\n" if DEBUG;
  $self->{clean_session} = 0;
  $self->connect(@_);
}

sub _handle_message {
  my ($self, $handle, $msg, $error) = @_;
  return $self->_error(0, $error, 1) if ($error);
  my $type = $msg->message_type;
  if ($type == MQTT_CONNACK) {
    $handle->timeout(undef);
    print STDERR "Connection ready:\n", $msg->string('  '), "\n" if DEBUG;
    $self->_write_now();
    $self->{connected} = 1;
    $self->{connect_cv}->send(1) if ($self->{connect_cv});
    delete $self->{connect_cv};
    $handle->on_drain(sub {
                        print STDERR "drained\n" if DEBUG;
                        my $w = $self->{_waiting};
                        $w->[1]->send(1) if (ref $w && defined $w->[1]);
                        $self->_write_now;
                        1;
                      });
    return
  }
  if ($type == MQTT_PINGRESP) {
    return $self->_keep_alive_received();
  }
  if ($type == MQTT_SUBACK) {
    print STDERR "Confirmed subscription:\n", $msg->string('  '), "\n" if DEBUG;
    $self->_confirm_subscription($msg->message_id, $msg->qos_levels->[0]);
    return
  }
  if ($type == MQTT_PUBLISH) {
    # TODO: handle puback, etc
    my $msg_topic = $msg->topic;
    my $msg_data = $msg->message;
    my $rec = $self->{_sub}->{$msg_topic};
    my %matched;
    if ($rec) {
      foreach my $cb (@{$rec->{cb}}) {
        next if ($matched{$cb}++);
        $cb->($msg_topic, $msg_data, $msg);
      }
    }
    foreach my $topic (keys %{$self->{_subre}}) {
      $rec = $self->{_subre}->{$topic};
      my $re = $rec->{re};
      next unless ($msg_topic =~ $re);
      foreach my $cb (@{$rec->{cb}}) {
        next if ($matched{$cb}++);
        $cb->($msg_topic, $msg_data, $msg);
      }
    }
    unless (scalar keys %matched) {
      carp "Unexpected publish:\n", $msg->string('  '), "\n";
    }
    return
  }
  print STDERR $msg->string(), "\n";
}

=method C<anyevent_read_type()>

This method is used to register an L<AnyEvent::Handle> read type
method to read MQTT messages.

=cut

sub anyevent_read_type {
  my ($handle, $cb) = @_;
  sub {
    my $rbuf = \$handle->{rbuf};
    return unless (defined $$rbuf);
    while (1) {
      my $msg = Net::MQTT::Message->new_from_bytes($$rbuf, 1);
      last unless ($msg);
      $cb->($handle, $msg);
    }
    return;
  };
}

1;

=head1 DISCLAIMER

This is B<not> official IBM code.  I work for IBM but I'm writing this
in my spare time (with permission) for fun.

=cut
