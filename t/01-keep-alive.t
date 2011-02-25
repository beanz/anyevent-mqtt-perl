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
  use t::MockServer;
}

my @connections =
  (
   [
    t::MockServer::Receive->new(
     description => q{connect},
     data => '10 17
              00 06 4D 51 49 73 64 70
              03 02 00 78
              00 09 61 63 6D 65 5F 6D 71 74 74',
    ),
    t::MockServer::Send->new(
     description => q{connack},
     data => '20 02 00 00',
    ),
    t::MockServer::Receive->new(
     description => q{pingreq},
     data => 'C0 00',
    ),
    t::MockServer::Send->new(
     description => q{pingresp},
     data => 'D0 00',
    ),
    t::MockServer::Send->new(
     description => q{pingresp dup},
     data => 'D0 00',
    ),
    t::MockServer::Sleep->new(
     description => q{pingreq timeout},
     interval => 0.5,
    ),
   ],
   [
    t::MockServer::Receive->new(
     description => q{connect},
     data => '10 17
              00 06 4D 51 49 73 64 70
              03 00 00 78
              00 09 61 63 6D 65 5F 6D 71 74 74',
    ),
    t::MockServer::Send->new(
     description => q{connack},
     data => '20 02 00 00',
    ),
    t::MockServer::Receive->new(
     description => q{subscribe /t1},
     data => '82 08 00 01 00 03 2F 74 31 00',
    ),
    t::MockServer::Send->new(
     description => q{suback /t1},
     data => '90 03 00 01 00',
    ),
    t::MockServer::Send->new(
     description => q{publish /t1 message1},
     data => '30 0d 00 03 2f 74 31 6d 65 73  73 61 67 65 31',
    ),
   ],
  );

my $server;
eval { $server = t::MockServer->new(@connections) };
plan skip_all => "Failed to create dummy server: $@" if ($@);

my ($host, $port) = $server->connect_address;

plan tests => 11;

use_ok('AnyEvent::MQTT');

my $mqtt =
  AnyEvent::MQTT->new(host => $host, port => $port, client_id => 'acme_mqtt');

ok($mqtt, 'instantiate AnyEvent::MQTT object');
my $cv = $mqtt->connect();

is($cv->recv, 1, '... connection handshake complete');
$mqtt->{keep_alive_timer} = 0.2; # hack keep alive timer to avoid long test
$mqtt->_reset_keep_alive_timer(); # reset it
$cv = AnyEvent->condvar;
my $timer = AnyEvent->timer(after => 0.4, cb => sub { $cv->send(1); });
$cv->recv;

$cv = AnyEvent->condvar;
$timer = AnyEvent->timer(after => 0.8, cb => sub { $cv->send(0,'oops'); });
$mqtt->{on_error} = sub { $cv->send(@_); };
my ($fatal, $err) = $cv->recv;
is($fatal, 0, 'keep alive timeout error - non-fatal');
is($err, 'keep alive timeout', 'keep alive timeout error - message');

$mqtt->{keep_alive_timer} = 120; # hack keep alive timer back to default
$cv = AnyEvent->condvar;
my $sub_cv = $mqtt->subscribe(topic => '/t1',
                              callback => sub {
                                my ($topic, $message) = @_;
                                $cv->send($topic.' '.$message);
                              });
is($sub_cv->recv, 0, 'subscribe after reconnect');
is($cv->recv, '/t1 message1', '... received message');
