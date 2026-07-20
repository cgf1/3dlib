package ThreeDLib;
# Shared modern-Perl prelude for 3dlib modules.
#   use ThreeDLib;   # enables v5.40, class, ref aliasing, try/catch
use v5.40;
use experimental qw(class refaliasing declared_refs);

use Exporter qw(import);
our @EXPORT = qw();          # features only; nothing to export
our @EXPORT_OK = qw();

# Re-export nothing: loading this package is enough for `use ThreeDLib`
# to pull in version/feature pragmas for the *caller* only if we use import.
# Callers should do:
#   use v5.40;
#   use experimental qw(class refaliasing declared_refs);
# or simply: use ThreeDLib ();  — features do NOT leak via use.
#
# So provide an import that enables features in the caller:

sub import {
  my $caller = caller;
  strict->import;
  warnings->import;
  feature->import(':5.40');
  experimental->import(qw(class refaliasing declared_refs));
  # ensure utf8-friendly defaults in library code
  feature->import('try') if feature->can('import');
}

1;

__END__

=head1 NAME

ThreeDLib - modern Perl feature bootstrap for 3dlib

=head1 SYNOPSIS

  use ThreeDLib;

  my \%item = $row;          # ref aliasing
  try { ... } catch ($e) { ... }

  class Example {
    field $x :param :reader;
  }

=cut
