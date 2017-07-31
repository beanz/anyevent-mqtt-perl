#!/usr/bin/perl

BEGIN {
  unless ($ENV{RELEASE_TESTING}) {
    print qq{1..0 # SKIP these tests are for release candidate testing\n};
    exit
  }
}

use strict; use warnings;

use Test::More;

eval "use Test::Pod::Spelling::CommonMistakes";
if ( $@ ) {
    plan skip_all => 'Test::Pod::Spelling::CommonMistakes required for testing POD';
} else {
    all_pod_files_ok();
}
