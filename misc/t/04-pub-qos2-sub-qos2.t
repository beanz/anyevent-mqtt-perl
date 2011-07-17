#!/usr/bin/perl
use warnings;
use strict;
use FindBin;
use lib $FindBin::Bin;
use Tester;
Tester->run(\*DATA);

__DATA__
{
 "stream" :
 [
  { "action" : "connect" },
  { "action" : "subscribe","arguments" : { "qos" : 2 },
    "result" : "2", "cvname" : "subscribe-qos2" },
  {
   "action" : "publish", "arguments" : { "qos" : 2, "message" : "just testing" }
  },
  {
   "action" : "wait", "for" : "subscribe-qos2",
   "result" : { "topic" : "%topicpid%", "message" : "just testing" }
  }
 ],
 "log" :
 [
  "> Connect/at-most-once MQIsdp/3/%testname% ",
  "< ConnAck/at-most-once Connection Accepted ",
  "> Subscribe/at-least-once 1 %topicpid%/exactly-once ",
  "< SubAck/at-most-once 1/exactly-once ",
  "> Publish/exactly-once %topicpid%/2 \n  6a 75 73 74 20 74 65 73 74 69 6e 67              just testing",
  "< PubRec/at-most-once 2 ",
  "> PubRel/at-least-once 2 ",
  "< PubComp/at-most-once 2 ",
  "< Publish/exactly-once %topicpid%/1 \n  6a 75 73 74 20 74 65 73 74 69 6e 67              just testing",
  "> PubRec/at-most-once 1 ",
  "< PubRel/at-least-once 1 ",
  "> PubComp/at-most-once 1 ",
  "> Disconnect/at-most-once"
 ]
}
