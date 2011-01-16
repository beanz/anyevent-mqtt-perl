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
     desc => q{subscribe /t1},
     recv => '82 08 00 01 00 03 2F 74 31 00',
     send => '90 03 00 01 00',
    },
    {
     desc => q{subscribe /t2},
     recv => '82 08 00 02 00 03 2F 74 32 00',
     send => '90 03 00 02 00',
    },
    {
     desc => q{publish /t1 message1},
     send => '30 0d 00 03 2f 74 31 6d 65 73  73 61 67 65 31',
    },
    {
     desc => q{pingreq trigger next publish},
     recv => 'C0 00',
     send => '30 0d 00 03 2f 74 31 6d 65 73  73 61 67 65 32',
    },
    {
     desc => q{publish /t2 message1},
     send => '30 0d 00 03 2f 74 32 6d 65 73  73 61 67 65 31',
    },
    {
     desc => q{pingreq trigger unsolicited publish},
     recv => 'C0 00',
     send => '30 0d 00 03 2f 74 33 6d 65 73  73 61 67 65 31',
    },
    {
     desc => q{publish /t1 message3},
     send => '30 0d 00 03 2f 74 31 6d 65 73  73 61 67 65 33',
    },
    {
     desc => q{pingreq trigger unsolicited suback},
     recv => 'C0 00',
     send => '90 03 00 03 00',
    },
    {
     desc => q{publish /t1 message4},
     send => '30 0d 00 03 2f 74 31 6d 65 73  73 61 67 65 34',
    },
    {
     desc => q{pingreq trigger ...},
     recv => 'C0 00',
    }
   ],
  );

my $cv = AnyEvent->condvar;

eval { test_server($cv, @connections) };
plan skip_all => "Failed to create dummy server: $@" if ($@);

my ($host,$port) = @{$cv->recv};
my $addr = join ':', $host, $port;

plan tests => 21;

use_ok('AnyEvent::MQTT');

my $mqtt = AnyEvent::MQTT->new(host => $host, port => $port,
                             client_id => 'acme_mqtt');

ok($mqtt, 'instantiate AnyEvent::MQTT object');

my $t1_cv = AnyEvent->condvar;
my $t1_sub = $mqtt->subscribe('/t1',
                            sub {
                              my ($topic, $message) = @_;
                              $t1_cv->send($topic.' '.$message);
                            });

my $t2_cv = AnyEvent->condvar;
my $t2_sub = $mqtt->subscribe('/t2',
                            sub {
                              my ($topic, $message) = @_;
                              $t2_cv->send($topic.' '.$message);
                            },
                            MQTT_QOS_AT_MOST_ONCE,
                           );

my $t2_dup_cv = AnyEvent->condvar;
my $t2_dup_sub = $mqtt->subscribe('/t2',
                            sub {
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
$mqtt->subscribe('/t1',
               sub {
                 my ($topic, $message) = @_;
                 $t1_dup_cv->send($topic.' '.$message);
               },
               MQTT_QOS_AT_MOST_ONCE, $t1_dup_sub);

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
   q{Got SubAck with no pending subscription for message id: 3},
   '... unsolicited message warning');
