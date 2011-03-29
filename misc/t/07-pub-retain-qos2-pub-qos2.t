#!/usr/bin/perl
use warnings;
use strict;
use Test::More tests => 18;
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
ok($cv = $mqtt->publish(topic => $topic,
                        qos => MQTT_QOS_EXACTLY_ONCE,
                        retain => 1,
                        message => 'retained'), 'publish');

ok($cv->recv, '...published retained');

ok($cv = $mqtt->publish(topic => $topic,
                        qos => MQTT_QOS_EXACTLY_ONCE,
                        message => 'not retained'), 'publish');

ok($cv->recv, '...published not retained');

my $received = AnyEvent->condvar;
ok($cv = $mqtt->subscribe(topic => $topic,
                          callback => sub { $received->send(\@_); }),
   'subscribe');
is($cv->recv, 0, '...subscribed');
my $res = $received->recv;
my ($topic_recv, $message) = @$res;
is($topic_recv, $topic, '...topic');
is($message, 'retained', '...message');

ok($cv = $mqtt->unsubscribe(topic => $topic), 'unsubscribe');
is($cv->recv, 1, '...unsubscribed');


ok($cv = $mqtt->publish(topic => $topic,
                        qos => MQTT_QOS_AT_MOST_ONCE,
                        retain => 1,
                        message => ''), 'publish');

ok($cv->recv, '...published clear retained');

$received = AnyEvent->condvar;
ok($cv = $mqtt->subscribe(topic => $topic,
                          callback => sub { $received->send(\@_); }),
   'subscribe');
is($cv->recv, 0, '...subscribed');
my $w =
  AnyEvent->timer(after => 0.2, cb => sub { $received->send(['timeout']) });
$res = $received->recv;
($topic_recv, $message) = @$res;
is($topic_recv, 'timeout', '...timeout');

is_deeply(\@messages,
          [
           q{> Connect/at-most-once MQIsdp/3/}.$test.q{ },
           q{< ConnAck/at-most-once Connection Accepted },
           q{> Publish/exactly-once,retain }.$topic."/1 \n".
             q{  72 65 74 61 69 6e 65 64                          retained},
           q{< PubRec/at-most-once 1 },
           q{> PubRel/at-least-once 1 },
           q{< PubComp/at-most-once 1 },
           q{> Publish/exactly-once }.$topic."/2 \n".
             q{  6e 6f 74 20 72 65 74 61 69 6e 65 64              not retained},
           q{< PubRec/at-most-once 2 },
           q{> PubRel/at-least-once 2 },
           q{< PubComp/at-most-once 2 },
           q{> Subscribe/at-least-once 3 }.$topic.q{/at-most-once },
           q{< SubAck/at-most-once 3/at-most-once },
           q{< Publish/at-most-once,retain }.$topic." \n".
             q{  72 65 74 61 69 6e 65 64                          retained},
           q{> Unsubscribe/at-least-once 4 }.$topic.q{ },
           q{< UnsubAck/at-most-once 4 },
           q{> Publish/at-most-once,retain }.$topic.q{ },
           q{> Subscribe/at-least-once 5 }.$topic.q{/at-most-once },
           q{< SubAck/at-most-once 5/at-most-once },
          ], '...message log');
