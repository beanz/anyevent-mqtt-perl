
BEGIN {
  unless ($ENV{AUTHOR_TESTING}) {
    print qq{1..0 # SKIP these tests are for testing by the author\n};
    exit
  }
}

use strict;
use warnings;

# this test was generated with Dist::Zilla::Plugin::Test::EOL 0.19

use Test::More 0.88;
use Test::EOL;

my @files = (
    'bin/anyevent-mqtt-monitor',
    'bin/anyevent-mqtt-pub',
    'bin/anyevent-mqtt-sub',
    'lib/AnyEvent/MQTT.pm',
    't/01-close-connection.t',
    't/01-connect-error.t',
    't/01-errors.t',
    't/01-keep-alive.t',
    't/01-publish.t',
    't/01-subscribe.t',
    't/01-timeout.t',
    't/01-unexpected.t',
    't/02-dup-sub-callback.t',
    't/02-sub-wildcard.t',
    't/03-pub-qos-1.t',
    't/03-pub-qos-2.t',
    't/03-sub-qos-1.t',
    't/03-sub-qos-2.t',
    't/04-multi-subs.t',
    't/Helpers.pm',
    't/author-critic.t',
    't/author-eol.t',
    't/author-no-tabs.t',
    't/author-pod-coverage.t',
    't/author-pod-linkcheck.t',
    't/author-pod-no404s.t',
    't/author-pod-syntax.t',
    't/author-synopsis.t',
    't/release-common_spelling.t',
    't/release-kwalitee.t'
);

eol_unix_ok($_, { trailing_whitespace => 1 }) foreach @files;
done_testing;
