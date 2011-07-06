use strict;
use warnings;
package AnyEvent::MQTT::Server;

# ABSTRACT: AnyEvent module for an MQTT server

=head1 SYNOPSIS

  use AnyEvent::MQTT::Server;
  my $mqtt = AnyEvent::MQTT::Server->new;
  $mqtt->all_cv->recv; # main loop

=head1 DESCRIPTION

AnyEvent module for MQTT server.

B<IMPORTANT:> This is an early release and the API is still subject to
change.

=head1 DISCLAIMER

This is B<not> official IBM code.  I work for IBM but I'm writing this
in my spare time (with permission) for fun.

=cut

use constant DEBUG => $ENV{ANYEVENT_MQTT_DEBUG};
use AnyEvent;
use AnyEvent::Handle;
use AnyEvent::Socket;
use Net::MQTT::Constants;
use Net::MQTT::Message;
use Carp qw/croak carp/;
use Sub::Name;
use Scalar::Util qw/weaken/;

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

=item C<message_log_callback>

Defines a callback to call on every message.

=back

=cut

sub new {
  my ($pkg, %p) = @_;
  my $self =
    bless {
           socket => undef,
           host => undef,
           port => '1883',
           timeout => 30,
           message_id => 1,
           inflight => {},
           %p,
          }, $pkg;

  unless ($self->{socket}) {
    $self->{socket} =
      tcp_server $self->{host}, $self->{port}, sub { $self->_accept(@_) },
        sub { print STDERR "listening\n" if DEBUG; return 0 };
  }
  $self
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
  $self->{handle}->destroy if ($self->{handle});
  delete $self->{handle};
  delete $self->{connected};
  delete $self->{wait};
  $self->{write_queue} = [];
}

sub _error {
  my ($self, $fatal, $message, $reconnect) = @_;
  $self->cleanup($message);
  $self->{on_error}->($fatal, $message) if ($self->{on_error});
  $self->_reconnect() if ($reconnect);
}

sub _accept {
  my ($self, $fh, $host, $port) = @_;

  my $weak_self = $self;
  weaken $weak_self;

  print STDERR "new client $host:$port\n" if DEBUG;
  my $hd;
  $hd = AnyEvent::Handle->new(fh => $fh,
                              on_error => subname('client_on_error_cb' => sub {
                                my ($handle, $fatal, $message) = @_;
                                print STDERR "handle error $_[1]\n" if DEBUG;
                                $handle->destroy;
                                $weak_self->_error($fatal, 'Error: '.$message,
                                                   0);
                              }));
  my $rec = $self->{_client}->{$hd} =
    {
     filehandle => $fh,
     handle => $hd,
     addr => $host.':'.$port,
     name => $host.':'.$port,
    };
  $hd->push_read(ref $weak_self =>
                 subname 'client_reader_cb' => sub {
                   $weak_self->_handle_message(@_);
                   return;
                 });
}

sub _handle_message {
  my $self = shift;
  my ($handle, $msg, $error) = @_;
  my $client = $self->{_client}->{$handle};
  return $self->_error(0, $error, 1) if ($error);
  $self->{message_log_callback}->(($client->{name}||$client->{addr}), '<', $msg)
    if ($self->{message_log_callback});
  my $method = lc ref $msg;
  $method =~ s/.*::/_process_/;
  unless ($self->can($method)) {
    carp 'Unsupported message ', $msg->string(), "\n";
    return;
  }
  $self->$method($client, @_);
}

sub _send_with_ack {
  my ($self, $client, $args, $cv, $expect, $dup) = @_;
  if ($args->{qos}) {
    unless (exists $args->{message_id}) {
      $args->{message_id} = $self->{message_id}++;
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

sub _process_connect {
  my ($self, $client, $handle, $msg) = @_;
  print STDERR "connect ", $client->{addr}, " => ", $msg->client_id, "\n"
    if DEBUG;
  $client->{name} = $msg->client_id;
  $self->_write($client, message_type => MQTT_CONNACK);
}

sub _process_subscribe {
  my ($self, $client, $handle, $msg) = @_;
  print STDERR "subscribe ", $client->{name}, " ", $msg, "\n" if DEBUG;
  my @qos = ();
  foreach my $rec (@{$msg->topics}) {
    my ($topic, $qos) = @$rec;
    my $re = topic_to_regexp($topic); # convert MQTT pattern to regexp
    if ($re) {
      $self->{_subre}->{$topic}->{re} = $re;
      $self->{_subre}->{$topic}->{c}->{$client} = [$client, $qos];
    } else {
      $self->{_sub}->{$topic}->{$client} = [$client, $qos];
    }
    push @qos, $qos;
  }
  $self->_write($client,
                message_type => MQTT_SUBACK,
                message_id => $msg->message_id,
                qos_levels => \@qos);
}

sub _process_publish {
  my ($self, $client, $handle, $msg) = @_;
  print STDERR "publish ", $client->{name}, " ", $msg, "\n" if DEBUG;
  my $topic = $msg->topic;
  foreach my $c (keys %{$self->{_sub}->{$topic}||{}}) {
    my ($subclient, $qos) = @{$self->{_sub}->{$topic}->{$c}};
    $self->_write($subclient,
                  message_type => MQTT_PUBLISH,
                  qos => ($msg->qos < $qos ? $msg->qos : $qos),
                  message_id => $msg->message_id,
                  topic => $msg->topic,
                  message => $msg->message);
  }
  foreach my $topic (keys %{$self->{_subre}||{}}) {
    my $rec = $self->{_subre}->{$topic};
    my $re = $rec->{re};
    next unless ($topic =~ $re);
    foreach my $c (keys %{$rec->{c}}) {
      my ($subclient, $qos) = @{$rec->{c}->{$c}};
      $self->_write($subclient,
                    message_type => MQTT_PUBLISH,
                    qos => ($msg->qos < $qos ? $msg->qos : $qos),
                    message_id => $msg->message_id,
                    topic => $msg->topic,
                    message => $msg->message);
    }
  }

  if ($msg->qos == MQTT_QOS_AT_LEAST_ONCE) {
    $self->_write($client,
                  message_type => MQTT_PUBACK,
                  message_id => $msg->message_id);
  }
}

sub _process_puback {
  my ($self, $client, $handle, $msg) = @_;
  print STDERR "puback ", $client->{name}, " ", $msg, "\n" if DEBUG;
}

sub _process_pingreq {
  my ($self, $client, $handle, $msg) = @_;
  print STDERR "pingreq ", $client->{name}, " ", $msg, "\n" if DEBUG;
  $self->_write($client, message_type => MQTT_PINGRESP);
}

sub _write {
  my ($self, $client, %p) = @_;
  my $msg = Net::MQTT::Message->new(%p);
  print STDERR "Sending ", $client->{name}, ": ", $msg->string, "\n" if DEBUG;
  $self->{message_log_callback}->($client->{name}, '>', $msg)
    if ($self->{message_log_callback});
  print '  ', (unpack 'H*', $msg->bytes), "\n" if DEBUG;
  $client->{handle}->push_write($msg->bytes);
}

=method C<anyevent_read_type()>

This method is used to register an L<AnyEvent::Handle> read type
method to read MQTT messages.

=cut

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

=head1 DISCLAIMER

This is B<not> official IBM code.  I work for IBM but I'm writing this
in my spare time (with permission) for fun.

=cut
