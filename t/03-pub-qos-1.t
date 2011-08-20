#!/usr/bin/perl
#
# Copyright (C) 2011 by Mark Hindess

use strict;
use constant {
  DEBUG => $ENV{ANYEVENT_MQTT_TEST_DEBUG}
};
use File::Temp qw/tempfile/;
use Net::MQTT::Constants;

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

my $published;
my @connections =
  (
   [
    [ packrecv => '10 17 00 06  4D 51 49 73   64 70 03 02  00 78 00 09
                   61 63 6D 65  5F 6D 71 74   74', q{connect} ],
    [ packsend => '20 02 00 00', q{connack} ],
    [ packrecv => '32 12 00 06  2F 74 6F 70   69 63 00 01  6D 65 73 73
                   61 67 65 31', q{publish} ],
    [ packsend => '40 02 00 01', q{puback} ],
    [ code => sub { $published->send(1) }, q{puback done} ],
    [ packrecv => '32 12 00 06  2F 74 6F 70   69 63 00 02  6D 65 73 73
                   61 67 65 32', q{publish} ],
    [ packrecv => 'C0 00', q{keepalive - pingreq} ],
    [ packsend => 'D0 00', q{keepalive - pingresp} ],
    [ packrecv => '3A 12 00 06  2F 74 6F 70   69 63 00 02  6D 65 73 73
                   61 67 65 32', q{publish} ],
    [ packsend => '50 02 00 02', q{pubrec} ],
    [ packsend => '40 02 00 02', q{puback} ],
    [ code => sub { $published->send(1) }, q{pubrec} ],
   ],
  );

my $server;
eval { $server = AnyEvent::MockTCPServer->new(connections => \@connections); };
plan skip_all => "Failed to create dummy server: $@" if ($@);

my ($host, $port) = $server->connect_address;

plan tests => 14;

use_ok('AnyEvent::MQTT');

my $mqtt = AnyEvent::MQTT->new(host => $host, port => $port,
                               client_id => 'acme_mqtt');

ok($mqtt, 'instantiate AnyEvent::MQTT object');

$published = AnyEvent->condvar;
my $cv = $mqtt->publish(message => 'message1', topic => '/topic',
                        qos => MQTT_QOS_AT_LEAST_ONCE);
ok($cv, 'simple message publish');
is($cv->recv, 1, '... client complete');
is($published->recv, 1, '... server complete');

$mqtt->{keep_alive_timer} = 0.1;
$published = AnyEvent->condvar;
$cv = $mqtt->publish(message => 'message2', topic => '/topic',
                     qos => MQTT_QOS_AT_LEAST_ONCE);
$mqtt->{keep_alive_timer} = 120;
ok($cv, 'message publish timeout and re-publish');
my $res;
is(test_warn(sub { $res = $cv->recv }),
   'Received PubRec but expected PubAck for message id 2',
   '... unexpected pubrec');
is($res, 1, '... client complete');
is($published->recv, 1, '... server complete');
