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
  eval { require AnyEvent::MockTCPServer; import AnyEvent::MockTCPServer };
  if ($@) {
    import Test::More skip_all => 'No AnyEvent::MockTCPServer module: '.$@;
  }
  import Test::More;
  use t::Helpers qw/test_warn/;
}

my @connections =
  (
   [
    [ packrecv => '10 17 00 06  4D 51 49 73   64 70 03 02  00 78 00 09
                   61 63 6D 65  5F 6D 71 74   74', 'connect' ],
    [ packsend => '20 02 00 00', 'connack' ],
    [ packrecv => '82 08 00 01  00 03 2F 74   31 00', q{subscribe /t1} ],
    [ packsend => '90 03 00 01  00', q{suback /t1} ],
    [ packsend => '30 0d 00 03  2f 74 31 6d   65 73 73 61  67 65 31',
      q{publish /t1 message1} ],
    [ packrecv => 'C0 00', q{pingreq trigger publish 2} ],
    [ packsend => '30 0d 00 03  2f 74 31 6d   65 73 73 61  67 65 32',
      q{publish /t1 message2} ],
    [ packrecv => 'C0 00', q{pingreq trigger publish 3} ],
    [ packsend => '30 0d 00 03  2f 74 31 6d   65 73 73 61  67 65 33',
      q{publish /t1 message3} ],
    [ packrecv => 'C0 00', q{pingreq trigger publish 4} ],
    [ packsend => '30 0d 00 03  2f 74 31 6d   65 73 73 61  67 65 34',
      q{publish /t1 message4} ],
    [ packrecv => 'A2 07 00 02  00 03 2F 74   31', q{unsubscribe /t1} ],
    [ packsend => 'B0 02 00 02', q{unsuback /t1} ],
   ],
  );

my $server;
eval { $server = AnyEvent::MockTCPServer->new(connections => \@connections); };
plan skip_all => "Failed to create dummy server: $@" if ($@);

my ($host, $port) = $server->connect_address;

plan tests => 22;

use_ok('AnyEvent::MQTT');

my $mqtt = AnyEvent::MQTT->new(host => $host, port => $port,
                               client_id => 'acme_mqtt');

ok($mqtt, 'instantiate AnyEvent::MQTT object');

my $t1_cv = AnyEvent->condvar;
my $cb1 = sub { my ($topic, $message) = @_; $t1_cv->send($topic.' '.$message) };
my $t1_sub = $mqtt->subscribe(topic => '/t1', callback => $cb1);

my $t2_cv = AnyEvent->condvar;
my $cb2 = sub { my ($topic, $message) = @_; $t2_cv->send($topic.' '.$message) };
my $t2_sub = $mqtt->subscribe(topic => '/t1', callback => $cb2);

is($t1_sub->recv, 0, '... 1st subscribe /t1 complete');
is($t2_sub->recv, 0, '... 2nd subscribe /t1 complete');
is($t1_cv->recv, '/t1 message1', '... 1st /t1 message1');
is($t2_cv->recv, '/t1 message1', '... 2nd /t1 message1');

$t1_cv = AnyEvent->condvar;
$t2_cv = AnyEvent->condvar;
my $t3_cv = AnyEvent->condvar;
my $cb3 = sub { my ($topic, $message) = @_; $t3_cv->send($topic.' '.$message) };
my $t3_sub = $mqtt->subscribe(topic => '/t1', callback => $cb3);
is($t3_sub->recv, 0, '... 3rd subscribe /t1 complete');

$mqtt->_send(message_type => MQTT_PINGREQ); # ping to trigger server to cont.
is($t1_cv->recv, '/t1 message2', '... 1st /t1 message2');
is($t2_cv->recv, '/t1 message2', '... 2nd /t1 message2');
is($t3_cv->recv, '/t1 message2', '... 3rd /t1 message2');

$t2_cv = AnyEvent->condvar;
$t3_cv = AnyEvent->condvar;

my $unsub_cv = $mqtt->unsubscribe(topic => '/t1', callback => $cb1);
is($unsub_cv->recv, 1, '... 1st /t1 unsubscribe');

$mqtt->_send(message_type => MQTT_PINGREQ); # ping to trigger server to cont.
is($t2_cv->recv, '/t1 message3', '... 2nd /t1 message3');
is($t3_cv->recv, '/t1 message3', '... 3rd /t1 message3');

$t2_cv = AnyEvent->condvar;
$t3_cv = AnyEvent->condvar;

$unsub_cv = $mqtt->unsubscribe(topic => '/t1', callback => $cb2);
is($unsub_cv->recv, 1, '... 2nd /t1 unsubscribe');

$mqtt->_send(message_type => MQTT_PINGREQ); # ping to trigger server to cont.
is($t3_cv->recv, '/t1 message4', '... 3rd /t1 message4');

$unsub_cv = $mqtt->unsubscribe(topic => '/t1', callback => $cb3);
is($unsub_cv->recv, 1, '... 3rd /t1 unsubscribe');
