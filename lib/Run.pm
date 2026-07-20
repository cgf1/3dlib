package Run;
use v5.40;
use experimental qw(class refaliasing declared_refs);
use File::Basename qw(basename dirname);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Cwd qw(abs_path);
use HTTP::Tiny;
use Meta ();
use Import ();
use DB ();
use LibConfig ();
use Util qw(dry_print path_ext);
use Item ();

sub run {
  my (%o) = @_;
  my $target   = $o{target} // die "run: target required\n";
  my $dryrun   = $o{dryrun} // 0;
  my $no_import = $o{no_import} // 0;
  my $studio   = LibConfig::load_config()->{bambu_studio}
    // LibConfig::BAMBU_STUDIO;

  my $open_path;
  my $item_id;

  # bambustudio:// scheme
  if ($target =~ m{^bambustudio:}i) {
    my $p = Meta::parse_bambustudio_scheme($target);
    dry_print($dryrun, "bambustudio scheme: ", $target);
    if ($p->{file} && -e $p->{file}) {
      $target = $p->{file};
    }
    elsif ($p->{http_url}) {
      $target = $p->{http_url};
    }
    else {
      # Pass through to Studio — it understands the deep link; we still log
      dry_print($dryrun, "passing scheme URL through to Bambu Studio");
      return _exec_studio($studio, $target, $dryrun);
    }
  }

  # MakerWorld / HTTP URL
  if ($target =~ m{^https?://}i) {
    my $mw = Meta::parse_makerworld_url($target);
    if ($mw) {
      dry_print($dryrun, "MakerWorld model: $mw->{design_model_id}");
      # Dedupe by design id
      if (my $ex = DB::find_by_design_id($mw->{design_model_id})) {
        my \%existing = $ex;
        dry_print($dryrun, "already in library #$existing{id}: $existing{path}");
        $open_path = _openable_path($ex);
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
          # Fall back: open Studio with makerworld page / hope deep link works
          warn "Could not download model automatically; launching Studio with URL.\n";
          warn "After Studio saves/opens the file, run: 3dlib scan\n";
          return _exec_studio($studio, $target, $dryrun);
        }
      }
    }
    else {
      # Non-MW HTTP: try download if ends with 3mf/stl
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
        return _exec_studio($studio, $target, $dryrun);
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
    $open_path = _openable_path($it);
    $item_id   = $row{id};
  }
  else {
    die "Cannot resolve target: $target\n";
  }

  die "Nothing to open\n" unless $open_path;
  dry_print($dryrun, "open: $open_path", $item_id ? " (item #$item_id)" : '');
  return _exec_studio($studio, $open_path, $dryrun, $item_id);
}

sub _openable_path ($item) {
  # $item may be a plain hashref from DB
  if (ref $item && ref $item ne 'HASH' && $item->can('openable_path')) {
    return $item->openable_path;
  }
  my \%it = $item;
  return Item::from_row(\%it)->openable_path;
}

sub _exec_studio {
  my ($studio, $arg, $dryrun, $item_id) = @_;
  if ($dryrun) {
    dry_print(1, "exec $studio $arg");
    return { dryrun => 1, studio => $studio, open => $arg, item_id => $item_id };
  }
  if (!-x $studio && !-f $studio) {
    die "Bambu Studio not found: $studio\n";
  }
  # Detach so web/CLI returns
  my $pid = fork();
  if (!defined $pid) {
    exec($studio, $arg) or die "exec $studio: $!\n";
  }
  if ($pid == 0) {
    # child
    open STDIN,  '<', '/dev/null';
    open STDOUT, '>>', '/tmp/3dlib-studio.log';
    open STDERR, '>>', '/tmp/3dlib-studio.log';
    exec($studio, $arg) or exit 127;
  }
  say "Launched Bambu Studio (pid $pid) on $arg";
  return { ok => 1, pid => $pid, open => $arg, item_id => $item_id };
}

sub _try_download_makerworld {
  my ($mw, $dryrun) = @_;
  # Public download endpoints are inconsistent/auth-gated.
  # Try a few heuristics; return undef on failure.
  if ($dryrun) {
    dry_print(1, "would attempt MakerWorld download for $mw->{design_model_id}");
    return '/tmp/dryrun-makerworld.3mf';
  }

  my $id = $mw->{design_model_id};
  my @try = (
    "https://makerworld.com/api/v1/design-service/design/$id/download",
    # numeric ids sometimes work differently
  );

  my $http = HTTP::Tiny->new(
    agent => '3dlib/1.0',
    max_redirect => 5,
    timeout => 60,
  );

  my $dir = LibConfig::library_root() . '/inbox';
  make_path($dir);

  for my $url (@try) {
    dry_print(0, "GET $url");
    my $res = $http->get($url);
    next unless $res->{success};
    my $ct = $res->{headers}{'content-type'} // '';
    my $body = $res->{content} // '';
    # 3mf is a zip (PK)
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
  my $res = $http->get($url);
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
