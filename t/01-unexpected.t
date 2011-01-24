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
  import Test::More;
  use t::Helpers qw/:all/;
}

my $sent = AnyEvent->condvar;
my @connections =
  (
   [
    {
     desc => q{connect invalid message},
     recv => '101700064D514973647003020078000961636D655F6D717474',
     send => '101700064d514973647003020078000961636d655f6d717474',
    },
    {
     desc => q{connack},
     send => '20020000',
    },
    {
     desc => q{puback},
     recv => 'C0 00',
     send => '4002 04d2',
    },
    {
     desc => q{wait},
     sleep => 0.1,
    },
    {
     desc => q{sent},
     send => sub { $sent->send(1) },
    },
    {
     desc => q{pubcomp},
     recv => 'C0 00',
     send => '7002 04d2',
    },
    {
     desc => q{wait},
     sleep => 0.1,
    },
    {
     desc => q{sent},
     send => sub { $sent->send(1) },
    },
    {
     desc => q{pubrel},
     recv => 'C0 00',
     send => '6002 04d2',
    },
    {
     desc => q{wait},
     sleep => 0.1,
    },
    {
     desc => q{sent},
     send => sub { $sent->send(1) },
    },
   ],
  );

my $cv = AnyEvent->condvar;

eval { test_server($cv, @connections) };
plan skip_all => "Failed to create dummy server: $@" if ($@);

my ($host,$port) = @{$cv->recv};
my $addr = join ':', $host, $port;

plan tests => 10;

use_ok('AnyEvent::MQTT');

my $mqtt =
  AnyEvent::MQTT->new(host => $host, port => $port, client_id => 'acme_mqtt');

ok($mqtt, 'instantiate AnyEvent::MQTT object');
$cv = $mqtt->connect();
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
