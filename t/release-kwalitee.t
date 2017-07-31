
BEGIN {
  unless ($ENV{RELEASE_TESTING}) {
    print qq{1..0 # SKIP these tests are for release candidate testing\n};
    exit
  }
}

# this test was generated with Dist::Zilla::Plugin::Test::Kwalitee 2.12
use strict;
use warnings;
use Test::More 0.88;
use Test::Kwalitee 1.21 'kwalitee_ok';

kwalitee_ok();

done_testing;
