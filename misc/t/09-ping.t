#!/usr/bin/perl
use warnings;
use strict;
use FindBin;
use lib $FindBin::Bin;
use Tester;
Tester->run(\*DATA);

__DATA__
{ "stream" :
 [
  { "action" : "connect" },
  { "action" : "send", "cvname" : "pingresp", "response" : "pingresp",
    "arguments" : { "message_type" : 12 } },
  { "action" : "wait", "for" : "pingresp",
    "result" : { "message_type" : 13 } }
  ],
  "log" : [ "> Connect/at-most-once MQIsdp/3/%testname% ",
            "< ConnAck/at-most-once Connection Accepted ",
            "> PingReq/at-most-once",
            "< PingResp/at-most-once",
            "> Disconnect/at-most-once" ] }
