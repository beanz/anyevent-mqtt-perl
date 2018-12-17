use strict;
use warnings;
package AnyEvent::MQTT;
$AnyEvent::MQTT::VERSION = '1.172121';
# ABSTRACT: AnyEvent module for an MQTT client


use constant DEBUG => $ENV{ANYEVENT_MQTT_DEBUG};
use AnyEvent;
use AnyEvent::Handle;
use Net::MQTT::Constants;
use Net::MQTT::Message;
use Net::MQTT::TopicStore;
use Carp qw/croak carp/;
use Sub::Name;
use Scalar::Util qw/weaken/;


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
           handle_args => [],
           write_queue => [],
           inflight => {},
           _sub_topics => Net::MQTT::TopicStore->new(),
           %p,
          }, $pkg;
}

sub DESTROY {
  $_[0]->cleanup;
}


sub cleanup {
  my $self = shift;
  print STDERR "cleanup\n" if DEBUG;
  if ($self->{handle}) {
    my $cv = AnyEvent->condvar;
    my $handle = $self->{handle};
    weaken $handle;
    $cv->cb(sub { $handle->destroy });
    $self->_send(message_type => MQTT_DISCONNECT, cv => $cv);
  }
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


sub publish {
  my ($self, %p) = @_;
  my $topic = exists $p{topic} ? $p{topic} :
    croak ref $self, '->publish requires "topic" parameter';
  my $qos = exists $p{qos} ? $p{qos} : MQTT_QOS_AT_MOST_ONCE;
  my $cv = exists $p{cv} ? delete $p{cv} : AnyEvent->condvar;
  my $expect;
  if ($qos) {
    $expect = ($qos == MQTT_QOS_AT_LEAST_ONCE ? MQTT_PUBACK : MQTT_PUBREC);
  }
  my $message = $p{message};
  if (defined $message) {
    print STDERR "publish: message[$message] => $topic\n" if DEBUG;
    $self->_send_with_ack({
                           message_type => MQTT_PUBLISH,
                           %p,
                          }, $cv, $expect);
    return $cv;
  }
  my $handle = exists $p{handle} ? $p{handle} :
    croak ref $self, '->publish requires "message" or "handle" parameter';
  unless ($handle->isa('AnyEvent::Handle')) {
    my @args = @{$p{handle_args}||[]};
    print STDERR "publish: IO[$handle] => $topic @args\n" if DEBUG;
    $handle = AnyEvent::Handle->new(fh => $handle, @args);
  }
  my $error_sub = $handle->{on_error}; # Hack: There is no accessor api
  $handle->on_error(subname 'on_error_for_read_publish_'.$topic =>
                    sub {
                      my ($hdl, $fatal, $msg) = @_;
                      $error_sub->(@_) if ($error_sub);
                      $hdl->destroy;
                      undef $hdl;
                      $cv->send(1);
                    });
  my $weak_self = $self;
  weaken $weak_self;
  my @push_read_args = @{$p{push_read_args}||['line']};
  my $sub; $sub = subname 'push_read_cb_for_'.$topic => sub {
    my ($hdl, $chunk, @args) = @_;
    print STDERR "publish: $chunk => $topic\n" if DEBUG;
    my $send_cv = AnyEvent->condvar;
    print STDERR "publish: message[$chunk] => $topic\n" if DEBUG;
    $weak_self->_send_with_ack({
                           message_type => MQTT_PUBLISH,
                           qos => $qos,
                           retain => $p{retain},
                           topic => $topic,
                           message => $chunk,
                          }, $send_cv, $expect);
    $send_cv->cb(subname 'publish_ack_'.$topic =>
                 sub { $handle->push_read(@push_read_args => $sub ) });
    return;
  };
  $handle->push_read(@push_read_args => $sub);
  return $cv;
}


sub next_message_id {
  my $self = shift;
  my $res = $self->{message_id};
  $self->{message_id}++;
  $self->{message_id} %= 65536;
  $res;
}

sub _send_with_ack {
  my ($self, $args, $cv, $expect, $dup) = @_;
  if ($args->{qos}) {
    unless (exists $args->{message_id}) {
      $args->{message_id} = $self->next_message_id();
    }
    my $mid = $args->{message_id};
    my $send_cv = AnyEvent->condvar;
    $send_cv->cb(subname 'ack_cb_for_'.$mid => sub {
                   $self->{inflight}->{$mid} =
                     {
                      expect => $expect,
                      message => $args,
                      cv => $cv,
                      timeout =>
                        AnyEvent->timer(after => $self->{keep_alive_timer},
                                        cb => subname 'ack_timeout_for_'.$mid =>
                                        sub {
                          print ref $self, " timeout waiting for ",
                            message_type_string($expect), "\n" if DEBUG;
                          delete $self->{inflight}->{$mid};
                          $self->_send_with_ack($args, $cv, $expect, 1);
                        }),
                     };
                   });
    $args->{cv} = $send_cv;
  } else {
    $args->{cv} = $cv;
  }
  $args->{dup} = 1 if ($dup);
  return $self->_send(%$args);
}


sub subscribe {
  my ($self, %p) = @_;
  my $topic = exists $p{topic} ? $p{topic} :
    croak ref $self, '->subscribe requires "topic" parameter';
  my $sub = exists $p{callback} ? $p{callback} :
    croak ref $self, '->subscribe requires "callback" parameter';
  my $qos = exists $p{qos} ? $p{qos} : MQTT_QOS_AT_MOST_ONCE;
  my $cv = exists $p{cv} ? delete $p{cv} : AnyEvent->condvar;
  my $mid = $self->_add_subscription($topic, $cv, $sub);
  if (defined $mid) { # not already subscribed/subscribing
    $self->_send(message_type => MQTT_SUBSCRIBE,
                 message_id => $mid,
                 topics => [[$topic, $qos]]);
  }
  $cv
}


sub unsubscribe {
  my ($self, %p) = @_;
  my $topic = exists $p{topic} ? $p{topic} :
    croak ref $self, '->unsubscribe requires "topic" parameter';
  my $cv = exists $p{cv} ? delete $p{cv} : AnyEvent->condvar;
  my $mid = $self->_remove_subscription($topic, $cv, $p{callback});
  if (defined $mid) { # not already subscribed/subscribing
    $self->_send(message_type => MQTT_UNSUBSCRIBE,
                 message_id => $mid,
                 topics => [$topic]);
  }
  $cv
}

sub _add_subscription {
  my ($self, $topic, $cv, $sub) = @_;
  my $rec = $self->{_sub}->{$topic};
  if ($rec) {
    print STDERR "Add $sub to existing $topic subscription\n" if DEBUG;
    $rec->{cb}->{$sub} = $sub;
    $cv->send($rec->{qos});
    foreach my $msg (values %{$rec->{retained}}) {
      $sub->($msg->topic, $msg->message, $msg);
    }
    return;
  }
  $rec = $self->{_sub_pending}->{$topic};
  if ($rec) {
    print STDERR "Add $sub to existing pending $topic subscription\n" if DEBUG;
    $rec->{cb}->{$sub} = $sub;
    push @{$rec->{cv}}, $cv;
    return;
  }
  my $mid = $self->next_message_id();
  print STDERR "Add $sub as pending $topic subscription (mid=$mid)\n" if DEBUG;
  $self->{_sub_pending_by_message_id}->{$mid} = $topic;
  $self->{_sub_pending}->{$topic} =
    { cb => { $sub => $sub }, cv => [ $cv ], retained => {} };
  $mid;
}

sub _remove_subscription {
  my ($self, $topic, $cv, $sub) = @_;
  my $rec = $self->{_unsub_pending}->{$topic};
  if ($rec) {
    print STDERR "Remove of $topic with pending unsubscribe\n" if DEBUG;
    push @{$rec->{cv}}, $cv;
    return;
  }
  $rec = $self->{_sub}->{$topic};
  unless ($rec) {
    print STDERR "Remove of $topic with no subscription\n" if DEBUG;
    $cv->send(0);
    return;
  }

  if (defined $sub) {
    unless (exists $rec->{cb}->{$sub}) {
      print STDERR "Remove of $topic for $sub with no subscription\n"
        if DEBUG;
      $cv->send(0);
      return;
    }
    delete $rec->{cb}->{$sub};
    if (keys %{$rec->{cb}}) {
      print STDERR "Remove of $topic for $sub\n" if DEBUG;
      $cv->send(1);
      return;
    }
  }
  print STDERR "Remove of $topic\n" if DEBUG;
  my $mid = $self->next_message_id();
  delete $self->{_sub}->{$topic};
  $self->{_sub_topics}->delete($topic);
  $self->{_unsub_pending_by_message_id}->{$mid} = $topic;
  $self->{_unsub_pending}->{$topic} = { cv => [ $cv ] };
  return $mid;
}

sub _confirm_subscription {
  my ($self, $mid, $qos) = @_;
  my $topic = delete $self->{_sub_pending_by_message_id}->{$mid};
  unless (defined $topic) {
    carp 'SubAck with no pending subscription for message id: ', $mid, "\n";
    return;
  }
  my $rec = $self->{_sub}->{$topic} = delete $self->{_sub_pending}->{$topic};
  $self->{_sub_topics}->add($topic);
  $rec->{qos} = $qos;

  foreach my $cv (@{$rec->{cv}}) {
    $cv->send($qos);
  }
  delete $rec->{cv};
}

sub _confirm_unsubscribe {
  my ($self, $mid) = @_;
  my $topic = delete $self->{_unsub_pending_by_message_id}->{$mid};
  unless (defined $topic) {
    carp 'UnSubAck with no pending unsubscribe for message id: ', $mid, "\n";
    return;
  }
  my $rec = delete $self->{_unsub_pending}->{$topic};
  foreach my $cv (@{$rec->{cv}}) {
    $cv->send(1);
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
  print STDERR 'Queuing: ', ($cv||'no cv'), ' ', $msg->string, "\n" if DEBUG;
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
  $self->{message_log_callback}->('>', $msg) if ($self->{message_log_callback});
  $self->{_waiting} = [$msg, $cv];
  print '  ', (unpack 'H*', $msg->bytes), "\n" if DEBUG;
  $self->{handle}->push_write($msg->bytes);
  $cv;
}

sub _reset_keep_alive_timer {
  my ($self, $wait) = @_;
  undef $self->{_keep_alive_handle};
  my $method = $wait ? '_keep_alive_timeout' : '_send_keep_alive';
  $self->{_keep_alive_waiting} = $wait;
  my $weak_self = $self;
  weaken $weak_self;
  $self->{_keep_alive_handle} =
    AnyEvent->timer(after => $self->{keep_alive_timer},
                    cb => subname((substr $method, 1).'_cb' =>
                                  sub { $weak_self->$method(@_) }));
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

  my $weak_self = $self;
  weaken $weak_self;

  my $hd;
  $hd = $self->{handle} =
    AnyEvent::Handle->new(connect => [$self->{host}, $self->{port}],
                          on_error => subname('on_error_cb' => sub {
                            my ($handle, $fatal, $message) = @_;
                            print STDERR "handle error $_[1]\n" if DEBUG;
                            $handle->destroy;
                            $weak_self->_error($fatal, 'Error: '.$message, 0);
                          }),
                          on_eof => subname('on_eof_cb' => sub {
                            my ($handle) = @_;
                            print STDERR "handle eof\n" if DEBUG;
                            $handle->destroy;
                            $weak_self->_error(1, 'EOF', 1);
                          }),
                          on_timeout => subname('on_timeout_cb' => sub {
                            $weak_self->_error(0, $weak_self->{wait}.' timeout', 1);
                            $weak_self->{wait} = 'nothing';
                          }),
                          on_connect => subname('on_connect_cb' => sub {
                            my ($handle, $host, $port, $retry) = @_;
                            print STDERR "TCP handshake complete\n" if DEBUG;
                            # call user-defined on_connect function.
                            $weak_self->{on_connect}->($handle, $retry) if $weak_self->{on_connect};
                            my $msg =
                              Net::MQTT::Message->new(
                                message_type => MQTT_CONNECT,
                                keep_alive_timer => $weak_self->{keep_alive_timer},
                                client_id => $weak_self->{client_id},
                                clean_session => $weak_self->{clean_session},
                                will_topic => $weak_self->{will_topic},
                                will_qos => $weak_self->{will_qos},
                                will_retain => $weak_self->{will_retain},
                                will_message => $weak_self->{will_message},
                                user_name => $weak_self->{user_name},
                                password => $weak_self->{password},
                              );
                            $weak_self->_write_now($msg);
                            $handle->timeout($weak_self->{timeout});
                            $weak_self->{wait} = 'connack';
                            $handle->on_read(subname 'on_read_cb' => sub {
                              my ($hdl) = @_;
                              $hdl->push_read(ref $weak_self =>
                                              subname 'reader_cb' => sub {
                                                $weak_self->_handle_message(@_);
                                                1;
                                              });
                            });
                          }),
                          @{$self->{handle_args}},
                         );
  return $cv
}

sub _reconnect {
  my $self = shift;
  print STDERR "reconnecting:\n" if DEBUG;
  $self->{clean_session} = 0;
  $self->connect(@_);
}

sub _handle_message {
  my $self = shift;
  my ($handle, $msg, $error) = @_;
  return $self->_error(0, $error, 1) if ($error);
  $self->{message_log_callback}->('<', $msg) if ($self->{message_log_callback});
  $self->_call_callback('before_msg_callback' => $msg) or return;
  my $msg_type = lc ref $msg;
  $msg_type =~ s/^.*:://;
  $self->_call_callback('before_'.$msg_type.'_callback' => $msg) or return;
  my $method = '_process_'.$msg_type;
  unless ($self->can($method)) {
    carp 'Unsupported message ', $msg->string(), "\n";
    return;
  }
  my $res = $self->$method(@_);
  $self->_call_callback('after_'.$msg_type.'_callback' => $msg, $res);
  $res;
}

sub _call_callback {
  my $self = shift;
  my $cb_name = shift;
  return 1 unless (exists $self->{$cb_name});
  $self->{$cb_name}->(@_);
}

sub _process_connack {
  my ($self, $handle, $msg, $error) = @_;
  $handle->timeout(undef);
  unless ($msg->return_code == MQTT_CONNECT_ACCEPTED) {
    return $self->_error(1, 'Connection refused: '.$msg->string, 0);
  }
  print STDERR "Connection ready:\n", $msg->string('  '), "\n" if DEBUG;
  $self->_write_now();
  $self->{connected} = 1;
  $self->{connect_cv}->send(1) if ($self->{connect_cv});
  delete $self->{connect_cv};

  my $weak_self = $self;
  weaken $weak_self;

  $handle->on_drain(subname 'on_drain_cb' => sub {
                      print STDERR "drained\n" if DEBUG;
                      my $w = $weak_self->{_waiting};
                      $w->[1]->send(1) if (ref $w && defined $w->[1]);
                      $weak_self->_write_now;
                      1;
                    });
  return
}

sub _process_pingresp {
  shift->_keep_alive_received();
}

sub _process_suback {
  my ($self, $handle, $msg, $error) = @_;
  print STDERR "Confirmed subscription:\n", $msg->string('  '), "\n" if DEBUG;
  $self->_confirm_subscription($msg->message_id, $msg->qos_levels->[0]);
  return
}

sub _process_unsuback {
  my ($self, $handle, $msg, $error) = @_;
  print STDERR "Confirmed unsubscribe:\n", $msg->string('  '), "\n" if DEBUG;
  $self->_confirm_unsubscribe($msg->message_id);
  return
}

sub _publish_locally {
  my ($self, $msg) = @_;
  my $msg_topic = $msg->topic;
  my $msg_data = $msg->message;
  my $matches = $self->{_sub_topics}->values($msg_topic);
  unless (scalar @$matches) {
    carp "Unexpected publish:\n", $msg->string('  '), "\n";
    return;
  }
  my %matched;
  my $msg_retain = $msg->retain;
  foreach my $topic (@$matches) {
    my $rec = $self->{_sub}->{$topic};
    if ($msg_retain) {
      if ($msg_data eq '') {
        delete $rec->{retained}->{$msg_topic};
        print STDERR "  retained cleared\n" if DEBUG;
      } else {
        $rec->{retained}->{$msg_topic} = $msg;
        print STDERR "  retained '", $msg_data, "'\n" if DEBUG;
      }
    }
    foreach my $cb (values %{$rec->{cb}}) {
      next if ($matched{$cb}++);
      $cb->($msg_topic, $msg_data, $msg);
    }
  }
  1;
}

sub _process_publish {
  my ($self, $handle, $msg, $error) = @_;
  my $qos = $msg->qos;
  if ($qos == MQTT_QOS_EXACTLY_ONCE) {
    my $mid = $msg->message_id;
    $self->{messages}->{$mid} = $msg;
    $self->_send(message_type => MQTT_PUBREC, message_id => $mid);
    return;
  }
  $self->_publish_locally($msg);
  $self->_send(message_type => MQTT_PUBACK, message_id => $msg->message_id)
    if ($qos == MQTT_QOS_AT_LEAST_ONCE);
  return
}

sub _inflight_record {
  my ($self, $msg) = @_;
  my $mid = $msg->message_id;
  unless (exists $self->{inflight}->{$mid}) {
    carp "Unexpected message for message id $mid\n  ".$msg->string;
    return;
  }
  my $exp_type = $self->{inflight}->{$mid}->{expect};
  my $got_type = $msg->message_type;
  unless ($got_type == $exp_type) {
    carp 'Received ', message_type_string($got_type), ' but expected ',
      message_type_string($exp_type), " for message id $mid\n";
    return;
  }
  return delete $self->{inflight}->{$mid};
}

sub _process_puback {
  my ($self, $handle, $msg, $error) = @_;
  my $rec = $self->_inflight_record($msg) or return;
  my $mid = $msg->message_id;
  print STDERR 'PubAck: ', $mid, ' ', $rec->{cv}, "\n" if DEBUG;
  $rec->{cv}->send(1);
  return 1;
}

sub _process_pubrec {
  my ($self, $handle, $msg, $error) = @_;
  my $rec = $self->_inflight_record($msg) or return;
  my $mid = $msg->message_id;
  print STDERR 'PubRec: ', $mid, ' ', $rec->{cv}, "\n" if DEBUG;
  $self->_send_with_ack({
                           message_type => MQTT_PUBREL,
                           qos => MQTT_QOS_AT_LEAST_ONCE,
                           message_id => $mid,
                          }, $rec->{cv}, MQTT_PUBCOMP);
}

sub _process_pubrel {
  my ($self, $handle, $msg, $error) = @_;
  my $mid = $msg->message_id;
  print STDERR 'PubRel: ', $mid, "\n" if DEBUG;
  my $pubmsg = delete $self->{messages}->{$mid};
  unless ($pubmsg) {
    carp "Unexpected message for message id $mid\n  ".$msg->string;
    return;
  }
  $self->_publish_locally($pubmsg);
  $self->_send(message_type => MQTT_PUBCOMP, message_id => $mid);
}

sub _process_pubcomp {
  my ($self, $handle, $msg, $error) = @_;
  my $rec = $self->_inflight_record($msg) or return;
  my $mid = $msg->message_id;
  print STDERR 'PubComp: ', $mid, ' ', $rec->{cv}, "\n" if DEBUG;
  $rec->{cv}->send(1);
  return 1;
}


sub anyevent_read_type {
  my ($handle, $cb) = @_;
  subname 'anyevent_read_type_reader' => sub {
    my ($handle) = @_;
    my $rbuf = \$handle->{rbuf};
    weaken $rbuf;
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

__END__

=pod

=encoding UTF-8

=head1 NAME

AnyEvent::MQTT - AnyEvent module for an MQTT client

=head1 VERSION

version 1.172121

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
  $cv = $mqtt->publish(message => 'simple message',
                          topic => '/topic');
  $cv->recv; # sent

  # publish line-by-line from file handle
  $cv =  $mqtt->publish(handle => \*STDIN,
                        topic => '/topic');
  $cv->recv; # sent

  # publish from AnyEvent::Handle
  $cv = $mqtt->publish(handle => AnyEvent::Handle->new(my %handle_args),
                       topic => '/topic');
  $cv->recv; # sent

=head1 DESCRIPTION

AnyEvent module for MQTT client.

B<IMPORTANT:> This is an early release and the API is still subject to
change.

=head1 METHODS

=head2 C<new(%params)>

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

=item C<user_name>

The user name for the MQTT broker.

=item C<password>

The password for the MQTT broker.

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
is C<NetMQTTpmNNNNN> where NNNNN is the current process id.

=item C<message_log_callback>

Defines a callback to call on every message.

=item C<on_error>

Defines a callback to call when some error occurs.

Two parameters are passed to the callback.

    $on_error->($fatal, $message)

where C<$fatal> is a boolean flag and C<$message> is the error message.
If the error is fatal, C<$fatal> is true.

=item C<handle_args>

  a reference to a list to pass as arguments to the
  L<AnyEvent::Handle> constructor (defaults to
  an empty list reference).

=back

=head2 C<cleanup()>

This method attempts to destroy any resources in the event of a
disconnection or fatal error.

=head2 C<publish( %parameters )>

This method is used to publish to a given topic.  It returns an
L<AnyEvent condvar|AnyEvent/"CONDITION VARIABLES"> which is notified
when the publish is complete (written to the kernel or ack'd depending
on the QoS level).  The parameter hash must included at least a
B<topic> value and one of:

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

=head2 C<next_message_id()>

Returns a 16-bit number to use as the next message id in a message requiring
an acknowledgement.

=head2 C<subscribe( %parameters )>

This method subscribes to the given topic.  The parameter hash
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

=head2 C<unsubscribe( %parameters )>

This method unsubscribes to the given topic.  The parameter hash
may contain values for the following keys:

=over

=item B<topic>

  for the topic to unsubscribe from (this is required),

=item B<callback>

  for the callback to call with messages (this is optional and currently
  not supported - all callbacks are unsubscribed),

=item B<cv>

  L<AnyEvent> condvar to use to signal the unsubscription is complete.

=back

This method returns the value of the B<cv> parameter if it was
supplied or an L<AnyEvent> condvar created for this purpose.

=head2 C<connect( [ $msg ] )>

This method starts the connection to the server.  It will be called
lazily when required publish or subscribe so generally is should not
be necessary to call it directly.

=head2 C<anyevent_read_type()>

This method is used to register an L<AnyEvent::Handle> read type
method to read MQTT messages.

=head1 DISCLAIMER

This is B<not> official IBM code.  I work for IBM but I'm writing this
in my spare time (with permission) for fun.

=head1 AUTHOR

Mark Hindess <soft-cpan@temporalanomaly.com>

=head1 COPYRIGHT AND LICENSE

This software is copyright (c) 2014 by Mark Hindess.

This is free software; you can redistribute it and/or modify it under
the same terms as the Perl 5 programming language system itself.

=cut
