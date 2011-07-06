#!/usr/bin/perl
use warnings;
use strict;
use Test::More tests => 17;
use AnyEvent::MQTT;
use Net::MQTT::Constants;

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
                                 push @messages, $_[0].' '.$_[1]->string;
                               });
ok(my $cv = $mqtt->connect, 'connect');
ok($cv->recv, '...connected') or BAIL_OUT('simple connect failed');
my $received = AnyEvent->condvar;
ok($cv = $mqtt->subscribe(topic => $topic,
                          qos => MQTT_QOS_EXACTLY_ONCE,
                          callback => sub { $received->send(\@_); }),
   'subscribe');
is($cv->recv, 2, '...subscribed');
ok($cv = $mqtt->publish(topic => $topic,
                        qos => MQTT_QOS_AT_LEAST_ONCE,
                        message => 'just testing'), 'publish');

ok($cv->recv, '...published');
my $res = $received->recv;
my ($topic_recv, $message) = @$res;
is($topic_recv, $topic, '...topic');
is($message, 'just testing', '...message');

is(@messages, 8, 'message log');
is(shift @messages, q{> Connect/at-most-once MQIsdp/3/}.$test.q{ },
   '... connect');
is(shift @messages, q{< ConnAck/at-most-once Connection Accepted },
   '... connack');
is(shift @messages, q{> Subscribe/at-least-once 1 }.$topic.q{/exactly-once },
   '... subscribe');
is(shift @messages, q{< SubAck/at-most-once 1/exactly-once },
   '... suback');
is(shift @messages,
   q{> Publish/at-least-once }.$topic."/2 \n".
     q{  6a 75 73 74 20 74 65 73 74 69 6e 67              just testing},
   '... publish');
my $m = shift @messages;
if ($m =~ qr!^< PubAck/!) {
  diag('minor deviation from specified order');
  is($m, q{< PubAck/at-most-once 2 }, '... puback');
  is(shift @messages,
     q{< Publish/at-least-once }.$topic."/1 \n".
       q{  6a 75 73 74 20 74 65 73 74 69 6e 67              just testing},
     '... publish');
  is(shift @messages,  q{> PubAck/at-most-once 1 }, '... puback');
} else {
  is($m,
     q{< Publish/at-least-once }.$topic."/1 \n".
       q{  6a 75 73 74 20 74 65 73 74 69 6e 67              just testing},
     '... publish');
  is(shift @messages,  q{> PubAck/at-most-once 1 }, '... puback');
  is(shift @messages, q{< PubAck/at-most-once 2 }, '... puback');
}
