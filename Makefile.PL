
use strict;
use warnings;



use ExtUtils::MakeMaker 6.31;



my %WriteMakefileArgs = (
  'ABSTRACT' => 'AnyEvent module for an MQTT client',
  'AUTHOR' => 'Mark Hindess <soft-cpan@temporalanomaly.com>',
  'BUILD_REQUIRES' => {
    'AnyEvent::MockTCPServer' => '0',
    'AnyEvent::Socket' => '0',
    'English' => '0',
    'Errno' => '0',
    'Exporter' => '0',
    'File::Temp' => '0',
    'Test::More' => '0'
  },
  'CONFIGURE_REQUIRES' => {
    'ExtUtils::MakeMaker' => '6.31'
  },
  'DISTNAME' => 'AnyEvent-MQTT',
  'EXE_FILES' => [
    'bin/anyevent-mqtt-monitor',
    'bin/anyevent-mqtt-pub',
    'bin/anyevent-mqtt-sub'
  ],
  'LICENSE' => 'perl',
  'NAME' => 'AnyEvent::MQTT',
  'PREREQ_PM' => {
    'AnyEvent' => '0',
    'AnyEvent::Handle' => '0',
    'Carp' => '0',
    'Getopt::Long' => '0',
    'Net::MQTT::Constants' => '0',
    'Net::MQTT::Message' => '1.112320',
    'Net::MQTT::TopicStore' => '0',
    'POSIX' => '0',
    'Pod::Usage' => '0',
    'Scalar::Util' => '0',
    'Sub::Name' => '0',
    'constant' => '0'
  },
  'VERSION' => '1.112480',
  'test' => {
    'TESTS' => 't/*.t'
  }
);


unless ( eval { ExtUtils::MakeMaker->VERSION(6.56) } ) {
  my $br = delete $WriteMakefileArgs{BUILD_REQUIRES};
  my $pp = $WriteMakefileArgs{PREREQ_PM};
  for my $mod ( keys %$br ) {
    if ( exists $pp->{$mod} ) {
      $pp->{$mod} = $br->{$mod} if $br->{$mod} > $pp->{$mod};
    }
    else {
      $pp->{$mod} = $br->{$mod};
    }
  }
}

delete $WriteMakefileArgs{CONFIGURE_REQUIRES}
  unless eval { ExtUtils::MakeMaker->VERSION(6.52) };

WriteMakefile(%WriteMakefileArgs);



