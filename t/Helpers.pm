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

1;
