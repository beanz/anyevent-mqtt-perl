#!/usr/bin/perl
use warnings;
use strict;
use Test::More tests => 31;
use FindBin;
use lib $FindBin::Bin;
use Tester;
Tester->run(\*DATA);

__DATA__
{
 "stream" :
 [
  { "action" : "connect" },
  {
   "action" : "publish",
   "arguments" : { "qos" : 1, "message" : "retained", "retain" : 1 }
  },
  {
   "action" : "publish",
   "arguments" : { "qos" : 0, "message" : "not retained" }
  },
  { "action" : "subscribe", "result" : "0", "cvname" : "subscribe-qos0" },
  {
   "action" : "wait", "for" : "subscribe-qos0",
   "result" : { "topic" : "%topicpid%", "message" : "retained" }
  },
  { "action" : "unsubscribe", "result" : 1 },
  {
   "action" : "publish",
   "arguments" : { "qos" : 0, "message" : "", "retain" : 1 }
  },
  { "action" : "subscribe", "result" : "0", "cvname" : "subscribe-qos1" },
  { "action" : "timeout", "timeout" : 0.5, "cvname" : "subscribe-qos1" },
  {
   "action" : "wait", "for" : "subscribe-qos1", "result" : "timeout"
  }
 ],
 "log" :
 [
  "> Connect/at-most-once MQIsdp/3/%testname% ",
  "< ConnAck/at-most-once Connection Accepted ",
  "> Publish/at-least-once,retain %topicpid%/1 \n  72 65 74 61 69 6e 65 64                          retained",
  "< PubAck/at-most-once 1 ",
  "> Publish/at-most-once %topicpid% \n  6e 6f 74 20 72 65 74 61 69 6e 65 64              not retained",
  "> Subscribe/at-least-once 2 %topicpid%/at-most-once ",
  "< SubAck/at-most-once 2/at-most-once ",
  "< Publish/at-most-once,retain %topicpid% \n  72 65 74 61 69 6e 65 64                          retained",
  "> Unsubscribe/at-least-once 3 %topicpid% ",
  "< UnsubAck/at-most-once 3 ",
  "> Publish/at-most-once,retain %topicpid% ",
  "> Subscribe/at-least-once 4 %topicpid%/at-most-once ",
  "< SubAck/at-most-once 4/at-most-once "
 ]
}
