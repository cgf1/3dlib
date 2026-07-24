package LibConfig;
use v5.40;
use experimental qw(class refaliasing declared_refs);
use Exporter qw(import);

our @EXPORT_OK = qw(
  library_root db_path thumbs_dir config_path load_config save_config
  MODEL_EXTS PROJECT_KEEPERS TYPE_DIRS BAMBU_STUDIO
);

use constant {
  DEFAULT_LIBRARY      => '/share/3d',
  DEFAULT_DOWNLOAD_DIR => '/share/tmp',
  BAMBU_STUDIO         => '/usr/local/bin/bambu-studio',
  DEFAULT_FREECAD      => 'freecad',
  DEFAULT_PORT         => 31353,
};

# Primary model / CAD extensions (lowercase, no dot)
our @MODEL_EXTS = qw(3mf stl obj step stp fcstd f3d scad amf);
our %MODEL_EXT  = map { $_ => 1 } @MODEL_EXTS;

# Files to keep when importing a project directory
our @PROJECT_KEEPERS = qw(
  url URL url.txt URL.txt readme.txt README.txt README.md readme.md
  license.txt LICENSE.txt LICENSE LICENSE.md
);

our %TYPE_DIRS = (
  stl   => 'stl',
  obj   => 'stl',
  '3mf' => '3mf',
  step  => 'step',
  stp   => 'step',
  fcstd => 'fcstd',
  f3d   => 'fcstd',
  scad  => 'fcstd',
  amf   => '3mf',
);

sub library_root () {
  my $cfg = load_config();
  return $cfg->{library_root} // DEFAULT_LIBRARY;
}

# Destination for non-3D zips (and other “not a library model” drops).
# Env: THREEDLIB_DOWNLOAD_DIR; config: download_dir. Default /share/tmp.
sub download_dir () {
  my $cfg = load_config();
  my $v =
       $ENV{THREEDLIB_DOWNLOAD_DIR}
    // $cfg->{download_dir}
    // DEFAULT_DOWNLOAD_DIR;
  $v =~ s/^\s+|\s+\z//g if defined $v;
  return (defined $v && length $v) ? $v : DEFAULT_DOWNLOAD_DIR;
}

sub db_path () {
  return library_root() . '/.library/library.db';
}

sub thumbs_dir () {
  return library_root() . '/.thumbs';
}

# External image viewer for `3dlib show` / describe --view (default: feh).
# Override with THREEDLIB_IMAGE_VIEWER or config image_viewer / tools.image_viewer.
sub image_viewer () {
  my $cfg = load_config();
  my $tools = (ref $cfg->{tools} eq 'HASH') ? $cfg->{tools} : {};
  my $v =
       $ENV{THREEDLIB_IMAGE_VIEWER}
    // $cfg->{image_viewer}
    // $tools->{image_viewer}
    // 'feh';
  $v =~ s/^\s+|\s+\z//g if defined $v;
  return (defined $v && length $v) ? $v : 'feh';
}

# FreeCAD launch command (default: freecad).
# Examples:
#   "freecad"
#   "ssh -Y tomoon freecad"
#   "ssh -Y tomoon freecad {file}"
# Env: THREEDLIB_FREECAD; config freecad or tools.freecad
# Set freecad_shell / tools.freecad_shell true for full shell (pipes, complex quoting).
sub freecad_cmd () {
  my $cfg = load_config();
  my $tools = (ref $cfg->{tools} eq 'HASH') ? $cfg->{tools} : {};
  my $v =
       $ENV{THREEDLIB_FREECAD}
    // $cfg->{freecad}
    // $tools->{freecad}
    // DEFAULT_FREECAD;
  $v =~ s/^\s+|\s+\z//g if defined $v;
  return (defined $v && length $v) ? $v : DEFAULT_FREECAD;
}

sub freecad_shell () {
  my $cfg = load_config();
  my $tools = (ref $cfg->{tools} eq 'HASH') ? $cfg->{tools} : {};
  my $v = $ENV{THREEDLIB_FREECAD_SHELL} // $cfg->{freecad_shell} // $tools->{freecad_shell};
  return 0 unless defined $v;
  return 0 if $v =~ /^(0|false|no|off)$/i;
  return 1 if $v =~ /^(1|true|yes|on)$/i;
  return $v ? 1 : 0;
}

# On-disk config path (env root or default). Independent of library_root inside the file.
sub load_config_path () {
  return ($ENV{THREEDLIB_ROOT} // DEFAULT_LIBRARY) . '/.library/config.json';
}

# Effective library's config path (after library_root is resolved).
sub config_path () {
  return library_root() . '/.library/config.json';
}

# Raw file contents as a hash (no defaults). Empty hash if missing/invalid.
sub read_config_file {
  my ($path) = @_;
  $path //= load_config_path();
  return {} unless defined $path && -f $path;
  open my $fh, '<:encoding(UTF-8)', $path or return {};
  local $/;
  my $raw = <$fh>;
  close $fh;
  require JSON::PP;
  my $j = eval { JSON::PP->new->decode($raw) };
  return (ref $j eq 'HASH') ? $j : {};
}

sub load_config {
  my $path = load_config_path();
  my %cfg = (
    library_root => $ENV{THREEDLIB_ROOT} // DEFAULT_LIBRARY,
    bind         => '0.0.0.0',
    port         => DEFAULT_PORT,
    bambu_studio => BAMBU_STUDIO,
  );
  my $j = read_config_file($path);
  if ($j && ref $j eq 'HASH' && keys %$j) {
    %cfg = (%cfg, %$j);
  }
  $cfg{library_root} = $ENV{THREEDLIB_ROOT} if $ENV{THREEDLIB_ROOT};
  return \%cfg;
}

# Write config hash to the on-disk path load_config reads (pretty JSON).
sub save_config {
  my ($cfg) = @_;
  die "save_config: expected hashref\n" unless ref $cfg eq 'HASH';
  require JSON::PP;
  require File::Path;
  my $path = load_config_path();
  my $dir  = $path =~ s{/[^/]+\z}{}r;
  File::Path::make_path($dir);
  # Atomic-ish replace
  my $tmp = "$path.tmp.$$";
  open my $fh, '>:encoding(UTF-8)', $tmp or die "Cannot write $tmp: $!\n";
  # No ->utf8: handle is already :encoding(UTF-8)
  print {$fh} JSON::PP->new->pretty->canonical->encode($cfg);
  close $fh;
  rename($tmp, $path) or die "Cannot replace $path: $!\n";
  return $path;
}

sub is_model_ext ($ext) {
  $ext = lc($ext // '');
  $ext =~ s/^\.//;
  return $MODEL_EXT{$ext} ? 1 : 0;
}

sub type_for_ext ($ext) {
  $ext = lc($ext // '');
  $ext =~ s/^\.//;
  return 'step'  if $ext eq 'stp';
  return 'fcstd' if $ext eq 'f3d' || $ext eq 'scad';
  return 'stl'   if $ext eq 'obj';
  return '3mf'   if $ext eq 'amf';
  return $ext if $MODEL_EXT{$ext};
  return 'other';
}

1;
