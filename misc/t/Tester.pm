package # Hide from PAUSE
        Tester;
use strict;
use warnings;
use constant {
  SERVER => $ENV{ANYEVENT_MQTT_SERVER} || 'localhost',
  JOBS => $ENV{ANYEVENT_MQTT_TESTER_JOBS} || 1,
  REPEAT => $ENV{ANYEVENT_MQTT_TESTER_REPEAT} || 1,
  TIMEOUT => $ENV{ANYEVENT_MQTT_TESTER_TIMEOUT} || 5,
  DIAG => $ENV{ANYEVENT_MQTT_TESTER_DIAG},
};

use Test::More;
use AnyEvent::MQTT;
use Net::MQTT::Constants;
use JSON;
use File::Slurp;
use Test::SharedFork;

sub run {
  my ($pkg, $file) = @_;

  my $json = JSON->new;
  my $data = read_file($file);
  $data = $json->decode($data);
  my $conf = $data->{config} || {};
  my $streams = $data->{streams} || [ $data->{stream} ];
  my $logs = $data->{logs} || [ $data->{log} ];
  $conf->{jobs} ||= JOBS;
  my $new = [];
  push @$new, @$streams foreach (1..$conf->{jobs});
  $streams = $new;
  $new = [];
  push @$new, @$logs foreach (1..$conf->{jobs});
  $logs = $new;

  $conf->{topic} ||= '/zqk/test';
  $conf->{host} ||= SERVER;
  $conf->{repeat} ||= REPEAT;
  $conf->{timeout} ||= TIMEOUT * $conf->{repeat} * $conf->{jobs};
  my ($test) = ($0 =~ m!([^/]+)\.t$!);
  $conf->{testname} ||= $test;

  my $timeout = AnyEvent->timer(after => $conf->{timeout},
                                cb => sub { die "timeout\n" });

  foreach my $n (0..($conf->{repeat}-1)) {

    my @pids;
    foreach my $i (0..(@$streams-1)) {
      my $pid = fork;
      die "Fork failed\n" unless (defined $pid);
      if ($pid) {
        push @pids, $pid;
        next;
      }
      #diag('child '.$i);
      my @log;
      $conf->{pid} = $i;
      $conf->{testname} .= '.'.$n.'.'.$i;
      $conf->{topicpid} = $conf->{topic}.'/'.$i;
      run_stream($conf, $streams->[$i], \@log);
      check_log($conf, $logs->[$i], \@log);
      #diag('child '.$i.' finished');
      exit;
    }

    foreach my $pid (@pids) {
      #diag('waiting for child '.$pid);
      waitpid($pid, 0);
      if ($?) {
        die "child died: ", ($?>>8), "\n";
      }
    }
  }
  done_testing();
}

sub run_stream {
  my ($conf, $stream, $log) = @_;
  my $cv;
  my $mqtt;
  my %cv = ();
  my %timer = ();
  my $index = 0;
  foreach my $index (0..-1+@$stream) {
    $conf->{index} = $index;
    my $rec = $stream->[$index];
    my $name =
      $rec->{name} || $index.':'.($rec->{action}||'item').'/'.$conf->{pid};
    my $args = $rec->{arguments} || {};
    $_ = replace_conf($_, $conf) foreach (values %$args);
    if ($rec->{action} eq 'connect') {
      $mqtt = AnyEvent::MQTT->new(host => $conf->{host},
                                  client_id => $conf->{testname},
                                  %$args,
                                  message_log_callback => sub {
                                    push @$log, $_[0].' '.$_[1]->string;
                                  },
                                  on_error => sub {
                                    warn $_[1], "\n";
                                    die "\n" if ($_[0]);
                                  },
                                 );
      ok($cv = $mqtt->connect, 'connect - '.$name);
      ok($cv->recv, '...connected - '.$name)
        or BAIL_OUT('connect failed');
    } elsif ($rec->{action} eq 'subscribe') {
      my $cvname = $rec->{cvname}||$name;
      $cv{$cvname} = AnyEvent->condvar;
      my %args =
        (
         topic => $conf->{topicpid},
         qos => MQTT_QOS_AT_MOST_ONCE,
         callback => sub { $cv{$cvname}->send($_[2]); },
         %$args,
        );

      ok($cv = $mqtt->subscribe(%args), '...subscribe - '.$name);
      is($cv->recv, $rec->{result}, '...subscribed - '.$name);
    } elsif ($rec->{action} eq 'unsubscribe') {
      my %args =
        (
         topic => $conf->{topicpid},
         %$args,
        );

      ok($cv = $mqtt->unsubscribe(%args), '...unsubscribe - '.$name);
      is($cv->recv, $rec->{result}, '...unsubscribed - '.$name);
    } elsif ($rec->{action} eq 'publish') {
      my %args =
        (
         topic => $conf->{topicpid},
         qos => MQTT_QOS_AT_MOST_ONCE,
         message => '',
         %$args,
        );
      ok($cv = $mqtt->publish(%args), '...publish - '.$name);
      ok($cv->recv, '...published - '.$name);
    } elsif ($rec->{action} eq 'wait') {
      my $msg = $cv{$rec->{for}}->recv;
      my $result = $rec->{result};
      if (ref $result) {
        foreach my $k (sort keys %$result) {
          is($msg->$k, replace_conf($result->{$k}, $conf),
             '...result '.$k.' - '.$name);
        }
      } else {
        is($msg, replace_conf($result, $conf),
           '...result '.$result.' - '.$name);
      }
    } elsif ($rec->{action} eq 'timeout') {
      my $cvname = $rec->{cvname}||$name;
      $cv{$cvname} = AnyEvent->condvar unless (exists $cv{$cvname});
      $timer{$name} = AnyEvent->timer(after => $rec->{timeout},
                      cb => sub { $cv{$cvname}->send("timeout") });
    } elsif ($rec->{action} eq 'send') {
      ok($cv = $mqtt->_send(%$args, cv => AnyEvent->condvar),
         '...send - '.$name);
      ok($cv->recv, '...sent - '.$name);
      my $cvname = $rec->{cvname}||$name;
      $cv{$cvname} = AnyEvent->condvar;
      my $callback = 'before_'.($rec->{response}||'msg').'_callback';
      $mqtt->{$callback} =
        sub {
          $cv{$cvname}->send($_[0]);
          delete $mqtt->{$callback};
        };
    } else {
      die "Invalid action: ", $rec->{action}, "\n";
    }
  }
}

sub check_log {
  my ($conf, $expected, $log) = @_;
  my $i = 0;
  while (my $m = shift @$expected) {
    my ($str) = ($m =~ m!^(.*?)/!);
    if (ref $m) {
      foreach my $alt (@$m) {
        my $re = $alt->{re};
        if (!defined $re || $log->[0] =~ m!$re!) {
          diag($alt->{diag}) if (DIAG && exists $alt->{diag});
          return check_log($conf, $alt->{log}, $log);
        }
      }
      die "Didn't match any alternative message log pattern\n";
    } else {
      my $got = shift @$log;
      is($got, replace_conf($m, $conf), 'message '.$i.' '.$str);
    }
  } continue {
    $i++;
  }
  is(@$log, 0, 'no extra messages') or
    diag("Got:\n  ", (join "\n  ", @$log), "\n");
}

sub replace_conf {
  my ($m, $conf) = @_;
  foreach my $k (keys %$conf) {
    $m =~ s/\%$k\%/$conf->{$k}/eg;
  }
  $m;
}

1;
