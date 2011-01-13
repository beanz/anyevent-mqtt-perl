#!/usr/bin/perl
#
# Copyright (C) 2011 by Mark Hindess

use strict;
use constant {
  DEBUG => $ENV{ANYEVENT_MQTT_TEST_DEBUG}
};
use File::Temp qw/tempfile/;

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
     desc => q{publish},
     send => '30 0d 00 03 2f 74 31 6d 65 73  73 61 67 65 31',
    },
   ],
  );

my $cv = AnyEvent->condvar;

eval { test_server($cv, @connections) };
plan skip_all => "Failed to create dummy server: $@" if ($@);

my ($host,$port) = @{$cv->recv};
my $addr = join ':', $host, $port;

plan tests => 8;

use_ok('AnyEvent::MQTT');

my $ow = AnyEvent::MQTT->new(host => $host, port => $port,
                             client_id => 'acme_mqtt');

ok($ow, 'instantiate AnyEvent::MQTT object');

my $cv1 = AnyEvent->condvar;
my $t1_sub = $ow->subscribe('/t1',
                            sub {
                              my ($topic, $message) = @_;
                              $cv1->send($topic.' '.$message);
                            });

my $cv2 = AnyEvent->condvar;
my $t2_sub = $ow->subscribe('/t2',
                            sub {
                              my ($topic, $message) = @_;
                              $cv2->send($topic.' '.$message);
                            });

is($t1_sub->recv, 0, '... subscribe /t1 complete');
is($t2_sub->recv, 0, '... subscribe /t2 complete');
is($cv1->recv, '/t1 message1', '... /t1 message');
