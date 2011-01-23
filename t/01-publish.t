#!/usr/bin/perl
#
# Copyright (C) 2011 by Mark Hindess

use strict;
use constant {
  DEBUG => $ENV{ANYEVENT_MQTT_TEST_DEBUG}
};
use File::Temp qw/tempfile/;
use Net::MQTT::Constants;
use Errno qw/EPIPE/;

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

my $published;
my $error;
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
     desc => q{publish},
     recv => '30 0F
              00 06 2F 74 6F 70 69 63
              6D 65 73 73 61 67 65',
     send => sub { $published->send(1) },
    },
    {
     desc => q{publish file handle},
     recv => '30 10
              00 06 2F 74 6F 70 69 63
              6D 65 73 73 61 67 65 32',
     send => sub { $published->send(2) },
    },
    {
     desc => q{publish AnyEvent::Handle},
     recv => '30 10
              00 06 2F 74 6F 70 69 63
              6D 65 73 73 61 67 65 33',
     send => sub { $published->send(3) },
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

$published = AnyEvent->condvar;
$cv = AnyEvent->condvar;
$mqtt->publish(message => 'message', topic => '/topic', cv => $cv);
ok($cv, 'simple message publish');
is($cv->recv, 1, '... client complete');
is($published->recv, 1, '... server complete');

my $fh = tempfile();
syswrite $fh, "message2\n";
sysseek $fh, 0, 0;

$published = AnyEvent->condvar;
my $eof = AnyEvent->condvar;
my $pcv =
  $mqtt->publish(handle => $fh, topic => '/topic',
                 qos => MQTT_QOS_AT_MOST_ONCE,
                 handle_args => [ on_error => sub {
                                    my ($hdl, $fatal, $msg) = @_;
                                    # error on fh close as
                                    # readers are waiting
                                    $eof->send($!{EPIPE});
                                    $hdl->destroy;
                                  }]);
ok($pcv, 'publish file handle');
ok($eof->recv, '... expected broken pipe');
ok($pcv->recv, '... client complete');
is($published->recv, 2, '... server complete');

sysseek $fh, 0, 0;
syswrite $fh, "message3\0";
sysseek $fh, 0, 0;

$published = AnyEvent->condvar;
$eof = AnyEvent->condvar;
my $handle;
$handle = AnyEvent::Handle->new(fh => $fh,
                                on_error => sub {
                                  my ($hdl, $fatal, $msg) = @_;
                                  # error on fh close as
                                  # readers are waiting
                                  $eof->send($!{EPIPE});
                                  $hdl->destroy;
                                });
$pcv = $mqtt->publish(handle => $handle, topic => '/topic',
                      push_read_args => ['line', "\0"]);
ok($pcv, 'publish AnyEvent::Handle');
ok($eof->recv, '... expected broken pipe');
ok($pcv->recv, '... client complete');
is($published->recv, 3, '... server complete');
