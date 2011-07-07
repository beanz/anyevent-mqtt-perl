#!/usr/bin/perl
use warnings;
use strict;
use Test::More tests => 18;
use FindBin;
use lib $FindBin::Bin;
use Tester;
Tester->run(\*DATA);

__DATA__
{
 "stream" :
 [
  { "action" : "connect" },
  { "action" : "subscribe", "result" : "0", "cvname" : "subscribe-qos0" },
  {
   "action" : "publish", "arguments" : { "qos" : 2, "message" : "just testing" }
  },
  {
   "action" : "wait", "for" : "subscribe-qos0",
   "result" : { "topic" : "%topicpid%", "message" : "just testing" }
  }
 ],
 "log" :
 [
  "> Connect/at-most-once MQIsdp/3/%testname% ",
  "< ConnAck/at-most-once Connection Accepted ",
  "> Subscribe/at-least-once 1 %topicpid%/at-most-once ",
  "< SubAck/at-most-once 1/at-most-once ",
  "> Publish/exactly-once %topicpid%/2 \n  6a 75 73 74 20 74 65 73 74 69 6e 67              just testing",
  "< PubRec/at-most-once 2 ",
  "> PubRel/at-least-once 2 ",
  "< PubComp/at-most-once 2 ",
  "< Publish/at-most-once %topicpid% \n  6a 75 73 74 20 74 65 73 74 69 6e 67              just testing"
 ]
}
