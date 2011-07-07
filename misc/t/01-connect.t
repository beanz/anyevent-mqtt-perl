#!/usr/bin/perl
use warnings;
use strict;
use Test::More tests => 5;
use FindBin;
use lib $FindBin::Bin;
use Tester;
Tester->run(\*DATA);

__DATA__
{ "stream" : [ { "action" : "connect" } ],
  "log" : [ "> Connect/at-most-once MQIsdp/3/%testname% ",
            "< ConnAck/at-most-once Connection Accepted " ] }
