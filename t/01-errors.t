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
   ],
   [
    {
     desc => q{connect},
     recv => '10 17
              00 06 4D 51 49 73 64 70
              03 02 00 78
              00 09 61 63 6D 65 5F 6D 71 74 74',
     sleep => 0.5,
    },
   ],
  );

my $cv = AnyEvent->condvar;

eval { test_server($cv, @connections) };
plan skip_all => "Failed to create dummy server: $@" if ($@);

my ($host,$port) = @{$cv->recv};
my $addr = join ':', $host, $port;

plan tests => 5;

use_ok('AnyEvent::MQTT');

my $error;
my $mqtt =
  AnyEvent::MQTT->new(host => $host, port => $port, client_id => 'acme_mqtt',
                      on_error => sub { $error = [@_]; $cv->send(1) });

ok($mqtt, 'instantiate AnyEvent::MQTT object');
$cv = $mqtt->connect();
$cv->recv;
is_deeply($error, [1, 'Broken pipe'], 'fatal error broken pipe');

undef $error;
$mqtt =
  AnyEvent::MQTT->new(host => $host, port => $port, client_id => 'acme_mqtt',
                      timeout => 0.1,
                      on_error => sub { $error = [@_]; $cv->send(1) });

ok($mqtt, 'instantiate AnyEvent::MQTT object');
$cv = $mqtt->connect();
$cv->recv;
is_deeply($error, [0, 'connack timeout'], 'connact timeout');
