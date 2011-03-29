#!/usr/bin/perl
#
# Copyright (C) 2011 by Mark Hindess

use strict;
use constant {
  DEBUG => $ENV{ANYEVENT_MQTT_TEST_DEBUG}
};
use Net::MQTT::Constants;
use Errno qw/EPIPE/;
use Scalar::Util qw/weaken/;

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
  use t::Helpers qw/test_error/;
  use t::MockServer qw/:all/;
}

my @connections =
  (
   [], # just close
   [
    mockrecv('10 17 00 06  4D 51 49 73   64 70 03 02  00 78 00 09
              61 63 6D 65  5F 6D 71 74   74', 'connect'),
    mocksleep(0.5, 'connect timeout'),
   ],
  );

my $server;
eval { $server = t::MockServer->new(@connections) };
plan skip_all => "Failed to create dummy server: $@" if ($@);

my ($host, $port) = $server->connect_address;

plan tests => 14;

use_ok('AnyEvent::MQTT');

my $cv;
my $mqtt =
  AnyEvent::MQTT->new(host => $host, port => $port, client_id => 'acme_mqtt',
                      on_error => sub { $cv->send($!{EPIPE}, @_) });

ok($mqtt, 'instantiate AnyEvent::MQTT object for broken pipe test');
$cv = $mqtt->connect();
my ($is_broken_pipe, $fatal, $error) = $cv->recv;
ok($is_broken_pipe, '... broken pipe errno');
is($fatal, 1, '... fatal error');
like($error, qr/^Error: /, '... message');

is(test_error(sub { $mqtt->subscribe }),
   'AnyEvent::MQTT->subscribe requires "topic" parameter',
   'subscribe w/o topic');

is(test_error(sub { $mqtt->unsubscribe }),
   'AnyEvent::MQTT->unsubscribe requires "topic" parameter',
   'unsubscribe w/o topic');

is(test_error(sub { $mqtt->subscribe(topic => '/test') }),
   'AnyEvent::MQTT->subscribe requires "callback" parameter',
   'subscribe w/o callback');

is(test_error(sub { $mqtt->publish }),
   'AnyEvent::MQTT->publish requires "topic" parameter',
   'publish w/o topic');

is(test_error(sub { $mqtt->publish(topic => '/test') }),
   'AnyEvent::MQTT->publish requires "message" or "handle" parameter',
   'publish w/o message or handle');

undef $error;
$mqtt =
  AnyEvent::MQTT->new(host => $host, port => $port, client_id => 'acme_mqtt',
                      timeout => 0.1,
                      on_error => sub { $error = [@_]; $cv->send(1) });

ok($mqtt, 'instantiate AnyEvent::MQTT object');
$cv = $mqtt->connect();
$cv->recv;
is($error->[0], 0, 'connact timeout - not fatal');
is($error->[1], 'connack timeout', 'connact timeout - message');

