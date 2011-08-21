#!/usr/bin/perl
use warnings;
use strict;
use Test::More tests => 9;
use AnyEvent::MQTT;

my $timeout = AnyEvent->timer(after => 5, cb => sub { die "timeout\n" });
my ($test) = ($0 =~ m!([^/]+)$!);
my $topic = '/zqk/test';
my @messages;
my $mqtt = AnyEvent::MQTT->new(host => $ENV{ANYEVENT_MQTT_SERVER},
                               on_error => sub {
                                 warn $_[1], "\n"; die "\n" if ($_[0])
                               },
                               client_id => $test,
                               message_log_callback => sub {
                                 my $str = $_[1]->string;
                                 return if ($str =~ /Publish/ && $str !~ /zqk/);
                                 push @messages, $_[0].' '.$str;
                               });
ok(my $cv = $mqtt->connect, 'connect');
ok($cv->recv, '...connected') or BAIL_OUT('simple connect failed');
my $received = AnyEvent->condvar;
ok($cv = $mqtt->subscribe(topic => $topic.'/+',
                          callback => sub {
                            return 1 unless ($_[0] =~ '/zqk/test');
                            $received->send(\@_);
                          }),
   'subscribe');
is($cv->recv, 0, '...subscribed');

foreach my $t ('/a', '/a/b', '') {
  ok($cv = $mqtt->publish(topic => $topic.$t,
                          message => 'just testing'), 'publish');
  ok($cv->recv, '...published '.$topic.$t);
  my $res = $received->recv;
  my ($topic_recv, $message) = @$res;
  is($topic_recv, $topic.$t, '...topic '.$topic.$t);
  is($message, 'just testing', '...message '.$topic.$t);

  $received = AnyEvent->condvar;
}

is_deeply(\@messages,
          [
           q{> Connect/at-most-once MQIsdp/3/}.$test.q{ },
           q{< ConnAck/at-most-once Connection Accepted },
           q{> Subscribe/at-least-once 1 /#/at-most-once },
           q{< SubAck/at-most-once 1/at-most-once },
           q{> Publish/at-most-once }.$topic." \n".
             q{  6a 75 73 74 20 74 65 73 74 69 6e 67              just testing},
           q{< Publish/at-most-once }.$topic." \n".
             q{  6a 75 73 74 20 74 65 73 74 69 6e 67              just testing},
          ], '...message log');
