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
  use t::Helpers qw/:all/;
}

my $published = AnyEvent->condvar;
my @connections =
  (
   [
    {
     desc => q{connect},
     recv => '10 17
              00 06 4D 51 49 73 64 70
              03 02 00 78
              00 09 61 63 6D 65 5F 6D 71 74 74',
     send => '20 02 00 00',
    },
    {
     desc => q{subscribe /t1},
     recv => '82 08 00 01 00 03 2F 74 31 02',
     send => '90 03 00 01 02',
    },
    {
     desc => q{publish /t1 message1},
     send => '34 0f 00 03 2f 74 31 00 01 6d 65 73  73 61 67 65 31',
    },
    {
     desc => q{pubrec -> pubrel},
     recv => '50 02 00 01',
     send => '60 02 00 01',
    },
    {
     desc => q{pubcomp},
     recv => '70 02 00 01',
     send => sub { $published->send(1) },
    },
   ],
  );

my $cv = AnyEvent->condvar;

eval { test_server($cv, @connections) };
plan skip_all => "Failed to create dummy server: $@" if ($@);

my ($host,$port) = @{$cv->recv};
my $addr = join ':', $host, $port;

plan tests => 9;

use_ok('AnyEvent::MQTT');

my $mqtt = AnyEvent::MQTT->new(host => $host, port => $port,
                               client_id => 'acme_mqtt');

ok($mqtt, 'instantiate AnyEvent::MQTT object');

$cv = AnyEvent->condvar;
my $sub = $mqtt->subscribe(topic => '/t1', qos => MQTT_QOS_EXACTLY_ONCE,
                           callback => sub {
                             my ($topic, $message) = @_;
                             $cv->send($topic.' '.$message);
                           });
is($sub->recv, MQTT_QOS_EXACTLY_ONCE, '... subscribe /t1 complete');
is($cv->recv, '/t1 message1', '... /t1 message1');
is($published->recv, 1, '... server complete');
