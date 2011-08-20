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
}

my @connections =
  (
   [
    [ packrecv => '10 17 00 06  4D 51 49 73   64 70 03 02  00 78 00 09
                   61 63 6D 65  5F 6D 71 74   74', q{connect} ],
    [ packsend => '20 02 00 00', q{connack} ],
    [ packrecv => '82 09 00 01  00 04 2F 74   2F 2B 00', q{subscribe /t/+} ],
    [ packsend => '90 03 00 01  00', q{suback /t/+} ],
    [ packrecv => '82 09 00 02  00 04 2F 74   2F 23 00', q{subscribe /t/#} ],
    [ packsend => '90 03 00 02  00', q{suback /t/#} ],
    [ packrecv => '82 09 00 03  00 04 2F 74   2F 61 00', q{subscribe /t/a} ],
    [ packsend => '90 03 00 03  00', q{suback /t/a} ],
    [ packsend => '30 0d 00 04  2f 74 2f 61   6d 65 73 73  61 67 65',
      q{publish /t/a message1} ],
   ],
  );

my $server;
eval { $server = AnyEvent::MockTCPServer->new(connections => \@connections); };
plan skip_all => "Failed to create dummy server: $@" if ($@);

my ($host, $port) = $server->connect_address;

plan tests => 12;

use_ok('AnyEvent::MQTT');

my $mqtt = AnyEvent::MQTT->new(host => $host, port => $port,
                               client_id => 'acme_mqtt');

ok($mqtt, 'instantiate AnyEvent::MQTT object');

my $cv = AnyEvent->condvar;
my $call_count = 0;
my $common_sub =
  sub {
    my ($topic, $message) = @_;
    $call_count++;
    $cv->send($topic.' '.$message);
  };
my $t1_sub = $mqtt->subscribe(topic => '/t/+', callback => $common_sub);
my $t2_sub = $mqtt->subscribe(topic => '/t/#', callback => $common_sub);
my $t3_sub = $mqtt->subscribe(topic => '/t/a' =>, callback => $common_sub);
my $t4_sub = $mqtt->subscribe(topic => '/t/a' =>, callback => $common_sub);
is($t1_sub->recv, 0, '... subscribe /t/+ complete');
is($t2_sub->recv, 0, '... subscribe /t/# complete');
is($t3_sub->recv, 0, '... subscribe /t/a complete');
is($t4_sub->recv, 0, '... subscribe dup /t/a complete');
is($cv->recv, '/t/a message', '... callback received message');
is($call_count, 1, '... callback called only once');
