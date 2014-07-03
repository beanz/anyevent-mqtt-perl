
BEGIN {
  unless ($ENV{RELEASE_TESTING}) {
    require Test::More;
    Test::More::plan(skip_all => 'these tests are for release candidate testing');
  }
}

use strict;
use warnings;

# this test was generated with Dist::Zilla::Plugin::NoTabsTests 0.08

use Test::More 0.88;
use Test::NoTabs;

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
    't/author-test-eol.t',
    't/release-common_spelling.t',
    't/release-kwalitee.t',
    't/release-no-tabs.t',
    't/release-pod-coverage.t',
    't/release-pod-linkcheck.t',
    't/release-pod-no404s.t',
    't/release-pod-syntax.t',
    't/release-synopsis.t'
);

notabs_ok($_) foreach @files;
done_testing;
