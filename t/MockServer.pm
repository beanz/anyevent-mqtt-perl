use strict;
use warnings;
package t::MockServer;

=head1 NAME

t::MockServer - Perl extension for Mock Server using AnyEvent

=head1 SYNOPSIS

  use t::MockServer;
  my $server = t::MockServer->new([ [ recv => 'hello', 'received hello' ],
                                    [ send => 'test', 'sent test' ] ], [...]);

=head1 DESCRIPTION

Common functions to make test scripts a bit easier to read.

=cut

use base 'Exporter';
use constant {
  DEBUG => $ENV{ANYEVENT_TEST_MOCK_SERVER_DEBUG}
};
use AnyEvent;
use AnyEvent::Socket;
use AnyEvent::Handle;
use Test::More;
use Scalar::Util qw/weaken/;

our %EXPORT_TAGS = ( 'all' => [ qw(mocksend mockrecv mocksleep mockcode) ] );
our @EXPORT_OK = ( @{ $EXPORT_TAGS{'all'} } );
our @EXPORT = qw();

sub new {
  my $pkg = shift;
  my $self =
    {
     connections => [ @_ ],
     listening => AnyEvent->condvar,
    };
  bless $self, $pkg;
  my $weak_self = $self; weaken $self;
  $self->{server} =
    tcp_server '127.0.0.1', undef, sub {
      my ($fh, $host, $port) = @_;
      print STDERR "In server\n" if DEBUG;
      my $handle;
      $handle =
        AnyEvent::Handle->new(fh => $fh,
                              on_error => sub {
                                my ($hdl, $fatal, $msg) = @_;
                                warn "error $msg\n";
                                $hdl->destroy;
                              },
                              on_eof => sub {
                                my ($hdl) = @_;
                                $hdl->destroy; # destroy handle
                                warn "done.\n";
                              },
                              timeout => 2,
                              on_timeout => sub {
                                die "server timeout\n";
                              }
                             );
      print STDERR "Connection handle: $handle\n" if DEBUG;
      $self->{handles}->{$handle} = $handle;
      my $con = $self->{connections};
      unless (@$con) {
        die "Server received unexpected connection\n";
      }
      my $actions = shift @$con;
      unless (@$con) {
        delete $self->{server};
      }
      $self->handle_connection($handle, $actions);
    }, sub {
      my ($fh, $host, $port) = @_;
      die "tcp_server setup failed: $!\n" unless ($fh);
      $self->{listening}->send([$host, $port]);
    };
  return $self;
}

sub DESTROY {
  my $self = shift;
  delete $self->{listening};
  delete $self->{server};
  foreach (values %{$self->{handles}}) {
    next unless (defined $_);
    $_->destroy;
    delete $self->{handles}->{$_};
  }
}

sub listening {
  shift->{listening};
}

sub connect_address {
  @{shift->listening->recv};
}

sub connect_host {
  shift->listening->recv->[0];
}

sub connect_port {
  shift->listening->recv->[1];
}

sub connect_string {
  join ':', @{shift->connect_address}
}

sub handle_connection {
  my ($self, $handle, $actions) = @_;
  print STDERR 'In handle connection ', scalar @$actions, "\n" if DEBUG;
  my $action = shift @$actions;
  unless (defined $action) {
    print STDERR "closing connection\n" if DEBUG;
    $handle->push_shutdown;
    delete $self->{handles}->{$handle};
    return;
  }
  $action->($self, $handle, $actions);
}

sub mocksend {
  my ($data, $desc) = @_;
  sub {
    my ($server, $handle, $actions) = @_;
    my $send = $data;
    $send =~ s/\s+//g if (defined $send);
    print STDERR 'Sending: ', $send, ' ', $desc, "\n" if DEBUG;
    $send = pack 'H*', $send;
    print STDERR 'Sending ', length $send, " bytes\n" if DEBUG;
    $handle->push_write($send);
    $server->handle_connection($handle, $actions);
  }
}

sub mockrecv {
  my ($data, $desc) = @_;
  sub {
    my ($server, $handle, $actions) = @_;
    my $recv = $data;
    $recv =~ s/\s+//g;
    my $expect = $recv;
    print STDERR 'Waiting for ', $recv, ' ', $desc, "\n" if DEBUG;
    my $len = .5*length $recv;
    print STDERR 'Waiting for ', $len, " bytes\n" if DEBUG;
    $handle->push_read(chunk => $len,
                       sub {
                         my ($hdl, $data) = @_;
                         print STDERR "In receive handler\n" if DEBUG;
                         my $got = uc unpack 'H*', $data;
                         is($got, $expect,
                            '... correct message received by server - '.$desc);
                         $server->handle_connection($hdl, $actions);
                         1;
                       });
  }
}

sub mocksleep {
  my ($interval, $desc) = @_;
  sub {
    my ($server, $handle, $actions) = @_;
    print STDERR 'Sleeping for ', $interval, ' ', $desc, "\n" if DEBUG;
    my $w;
    $w = AnyEvent->timer(after => $interval,
                         cb => sub {
                           $server->handle_connection($handle, $actions);
                           undef $w;
                         });
  }
}

sub mockcode {
  my ($code, $desc) = @_;
  sub {
    my ($server, $handle, $actions) = @_;
    $code->($server, $handle);
    $server->handle_connection($handle, $actions);
  }
}

1;
