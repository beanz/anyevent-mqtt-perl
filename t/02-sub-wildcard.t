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
     desc => q{subscribe /t/+},
     recv => '82 09 00 01 00 04 2F 74 2F 2B 00',
     send => '90 03 00 01 00',
    },
    {
     desc => q{subscribe /t/#},
     recv => '82 09 00 02 00 04 2F 74 2F 23 00',
     send => '90 03 00 02 00',
    },
    {
     desc => q{subscribe /t/+/s},
     recv => '82 0B 00 03 00 06 2F 74 2F 2B 2F 73 00',
     send => '90 03 00 03 00',
    },
    {
     desc => q{publish /t/a message1},
     send => '30 0e 00 04 2f 74 2f 61 6d 65 73  73 61 67 65 31',
    },
    {
     desc => q{pingreq trigger publish /t/a/s message2},
     recv => 'C0 00',
     send => '30 10 00 06 2f 74 2f 61 2f 73 6d 65 73  73 61 67 65 32',
    },
   ],
  );

my $cv = AnyEvent->condvar;

eval { test_server($cv, @connections) };
plan skip_all => "Failed to create dummy server: $@" if ($@);

my ($host,$port) = @{$cv->recv};
my $addr = join ':', $host, $port;

plan tests => 17;

use_ok('AnyEvent::MQTT');

my $mqtt = AnyEvent::MQTT->new(host => $host, port => $port,
                             client_id => 'acme_mqtt');

ok($mqtt, 'instantiate AnyEvent::MQTT object');

my %c;
my $t1_cv = AnyEvent->condvar;
my $t1_sub = $mqtt->subscribe(topic => '/t/+',
                              callback => sub {
                                my ($topic, $message) = @_;
                                $c{t1}++;
                                $t1_cv->send($topic.' '.$message);
                              });

my $t2_cv = AnyEvent->condvar;
my $t2_sub = $mqtt->subscribe(topic => '/t/#',
                              callback => sub {
                                my ($topic, $message) = @_;
                                $c{t2}++;
                                $t2_cv->send($topic.' '.$message);
                              },
                              qos => MQTT_QOS_AT_MOST_ONCE,
                             );

my $t3_cv = AnyEvent->condvar;
my $t3_sub = $mqtt->subscribe(topic => '/t/+/s',
                              callback => sub {
                                my ($topic, $message) = @_;
                                $c{t3}++;
                                $t3_cv->send($topic.' '.$message);
                              });

is($t1_sub->recv, 0, '... subscribe /t/+ complete');
is($t2_sub->recv, 0, '... subscribe /t/# complete');
is($t3_sub->recv, 0, '... subscribe /t/+/s complete');
is($t1_cv->recv, '/t/a message1', '... /t/+ received message1');
is($t2_cv->recv, '/t/a message1', '... /t/# received message1');

$t2_cv = AnyEvent->condvar;
$mqtt->_send(message_type => MQTT_PINGREQ); # ping to trigger server to cont.
is($t2_cv->recv, '/t/a/s message2', '... /t/# received message2');
is($t3_cv->recv, '/t/a/s message2', '... /t/+/s received message2');
is($c{t1}, 1, '... /t/+ call count');
is($c{t2}, 2, '... /t/# call count');
is($c{t3}, 1, '... /t/+/s call count');
