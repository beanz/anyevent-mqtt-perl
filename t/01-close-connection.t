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
     [ packsend => '20 02', 'half a connack' ],
     # now close
   ],
  );

my $server;
eval { $server = AnyEvent::MockTCPServer->new(connections => \@connections); };
plan skip_all => "Failed to create dummy server: $@" if ($@);

my ($host, $port) = $server->connect_address;

plan tests => 6;

use_ok('AnyEvent::MQTT');

my $cv;
my $error;
my $mqtt =
  AnyEvent::MQTT->new(host => $host, port => $port, client_id => 'acme_mqtt',
                      timeout => 0.4,
                      on_error => sub { $cv->send($!{EPIPE}, @_) });

ok($mqtt, 'instantiate AnyEvent::MQTT object');
$cv = $mqtt->connect();
my ($is_broken_pipe, $fatal, $message) = $cv->recv;
ok($is_broken_pipe, '... is broken pipe');
ok($fatal, '... is fatal');
like($message, qr/broken pipe/i, '... broken pipe');
