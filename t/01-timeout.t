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
  use t::Helpers qw/test_error/;
}

my @connections =
  (
   [ [ packrecv => '10 17 00 06  4D 51 49 73   64 70 03 02  00 78 00 09
                    61 63 6D 65  5F 6D 71 74   74', 'connect' ],
     [ sleep => 1, 'connect timeout' ],
   ],
  );

my $server;
eval { $server = AnyEvent::MockTCPServer->new(connections => \@connections); };
plan skip_all => "Failed to create dummy server: $@" if ($@);

my ($host, $port) = $server->connect_address;

plan tests => 5;

use_ok('AnyEvent::MQTT');

my $cv;
my $error;
my $mqtt =
  AnyEvent::MQTT->new(host => $host, port => $port, client_id => 'acme_mqtt',
                      timeout => 0.4,
                      on_error => sub { $error = [@_]; $cv->send(1) });

ok($mqtt, 'instantiate AnyEvent::MQTT object');
$cv = $mqtt->connect();
$cv->recv;
is($error->[0], 0, 'connact timeout - not fatal');
is($error->[1], 'connack timeout', 'connact timeout - message');
