#!/usr/bin/perl

BEGIN {
  unless ($ENV{RELEASE_TESTING}) {
    require Test::More;
    Test::More::plan(skip_all => 'these tests are for release candidate testing');
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
