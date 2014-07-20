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
}

my $published;
my $error;
my @connections =
  (
   [
    [ packrecv => '10 17 00 06  4D 51 49 73   64 70 03 02  00 78 00 09
                   61 63 6D 65  5F 6D 71 74   74', 'connect' ],
    [ packsend => '20 02 00 00', 'connack' ],
    [ packrecv => '30 0F 00 06  2F 74 6F 70   69 63 6D 65  73 73 61 67
                   65', q{publish} ],
    [ code => sub { $published->send(1) }, q{published} ],
    [ packrecv => '30 10 00 06  2F 74 6F 70   69 63 6D 65  73 73 61 67
                   65 32', q{publish file handle} ],
    [ code => sub { $published->send(2) }, q{publish file handle done} ],
    [ packrecv => '30 10 00 06  2F 74 6F 70   69 63 6D 65  73 73 61 67
                   65 33', q{publish AnyEvent::Handle} ],
    [ code => sub { $published->send(3) }, q{publish AnyEvent::Handle done} ],
   ],
  );

my $server;
eval { $server = AnyEvent::MockTCPServer->new(connections => \@connections); };
plan skip_all => "Failed to create dummy server: $@" if ($@);

my ($host, $port) = $server->connect_address;

plan tests => 19;

use_ok('AnyEvent::MQTT');

my @messages;
my $mqtt = AnyEvent::MQTT->new(host => $host, port => $port,
                               client_id => 'acme_mqtt',
                               message_log_callback => sub {
                                 push @messages, $_[0].' '.$_[1]->string;
                               });

ok($mqtt, 'instantiate AnyEvent::MQTT object');

$published = AnyEvent->condvar;
my $cv = AnyEvent->condvar;
$mqtt->publish(message => 'message', topic => '/topic', cv => $cv);
ok($cv, 'simple message publish');
is($cv->recv, 1, '... client complete');
is($published->recv, 1, '... server complete');

my $fh = tempfile();
syswrite $fh, "message2\n";
sysseek $fh, 0, 0;

$published = AnyEvent->condvar;
my $eof = AnyEvent->condvar;
my $weak_eof = $eof; weaken $weak_eof;
my $pcv =
  $mqtt->publish(handle => $fh, topic => '/topic',
                 qos => MQTT_QOS_AT_MOST_ONCE,
                 handle_args => [ on_error => sub {
                                    my ($hdl, $fatal, $msg) = @_;
                                    # error on fh close as
                                    # readers are waiting
                                    $weak_eof->send($!{EPIPE});
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
$weak_eof = $eof; weaken $weak_eof;
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

is_deeply(\@messages,
          [
           '> Connect/at-most-once MQIsdp/3/acme_mqtt ',
           '< ConnAck/at-most-once Connection Accepted ',
           "> Publish/at-most-once /topic \n".
             '  6d 65 73 73 61 67 65                             message',
           "> Publish/at-most-once /topic \n".
             '  6d 65 73 73 61 67 65 32                          message2',
           "> Publish/at-most-once /topic \n".
             '  6d 65 73 73 61 67 65 33                          message3',
          ], '... message log');

my $ok = 1;
foreach (0..70000) {
  next if ($mqtt->next_message_id < 65536);
  $ok = 0;
}
ok($ok, '... message id should never exceed 16bit size');
