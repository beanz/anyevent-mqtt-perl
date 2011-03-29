#!/usr/bin/perl
#
# Copyright (C) 2011 by Mark Hindess

use strict;
use constant {
  DEBUG => $ENV{ANYEVENT_MQTT_TEST_DEBUG}
};
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
  import Test::More;
  use t::Helpers qw/test_warn/;
  use t::MockServer qw/:all/;
}

my @connections =
  (
   [
    mockrecv('10 17 00 06  4D 51 49 73   64 70 03 02  00 78 00 09
              61 63 6D 65  5F 6D 71 74   74', 'connect'),
    mocksend('20 02 00 00', 'connack'),
    mockrecv('82 08 00 01  00 03 2F 74   31 00', q{subscribe /t1}),
    mocksend('90 03 00 01  00', q{suback /t1}),
    mockrecv('82 08 00 02  00 03 2F 74   32 00', q{subscribe /t2}),
    mocksend('90 03 00 02  00', q{suback /t2}),
    mocksend('30 0d 00 03  2f 74 31 6d   65 73 73 61  67 65 31',
             q{publish /t1 message1}),
    mockrecv('C0 00', q{pingreq trigger next publish}),
    mocksend('30 0d 00 03  2f 74 31 6d   65 73 73 61  67 65 32',
             q{pingreq triggering next publish}),
    mocksend('30 0d 00 03  2f 74 32 6d   65 73 73 61  67 65 31',
             q{publish /t2 message1}),
    mockrecv('C0 00', q{pingreq trigger unsolicited publish}),
    mocksend('30 0d 00 03  2f 74 33 6d   65 73 73 61  67 65 31',
             q{pingreq trigger unsolicited publish}),
    mocksend('30 0d 00 03  2f 74 31 6d   65 73 73 61  67 65 33',
             q{publish /t1 message3}),
    mockrecv('C0 00', q{pingreq trigger unsolicited suback}),
    mocksend('90 03 00 03  00', q{pingreq trigger unsolicited suback}),
    mocksend('30 0d 00 03  2f 74 31 6d   65 73 73 61  67 65 34',
             q{publish /t1 message4}),
    mockrecv('A2 07 00 03  00 03 2F 74   31', q{unsubscribe /t1}),
    mocksend('B0 02 00 10', q{unsolicited unsuback}),
    mocksend('B0 02 00 03', q{unsuback /t1}),
   ],
  );

my $server;
eval { $server = t::MockServer->new(@connections) };
plan skip_all => "Failed to create dummy server: $@" if ($@);

my ($host, $port) = $server->connect_address;

plan tests => 28;

use_ok('AnyEvent::MQTT');

my $mqtt = AnyEvent::MQTT->new(host => $host, port => $port,
                             client_id => 'acme_mqtt');

ok($mqtt, 'instantiate AnyEvent::MQTT object');

my $t1_cv = AnyEvent->condvar;
my $t1_sub = $mqtt->subscribe(topic => '/t1',
                              callback => sub {
                                my ($topic, $message) = @_;
                                $t1_cv->send($topic.' '.$message);
                              });

my $t2_cv = AnyEvent->condvar;
my $t2_sub = $mqtt->subscribe(topic => '/t2',
                              callback => sub {
                                my ($topic, $message) = @_;
                                $t2_cv->send($topic.' '.$message);
                              },
                              qos => MQTT_QOS_AT_MOST_ONCE,
                             );

my $t2_dup_cv = AnyEvent->condvar;
my $t2_dup_sub = $mqtt->subscribe(topic => '/t2',
                                  callback => sub {
                                    my ($topic, $message) = @_;
                                    $t2_dup_cv->send($topic.' '.$message);
                                  });

is($t1_sub->recv, 0, '... subscribe /t1 complete');
is($t2_sub->recv, 0, '... subscribe /t2 complete');
is($t2_dup_sub->recv, 0, '... subscribe /t2 dup complete');
is($t1_cv->recv, '/t1 message1', '... /t1 message1');

$t1_cv = AnyEvent->condvar;
my $t1_dup_cv = AnyEvent->condvar;
my $t1_dup_sub = AnyEvent->condvar;
$mqtt->subscribe(topic => '/t1',
                 callback => sub {
                   my ($topic, $message) = @_;
                   $t1_dup_cv->send($topic.' '.$message);
                 },
                 qos => MQTT_QOS_AT_MOST_ONCE, cv => $t1_dup_sub);

is($t1_dup_sub->recv, 0, '... subscribe /t1 dup complete');
$mqtt->_send(message_type => MQTT_PINGREQ); # ping to trigger server to cont.
is($t1_cv->recv, '/t1 message2', '... /t1 message2');
is($t1_dup_cv->recv, '/t1 message2', '... /t1 message2 dup callback');

is($t2_cv->recv, '/t2 message1', '... /t2 message1');
is($t2_dup_cv->recv, '/t2 message1', '... /t2 message1 dup callback');

$t1_cv = AnyEvent->condvar;
$t1_dup_cv = AnyEvent->condvar;
$mqtt->_send(message_type => MQTT_PINGREQ); # ping to trigger server to cont.

my $t1_msg;
my $warn = test_warn(sub { $t1_msg = $t1_cv->recv });
is($t1_msg, '/t1 message3', '... /t1 message3');

is($warn,
   q{Unexpected publish:
  Publish/at-most-once /t3 }.q{
  6d 65 73 73 61 67 65 31                          message1},
   '... unsolicited message warning');

$t1_cv = AnyEvent->condvar;
$t1_dup_cv = AnyEvent->condvar;
$mqtt->_send(message_type => MQTT_PINGREQ); # ping to trigger server to cont.

$warn = test_warn(sub { $t1_msg = $t1_cv->recv });
is($t1_msg, '/t1 message4', '... /t1 message4');

is($warn,
   q{SubAck with no pending subscription for message id: 3},
   '... unsolicited message warning');

my $unsub_cv = $mqtt->unsubscribe(topic => '/t1');
ok($unsub_cv, '... unsubscribe /t1');
my $dup_unsub_cv = AnyEvent->condvar;
$mqtt->unsubscribe(topic => '/t1',
                   qos => MQTT_QOS_AT_MOST_ONCE,
                   cv => $dup_unsub_cv);
ok($dup_unsub_cv, '... dup unsubscribe /t1');
my $unsub;
$warn = test_warn(sub { $unsub = $unsub_cv->recv });
is($warn,
   q{UnSubAck with no pending unsubscribe for message id: 16},
   '... unsolicited unsuback warning');
ok($unsub, '... unsubcribed /t1');
ok($dup_unsub_cv->recv, '... dup unsubscribe /t1');

$unsub_cv = $mqtt->unsubscribe(topic => '/t1');
ok(!$unsub_cv->recv, '... unsub with no sub');
