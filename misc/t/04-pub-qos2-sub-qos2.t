#!/usr/bin/perl
use warnings;
use strict;
use Test::More tests => 9;
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
                        qos => MQTT_QOS_EXACTLY_ONCE,
                        message => 'just testing'), 'publish');

ok($cv->recv, '...published');
my $res = $received->recv;
my ($topic_recv, $message) = @$res;
is($topic_recv, $topic, '...topic');
is($message, 'just testing', '...message');

is_deeply(\@messages,
          [
           q{> Connect/at-most-once MQIsdp/3/}.$test.q{ },
           q{< ConnAck/at-most-once Connection Accepted },
           q{> Subscribe/at-least-once 1 }.$topic.q{/exactly-once },
           q{< SubAck/at-most-once 1/exactly-once },
           q{> Publish/exactly-once }.$topic."/2 \n".
             q{  6a 75 73 74 20 74 65 73 74 69 6e 67              just testing},
           q{< PubRec/at-most-once 2 },
           q{> PubRel/at-least-once 2 },
           q{< PubComp/at-most-once 2 },
           q{< Publish/exactly-once }.$topic."/1 \n".
             q{  6a 75 73 74 20 74 65 73 74 69 6e 67              just testing},
           q{> PubRec/at-most-once 1 },
           q{< PubRel/at-most-once 1 },
           q{> PubComp/at-most-once 1 },
          ], '...message log');
