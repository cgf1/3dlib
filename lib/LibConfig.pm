package LibConfig;
use v5.40;
use experimental qw(class refaliasing declared_refs);
use Exporter qw(import);

our @EXPORT_OK = qw(
  library_root db_path thumbs_dir config_path load_config save_config
  MODEL_EXTS PROJECT_KEEPERS TYPE_DIRS BAMBU_STUDIO
);

use constant {
  DEFAULT_LIBRARY => '/share/3d',
  BAMBU_STUDIO    => '/usr/local/bin/bambu-studio',
  DEFAULT_PORT    => 31353,
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

sub db_path () {
  return library_root() . '/.library/library.db';
}

sub thumbs_dir () {
  return library_root() . '/.thumbs';
}

sub config_path () {
  return library_root() . '/.library/config.json';
}

sub load_config {
  my $path = DEFAULT_LIBRARY . '/.library/config.json';
  # allow env override of root before config exists
  if ($ENV{THREEDLIB_ROOT}) {
    $path = $ENV{THREEDLIB_ROOT} . '/.library/config.json';
  }
  my %cfg = (
    library_root => $ENV{THREEDLIB_ROOT} // DEFAULT_LIBRARY,
    bind         => '0.0.0.0',
    port         => DEFAULT_PORT,
    bambu_studio => BAMBU_STUDIO,
  );
  if (-f $path) {
    open my $fh, '<:encoding(UTF-8)', $path or return \%cfg;
    local $/;
    my $raw = <$fh>;
    close $fh;
    require JSON::PP;
    my $j = eval { JSON::PP->new->utf8->decode($raw) };
    if ($j && ref $j eq 'HASH') {
      %cfg = (%cfg, %$j);
    }
  }
  $cfg{library_root} = $ENV{THREEDLIB_ROOT} if $ENV{THREEDLIB_ROOT};
  return \%cfg;
}

sub save_config {
  my ($cfg) = @_;
  require JSON::PP;
  my $root = $cfg->{library_root} // DEFAULT_LIBRARY;
  my $dir  = "$root/.library";
  require File::Path;
  File::Path::make_path($dir);
  my $path = "$dir/config.json";
  open my $fh, '>:encoding(UTF-8)', $path or die "Cannot write $path: $!\n";
  print {$fh} JSON::PP->new->utf8->pretty->canonical->encode($cfg);
  close $fh;
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
