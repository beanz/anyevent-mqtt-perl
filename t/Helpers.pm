use strict;
use warnings;
package t::Helpers;

=head1 NAME

t::Helpers - Perl extension for Helper functions for tests.

=head1 SYNOPSIS

  use Test::More tests => 2;
  use t::Helpers qw/:all/;
  is(test_error(sub { die 'argh' }),
     'argh',
     'died horribly');

  is(test_warn(sub { warn 'danger will robinson' }),
     'danger will robinson',
     'warned nicely');

=head1 DESCRIPTION

Common functions to make test scripts a bit easier to read.

=cut

use base 'Exporter';
use constant {
  DEBUG => $ENV{ANYEVENT_MQTT_TEST_HELPERS_DEBUG}
};
use AnyEvent;
use AnyEvent::Socket;
use AnyEvent::Handle;
use File::Temp qw/tempfile/;
use Test::More;

our %EXPORT_TAGS = ( 'all' => [ qw(
                                   test_error
                                   test_warn
                                   test_output
                                   test_server
) ] );
our @EXPORT_OK = ( @{ $EXPORT_TAGS{'all'} } );
our @EXPORT = qw();

=head2 C<test_error($code_ref)>

This method runs the code with eval and returns the error.  It strips
off some common strings from the end of the message including any "at
<file> line <number>" strings and any "(@INC contains: .*)".

=cut

sub test_error {
  my $sub = shift;
  eval { $sub->() };
  my $error = $@;
  if ($error) {
    $error =~ s/\s+at (\S+|\(eval \d+\)(\[[^]]+\])?) line \d+\.?\s*$//g;
    $error =~ s/\s+at (\S+|\(eval \d+\)(\[[^]]+\])?) line \d+\.?\s*$//g;
    $error =~ s/ \(\@INC contains:.*?\)$//;
  }
  return $error;
}

=head2 C<test_warn($code_ref)>

This method runs the code with eval and returns the warning.  It strips
off any "at <file> line <number>" specific part(s) from the end.

=cut

sub test_warn {
  my $sub = shift;
  my $warn;
  local $SIG{__WARN__} = sub { $warn .= $_[0]; };
  eval { $sub->(); };
  die $@ if ($@);
  if ($warn) {
    $warn =~ s/\s+at (\S+|\(eval \d+\)(\[[^]]+\])?) line \d+\.?\s*$//g;
    $warn =~ s/\s+at (\S+|\(eval \d+\)(\[[^]]+\])?) line \d+\.?\s*$//g;
    $warn =~ s/ \(\@INC contains:.*?\)$//;
  }
  return $warn;
}

sub test_output {
  my ($sub, $fh) = @_;
  my ($tmpfh, $tmpfile) = tempfile();
  open my $oldfh, ">&", $fh     or die "Can't dup \$fh: $!";
  open $fh, ">&", $tmpfh or die "Can't dup \$tmpfh: $!";
  $sub->();
  open $fh, ">&", $oldfh or die "Can't dup \$oldfh: $!";
  $tmpfh->flush;
  open my $rfh, '<', $tmpfile;
  local $/;
  undef $/;
  my $c = <$rfh>;
  close $rfh;
  unlink $tmpfile;
  $tmpfh->close;
  return $c;
}

sub test_server {
  my ($cv, @connections) = @_;
  my $server;
  $server = tcp_server '127.0.0.1', undef, sub {
    my ($fh, $host, $port) = @_;
    print STDERR "In server\n" if DEBUG;
    my $handle;
    $handle = AnyEvent::Handle->new(fh => $fh,
                                    on_error => sub {
                                      warn "error $_[2]\n";
                                      $_[0]->destroy;
                                    },
                                    on_eof => sub {
                                      $handle->destroy; # destroy handle
                                      warn "done.\n";
                                    },
                                    timeout => 1,
                                    on_timeout => sub {
                                      die "server timeout\n";
                                    }
                                   );
    unless (@connections) {
      die "Server received unexpected connection\n";
    }
    my @actions = @{shift @connections}; # intentional copy
    unless (@connections) {
      undef $server;
    }
    handle_connection($handle, \@actions);
    undef $handle;
  }, sub {
    my ($fh, $host, $port) = @_;
    die "tcp_server setup failed: $!\n" unless ($fh);
    $cv->send([$host, $port]);
  };
  return $server;
}

sub handle_connection {
  my ($handle, $actions) = @_;
  print STDERR "In handle connection ", scalar @$actions, "\n" if DEBUG;
  my $rec = shift @$actions;
  unless ($rec) {
    print STDERR "closing connection\n" if DEBUG;
    return $handle->push_shutdown;
  }
  if ($rec->{sleep}) {
    # pause to permit read to happen
    my $w; $w = AnyEvent->timer(after => $rec->{sleep}, cb => sub {
                                  handle_connection($handle, $actions);
                                  undef $w;
                                });
    return;
  }
  my ($desc, $recv, $send) = @{$rec}{qw/desc recv send/};
  $send =~ s/\s+//g if (defined $send);
  unless (defined $recv) {
    if (ref $send) {
      print STDERR $send."->send:\n" if DEBUG;
      $send->();
    } else {
      print STDERR "Sending: ", $send if DEBUG;
      $send = pack "H*", $send;
      print STDERR "Sending ", length $send, " bytes\n" if DEBUG;
      $handle->push_write($send);
    }
    handle_connection($handle, $actions);
    return;
  }
  $recv =~ s/\s+//g;
  my $expect = $recv;
  print STDERR "Waiting for ", $recv, "\n" if DEBUG;
  my $len = .5*length $recv;
  print STDERR "Waiting for ", $len, " bytes\n" if DEBUG;
  $handle->push_read(chunk => $len,
                     sub {
                       print STDERR "In receive handler\n" if DEBUG;
                       my $got = uc unpack 'H*', $_[1];
                       is($got, $expect,
                          '... correct message received by server - '.$desc);
                       if (ref $send) {
                         print STDERR $send."->send:\n" if DEBUG;
                         $send->();
                       } else {
                         print STDERR "Sending: ", $send, "\n" if DEBUG;
                         $send = pack "H*", $send;
                         print STDERR "Sending ", length $send, " bytes\n"
                           if DEBUG;
                         $handle->push_write($send);
                       }
                       handle_connection($handle, $actions);
                       1;
                     });
}

1;
