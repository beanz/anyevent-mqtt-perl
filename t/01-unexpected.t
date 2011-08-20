#!/usr/bin/perl
#
# Copyright (C) 2011 by Mark Hindess

use strict;
use constant {
  DEBUG => $ENV{ANYEVENT_MQTT_TEST_DEBUG}
};
use Net::MQTT::Constants;
use Errno qw/EPIPE/;

$|=1;

BEGIN {
  require Test::More;
  $ENV{PERL_ANYEVENT_MODEL} = 'Perl' unless ($ENV{PERL_ANYEVENT_MODEL});
  eval { require AnyEvent; import AnyEvent;
         require AnyEvent::Socket; import AnyEvent::Socket };
  if ($@) {
    import Test::More skip_all => 'No AnyEvent::Socket module installed: $@';
  }
  eval { require AnyEvent::MockTCPServer; import AnyEvent::MockTCPServer };
  if ($@) {
    import Test::More skip_all => 'No AnyEvent::MockTCPServer module: '.$@;
  }
  import Test::More;
  use t::Helpers qw/test_warn/;
}

my $sent = AnyEvent->condvar;
my @connections =
  (
   [
    [ packrecv => '10 17 00 06  4D 51 49 73   64 70 03 02  00 78 00 09
                   61 63 6D 65  5F 6D 71 74   74', q{connect invalid message} ],
    [ packsend => '10 17 00 06  4d 51 49 73   64 70 03 02  00 78 00 09
                   61 63 6d 65  5f 6d 71 74   74', q{invalid message} ],
    [ packsend => '20 02 00 00', q{connack} ],
    [ packrecv => 'C0 00', q{pingreq trigger} ],
    [ packsend => '40 02 04 d2', q{puback} ],
    [ sleep => 0.1, q{wait} ],
    [ code => sub { $sent->send(1) }, q{sent} ],
    [ packrecv => 'C0 00', q{pingreq trigger} ],
    [ packsend => '70 02 04 d2', q{pubcomp} ],
    [ sleep => 0.1, q{wait} ],
    [ code => sub { $sent->send(1) }, q{sent} ],
    [ packrecv => 'C0 00', q{pingreq trigger} ],
    [ packsend => '60 02 04 d2', q{pubrel} ],
    [ sleep =>0.1, q{wait} ],
    [ code => sub { $sent->send(1) }, q{sent} ],
   ],
  );

my $server;
eval { $server = AnyEvent::MockTCPServer->new(connections => \@connections); };
plan skip_all => "Failed to create dummy server: $@" if ($@);

my ($host, $port) = $server->connect_address;

plan tests => 10;

use_ok('AnyEvent::MQTT');

my $mqtt =
  AnyEvent::MQTT->new(host => $host, port => $port, client_id => 'acme_mqtt');

ok($mqtt, 'instantiate AnyEvent::MQTT object');
my $cv = $mqtt->connect();
is(test_warn(sub { $cv->recv }),
   'Unsupported message Connect/at-most-once MQIsdp/3/acme_mqtt',
   'received unsupported message');

$mqtt->_send(message_type => MQTT_PINGREQ); # ping to trigger server to cont.
is(test_warn(sub { $sent->recv }),
   "Unexpected message for message id 1234\n  PubAck/at-most-once 1234",
   'received unexpected puback message');

$sent = AnyEvent->condvar;
$mqtt->_send(message_type => MQTT_PINGREQ); # ping to trigger server to cont.
is(test_warn(sub { $sent->recv }),
   "Unexpected message for message id 1234\n  PubComp/at-most-once 1234",
   'received unexpected pubcomp message');

$sent = AnyEvent->condvar;
$mqtt->_send(message_type => MQTT_PINGREQ); # ping to trigger server to cont.
is(test_warn(sub { $sent->recv }),
   "Unexpected message for message id 1234\n  PubRel/at-most-once 1234",
   'received unexpected pubrel message');
