package Run;
use v5.40;
use experimental qw(class refaliasing declared_refs);
use File::Basename qw(basename dirname);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Cwd qw(abs_path);
use HTTP::Tiny;
use Text::ParseWords qw(shellwords);
use Meta ();
use Import ();
use DB ();
use LibConfig ();
use Util qw(dry_print path_ext);
use Item ();

sub run {
  my (%o) = @_;
  my $target    = $o{target} // die "run: target required\n";
  my $dryrun    = $o{dryrun} // 0;
  my $no_import = $o{no_import} // 0;
  my $app       = lc($o{app} // 'studio');
  $app = 'studio' if $app eq 'bambu' || $app eq 'bambu-studio' || $app eq 'bambustudio';
  $app = 'freecad' if $app eq 'fc' || $app eq 'fcstd';

  my $open_path;
  my $item_id;

  # Custom URL schemes (desktop handlers → 3dlib run %u)
  #   bambustudio://library/42
  #   freecad://library/42
  #   3dlib://studio/42
  #   bambustudio://open/?file=/path  (MakerWorld / Studio deep links)
  if ($target =~ m{^(bambustudio|freecad|3dlib):}i) {
    my $p =
        $target =~ m{^bambustudio:}i ? Meta::parse_bambustudio_scheme($target)
      : $target =~ m{^freecad:}i     ? Meta::parse_freecad_scheme($target)
      :                                Meta::parse_3dlib_scheme($target);
    dry_print($dryrun, ($p->{scheme} // 'scheme'), ": ", $target);
    $app = $p->{app} if $p->{app};
    if ($p->{item_id}) {
      $target = $p->{item_id};
      $no_import = 1;
    }
    elsif ($p->{file}) {
      $target = $p->{file};
    }
    elsif ($p->{http_url}) {
      $target = $p->{http_url};
      $app    = 'studio';
    }
    elsif ($target =~ m{^bambustudio:}i) {
      # Unknown bambustudio deep link — hand off to Studio itself
      dry_print($dryrun, "passing scheme URL through to Bambu Studio");
      return _launch_app('studio', $target, $dryrun);
    }
    else {
      die "Cannot resolve scheme URL: $target\n";
    }
  }

  # Opening a FreeCAD file by path implies freecad unless caller forced studio
  if (!defined $o{app} && $target !~ m{^(bambustudio|https?):}i
    && path_ext($target) =~ /^(fcstd|f3d)\z/i)
  {
    $app = 'freecad';
  }

  # MakerWorld / HTTP URL
  if ($target =~ m{^https?://}i) {
    my $mw = Meta::parse_makerworld_url($target);
    if ($mw) {
      dry_print($dryrun, "MakerWorld model: $mw->{design_model_id}");
      if (my $ex = DB::find_by_design_id($mw->{design_model_id})) {
        my \%existing = $ex;
        dry_print($dryrun, "already in library #$existing{id}: $existing{path}");
        $open_path = _openable_path($ex, $app);
        $item_id   = $existing{id};
      }
      else {
        my $downloaded = _try_download_makerworld($mw, $dryrun);
        if ($downloaded && !$dryrun) {
          if ($no_import) {
            $open_path = $downloaded;
          }
          else {
            my $res = Import::import_path(path => $downloaded, dryrun => 0, copy => 0);
            my $r = ref $res eq 'ARRAY' ? $res->[0] : $res;
            $item_id   = $r->{item_id};
            $open_path = $r->{dest} // $r->{path};
            if ($r->{existing}) {
              $open_path = $r->{dest};
            }
          }
        }
        elsif ($dryrun) {
          dry_print(1, "would download/import MakerWorld $mw->{source_url}");
          return { dryrun => 1, url => $mw->{source_url} };
        }
        else {
          warn "Could not download model automatically; launching Studio with URL.\n";
          warn "After Studio saves/opens the file, run: 3dlib scan\n";
          return _launch_app('studio', $target, $dryrun);
        }
      }
    }
    else {
      if ($target =~ /\.(3mf|stl|zip)(\?|$)/i) {
        my $dl = _download_url($target, $dryrun);
        if ($dl && !$no_import && !$dryrun) {
          my $res = Import::import_path(path => $dl, dryrun => 0, copy => 0);
          my $r = ref $res eq 'ARRAY' ? $res->[0] : $res;
          $open_path = $r->{dest};
          $item_id   = $r->{item_id};
        }
        else {
          $open_path = $dl;
        }
      }
      else {
        return _launch_app('studio', $target, $dryrun);
      }
    }
  }
  elsif (-e $target) {
    $target = abs_path($target) // $target;
    my $root = LibConfig::library_root();
    if ($no_import || index($target, $root) == 0) {
      $open_path = $target;
      my $it = DB::find_by_path($target);
      $item_id = $it->{id} if $it;
    }
    else {
      if ($dryrun) {
        dry_print(1, "would import then open: $target");
        return { dryrun => 1, path => $target };
      }
      my $res = Import::import_path(path => $target, dryrun => 0, copy => 0);
      my $r = ref $res eq 'ARRAY' ? $res->[0] : $res;
      # Non-3D zip parked in download_dir — nothing to open in Studio
      if (($r->{action} // '') eq 'download') {
        dry_print(0, "non-3D zip moved to ", ($r->{dest} // '(unknown)'));
        return $r;
      }
      $open_path = $r->{dest} // $target;
      $item_id   = $r->{item_id};
      if ($r->{existing}) {
        $open_path = $r->{dest};
      }
    }
  }
  elsif ($target =~ /^\d+$/) {
    my $it = DB::get_item($target) or die "No item id $target\n";
    my \%row = $it;
    $open_path = _openable_path($it, $app);
    $item_id   = $row{id};
  }
  else {
    die "Cannot resolve target: $target\n";
  }

  # Catalog item + Studio: open every .stl (Studio accepts multiple args).
  my $open_arg = $open_path;
  if ($item_id && $app eq 'studio') {
    my $it = DB::get_item($item_id);
    if ($it) {
      my $paths = _studio_open_paths($it);
      if ($paths && $paths->@*) {
        $open_arg = @$paths == 1 ? $paths->[0] : $paths;
      }
    }
  }
  elsif ($app eq 'studio' && defined $open_path && -d $open_path) {
    my $paths = _stls_under_dir($open_path);
    $open_arg = $paths if $paths && @$paths;
  }

  my @check = ref $open_arg eq 'ARRAY' ? $open_arg->@* : ($open_arg);
  die "Nothing to open\n" unless @check && defined $check[0] && length $check[0];
  for my $p (@check) {
    next if $p =~ m{^https?://}i;
    die "Missing file: $p\n" unless -e $p;
  }

  my $disp = ref $open_arg eq 'ARRAY'
    ? join(' ', map { basename($_) } $open_arg->@*) . " (" . scalar($open_arg->@*) . " files)"
    : $open_arg;
  dry_print($dryrun, "open ($app): $disp", $item_id ? " (item #$item_id)" : '');
  return _launch_app($app, $open_arg, $dryrun, $item_id);
}

sub _openable_path ($item, $app = 'studio') {
  my $prefer =
      $app eq 'freecad' ? 'fcstd'
    : $app eq 'studio'  ? '3mf'
    : undef;

  if (ref $item && ref $item ne 'HASH' && $item->can('openable_path')) {
    return $item->openable_path($prefer);
  }
  my \%it = $item;
  return Item::from_row(\%it)->openable_path($prefer);
}

sub _studio_open_paths ($item) {
  if (ref $item && ref $item ne 'HASH' && $item->can('studio_open_paths')) {
    return $item->studio_open_paths;
  }
  my \%it = $item;
  return Item::from_row(\%it)->studio_open_paths;
}

# Loose directory (not yet preferred over catalog): every .stl under it.
sub _stls_under_dir ($dir) {
  return unless $dir && -d $dir;
  require File::Find;
  my @stls;
  File::Find::find({
    wanted => sub {
      return unless -f $_;
      return unless path_ext($File::Find::name) eq 'stl';
      push @stls, $File::Find::name;
    },
    no_chdir => 1,
  }, $dir);
  return unless @stls;
  return [ sort @stls ];
}

# Expand a command template into argv (or shell string).
# {file} is replaced with the first path; extra paths are appended.
# $files may be a path string or an arrayref of paths.
sub expand_cmd {
  my ($spec, $files, %o) = @_;
  $spec //= '';
  $spec =~ s/^\s+|\s+\z//g;
  die "empty launch command\n" unless length $spec;

  my @files = ref $files eq 'ARRAY' ? $files->@* : ($files);
  @files = grep { defined && length } @files;
  die "nothing to open\n" unless @files;
  my $file = $files[0];

  if ($o{shell}) {
    my $s = $spec;
    if ($s =~ /\{file\}/) {
      my $q = $file;
      $q =~ s/'/'\\''/g;
      $s =~ s/\{file\}/'$q'/g;
      for my $extra (@files[1 .. $#files]) {
        my $e = $extra;
        $e =~ s/'/'\\''/g;
        $s .= " '$e'";
      }
    }
    else {
      for my $f (@files) {
        my $q = $f;
        $q =~ s/'/'\\''/g;
        $s .= " '$q'";
      }
    }
    return (shell => 1, cmd => $s);
  }

  my $ph = "\0FILE\0";
  my $tmp = $spec;
  my $had_ph = ($tmp =~ s/\{file\}/$ph/g) ? 1 : 0;
  my @cmd = shellwords($tmp);
  @cmd = map { $_ eq $ph ? $file : $_ } @cmd;
  if ($had_ph) {
    push @cmd, @files[1 .. $#files] if @files > 1;
  }
  else {
    push @cmd, @files;
  }
  die "empty launch command after parse\n" unless @cmd;
  return (shell => 0, cmd => \@cmd);
}

sub _launch_app {
  my ($app, $arg, $dryrun, $item_id) = @_;
  $app //= 'studio';

  my ($label, $spec, $shell, $require_local_bin);
  if ($app eq 'freecad') {
    $label             = 'FreeCAD';
    $spec              = LibConfig::freecad_cmd();
    $shell             = LibConfig::freecad_shell();
    $require_local_bin = 0;    # may be "ssh tomoon freecad"
    # FreeCAD: single path only
    $arg = $arg->[0] if ref $arg eq 'ARRAY';
  }
  else {
    $label             = 'Bambu Studio';
    $spec              = LibConfig::load_config()->{bambu_studio} // LibConfig::BAMBU_STUDIO;
    $shell             = 0;
    $require_local_bin = 1;
  }

  my %ex = expand_cmd($spec, $arg, shell => $shell);

  my $open_disp = ref $arg eq 'ARRAY' ? [ $arg->@* ] : $arg;

  if ($dryrun) {
    if ($ex{shell}) {
      dry_print(1, "exec sh -c ", $ex{cmd});
    }
    else {
      dry_print(1, "exec ", join(' ', $ex{cmd}->@*));
    }
    return {
      dryrun  => 1,
      app     => $app,
      label   => $label,
      open    => $open_disp,
      item_id => $item_id,
      cmd     => $ex{shell} ? $ex{cmd} : join(' ', $ex{cmd}->@*),
    };
  }

  if ($require_local_bin && !$ex{shell}) {
    my $bin = $ex{cmd}[0];
    if ($bin && $bin !~ m{/} && !-x $bin) {
      # bare name on PATH is ok
    }
    elsif ($bin && $bin =~ m{/} && !-e $bin) {
      die "$label not found: $bin\n";
    }
  }

  my $pid = fork();
  if (!defined $pid) {
    die "fork failed: $!\n";
  }
  if ($pid == 0) {
    open STDIN,  '<',  '/dev/null';
    open STDOUT, '>>', '/tmp/3dlib-launch.log';
    open STDERR, '>>', '/tmp/3dlib-launch.log';
    if ($ex{shell}) {
      exec('/bin/sh', '-c', $ex{cmd}) or exit 127;
    }
    else {
      exec($ex{cmd}->@*) or exit 127;
    }
  }
  my $cmd_disp = $ex{shell} ? $ex{cmd} : join(' ', $ex{cmd}->@*);
  say "Launched $label (pid $pid): $cmd_disp";
  return {
    ok      => 1,
    app     => $app,
    label   => $label,
    pid     => $pid,
    open    => $open_disp,
    item_id => $item_id,
    cmd     => $cmd_disp,
    message => "Launched $label",
  };
}

sub _try_download_makerworld {
  my ($mw, $dryrun) = @_;
  if ($dryrun) {
    dry_print(1, "would attempt MakerWorld download for $mw->{design_model_id}");
    return '/tmp/dryrun-makerworld.3mf';
  }

  my $id = $mw->{design_model_id};
  my @try = (
    "https://makerworld.com/api/v1/design-service/design/$id/download",
  );

  my $http = HTTP::Tiny->new(
    agent        => '3dlib/1.0',
    max_redirect => 5,
    timeout      => 60,
  );

  my $dir = LibConfig::library_root() . '/inbox';
  make_path($dir);

  for my $url (@try) {
    dry_print(0, "GET $url");
    my $res = $http->get($url);
    next unless $res->{success};
    my $ct   = $res->{headers}{'content-type'} // '';
    my $body = $res->{content} // '';
    if ($body =~ /^PK/ || $ct =~ /3mf|octet|zip/i) {
      my $out = "$dir/$id.3mf";
      open my $fh, '>:raw', $out or next;
      print {$fh} $body;
      close $fh;
      say "Downloaded $out (", length($body), " bytes)";
      return $out;
    }
  }
  return;
}

sub _download_url {
  my ($url, $dryrun) = @_;
  if ($dryrun) {
    dry_print(1, "would download $url");
    return '/tmp/dryrun-download';
  }
  my $http = HTTP::Tiny->new(agent => '3dlib/1.0', timeout => 120, max_redirect => 5);
  my $res  = $http->get($url);
  die "Download failed: $url ($res->{status})\n" unless $res->{success};
  my $name = basename($url);
  $name =~ s/\?.*//;
  $name = 'download.3mf' unless $name =~ /\./;
  my $dir = LibConfig::library_root() . '/inbox';
  make_path($dir);
  my $out = "$dir/$name";
  open my $fh, '>:raw', $out or die $!;
  print {$fh} $res->{content};
  close $fh;
  return $out;
}

1;
