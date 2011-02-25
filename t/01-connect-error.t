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
  use t::MockServer qw/:all/;
}

my @connections =
  (
   [
    mockrecv('10 26 00 06  4D 51 49 73   64 70 03 02  00 78 00 18
              61 61 61 61  61 61 61 61   61 61 61 61  61 61 61 61
              61 61 61 61  61 61 61 61',
             q{connect invalid client id}),
    mocksend('20 02 00 02', q{connack invalid client id}),
   ],
  );

my $server;
eval { $server = t::MockServer->new(@connections) };
plan skip_all => "Failed to create dummy server: $@" if ($@);

my ($host, $port) = $server->connect_address;

plan tests => 5;

use_ok('AnyEvent::MQTT');

my $cv = AnyEvent->condvar;
my $error = AnyEvent->condvar;
my $mqtt =
  AnyEvent::MQTT->new(host => $host, port => $port, client_id => 'a' x 24,
                      on_error => sub { $error->send(@_) });

ok($mqtt, 'instantiate AnyEvent::MQTT object with invalid client_id');
$cv = $mqtt->connect();
my ($fatal, $message) = $error->recv;
is($fatal, 1, '... fatal error');
is($message,
   'Connection refused: ConnAck/at-most-once '.
   'Connection Refused: identifier rejected ',
   '... correct message');
