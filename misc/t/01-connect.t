#!/usr/bin/perl
use warnings;
use strict;
use Test::More;
use AnyEvent::MQTT;
my ($test) = ($0 =~ m!([^/]+)$!);
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

undef $mqtt;

is_deeply(\@messages,
          [
           q{> Connect/at-most-once MQIsdp/3/}.$test.q{ },
           q{< ConnAck/at-most-once Connection Accepted },
          ], '...message log');

done_testing;
