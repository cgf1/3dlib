package Thumbs;
use v5.40;
use experimental qw(class refaliasing declared_refs);
use File::Basename qw(basename dirname);
use File::Copy qw(copy);
use File::Path qw(make_path);
use File::Find qw(find);
use File::Temp qw(tempdir);
use LibConfig qw(thumbs_dir library_root);
use DB ();
use Meta ();
use Util qw(path_ext);

# Preferred order when picking a file to mesh-render for an item
my @MESH_PREVIEW_EXTS = qw(3mf stl obj step stp fcstd amf ply);

sub ensure_item_thumb {
  my ($item_id, %o) = @_;
  my $force = $o{force} // 0;

  my $row = DB::get_item($item_id) or return;
  my \%item = $row;

  my $tdir = thumbs_dir();
  make_path($tdir);
  my $out = "$tdir/$item_id.png";
  # Prefer canonical path under .thumbs/ for mtime checks
  my $thumb = (-f $out && -s $out) ? $out
    : (($item{thumb_path} && -f $item{thumb_path}) ? $item{thumb_path} : undef);

  my $stale = $thumb ? _thumb_is_stale(\%item, $item_id, $thumb) : 1;
  if (!$force && $thumb && !$stale) {
    return $item{thumb_path} && -f $item{thumb_path} ? $item{thumb_path} : $thumb;
  }

  # Force or stale: remove previous thumb so extraction/render rewrites
  if (($force || $stale) && -e $out) {
    unlink $out or warn "could not remove old thumb $out: $!\n";
  }
  if (($force || $stale) && $item{thumb_path} && $item{thumb_path} ne $out && -e $item{thumb_path}) {
    # leave non-canonical thumbs alone; we write to $out
  }

  # 1) Project photo/preview images
  if (($item{kind} // '') eq 'project') {
    my $img = _find_project_image($item{path});
    _normalize_image($img, $out) if $img && (!-f $out || !-s $out);
  }

  # 2) Embedded 3MF thumbnails / plate previews
  unless (-f $out && -s $out) {
    my $files = DB::item_files($item_id);
    for my $f ($files->@*) {
      my \%file = $f;
      next unless ($file{ext} // '') eq '3mf' || ($file{path} // '') =~ /\.3mf$/i;
      next unless $file{path} && -f $file{path};
      last if Meta::extract_3mf_thumb_to($file{path}, $out);
    }
    if ((!-f $out || !-s $out)
      && ($item{path} // '') =~ /\.3mf$/i
      && -f $item{path})
    {
      Meta::extract_3mf_thumb_to($item{path}, $out);
    }
  }

  # 3) Render mesh/CAD via mesh-preview (STL, STEP, OBJ, 3MF, …)
  unless (-f $out && -s $out) {
    my $src = _pick_mesh_source(\%item, $item_id);
    _mesh_preview($src, $out) if $src;
  }

  if (-f $out && -s $out) {
    DB::dbh()->do(
      'UPDATE items SET thumb_path = ?, updated_at = ? WHERE id = ?',
      undef, $out, time, $item_id
    );
    return $out;
  }
  return;
}

# Generate thumbs for missing/stale items and/or specific IDs.
# Options: force, verbose, limit, ids => [1,2,…]
# Default (no ids, no force): items with missing OR outdated thumbs.
sub generate_missing {
  my (%o) = @_;
  my $force   = $o{force} // 0;
  my $verbose = $o{verbose} // 0;
  my $limit   = $o{limit} // 5000;
  my @ids     = @{ $o{ids} // [] };

  my @rows;
  if (@ids) {
    for my $id (@ids) {
      my $row = DB::get_item($id);
      die "No catalog item with id $id\n" unless $row;
      push @rows, $row;
    }
  }
  elsif ($force) {
    @rows = DB::list_items(limit => $limit)->@*;
  }
  else {
    # missing or stale relative to source file mtime
    for my $row (DB::list_items(limit => $limit)->@*) {
      my \%it = $row;
      my $thumb = $it{thumb_path};
      if (!$thumb || !-f $thumb) {
        my $canon = thumbs_dir() . "/$it{id}.png";
        $thumb = $canon if -f $canon;
      }
      if (!$thumb || !-f $thumb || _thumb_is_stale(\%it, $it{id}, $thumb)) {
        push @rows, $row;
      }
    }
  }

  my $n = 0;
  for my $row (@rows) {
    my \%it = $row;
    my $t = ensure_item_thumb($it{id}, force => $force);
    $n++ if $t;
    if ($verbose) {
      my $why = $force ? 'force' : '';
      say "thumb #$it{id}: ", ($t // 'none'), ($why ? " ($why)" : '');
    }
  }
  return $n;
}

# True if thumb is missing or older than the newest relevant source file.
sub _thumb_is_stale {
  my ($item, $item_id, $thumb_path) = @_;
  return 1 unless $thumb_path && -f $thumb_path;
  my $thumb_mt = (stat($thumb_path))[9] // 0;
  my $src_mt   = _source_mtime($item, $item_id);
  return 0 unless $src_mt;
  return $thumb_mt < $src_mt;
}

# Newest mtime among the item path and its model/image files.
sub _source_mtime {
  my ($item, $item_id) = @_;
  my $mt = 0;

  my $bump = sub {
    my ($p) = @_;
    return unless $p && -e $p;
    my $m = (stat($p))[9] // 0;
    $mt = $m if $m > $mt;
  };

  $bump->($item->{path});

  if ($item->{path} && -d $item->{path}) {
    find({
      wanted => sub {
        return unless -f $_;
        my $ext = path_ext($_);
        return unless $ext =~ /^(3mf|stl|obj|step|stp|fcstd|amf|ply|png|jpe?g|webp)$/;
        $bump->($File::Find::name);
      },
      no_chdir => 1,
    }, $item->{path});
  }

  my $files = DB::item_files($item_id);
  for my $f ($files->@*) {
    my \%file = $f;
    next if ($file{role} // '') eq 'backup';
    $bump->($file{path});
  }

  # DB mtime as weak fallback
  if (!$mt && $item->{mtime}) {
    $mt = $item->{mtime};
  }
  return $mt;
}

# Resolve CLI targets (ids, paths, or latest / latest-N) to item ids.
sub resolve_targets {
  my (@targets) = @_;
  require Util;
  my @ids;
  for my $t (@targets) {
    $t = Util::text_for_db($t);
    my $row = DB::resolve_item_ref($t);
    die "Not in catalog: $t\n" unless $row;
    push @ids, $row->{id};
  }
  return @ids;
}

sub _pick_mesh_source ($item, $item_id) {
  my @candidates;

  if (($item->{kind} // '') eq 'file' && $item->{path} && -f $item->{path}) {
    my $ext = path_ext($item->{path});
    push @candidates, $item->{path}
      if grep { $_ eq $ext } @MESH_PREVIEW_EXTS;
  }

  my $files = DB::item_files($item_id);
  for my $f ($files->@*) {
    my \%file = $f;
    next unless $file{path} && -f $file{path};
    next if ($file{role} // '') eq 'backup';
    my $ext = lc($file{ext} // path_ext($file{path}));
    next unless grep { $_ eq $ext } @MESH_PREVIEW_EXTS;
    push @candidates, $file{path};
  }

  my %prio = map { $MESH_PREVIEW_EXTS[$_] => $_ } 0 .. $#MESH_PREVIEW_EXTS;
  @candidates = sort {
    my $ea = path_ext($a);
    my $eb = path_ext($b);
    ($prio{$ea} // 99) <=> ($prio{$eb} // 99)
      || (-s $a // 1e15) <=> (-s $b // 1e15)
  } @candidates;

  my %seen;
  for my $p (@candidates) {
    next if $seen{$p}++;
    return $p if -f $p && -s $p;
  }
  return;
}

sub _mesh_preview_bin {
  for my $c (
    $ENV{THREEDLIB_MESH_PREVIEW},
    '/usr/local/bin/mesh-preview',
    '/usr/local/3dlib/bin/mesh-preview',
  ) {
    next unless defined $c && length $c && -x $c;
    return $c;
  }
  return;
}

sub _mesh_preview ($src, $dest) {
  my $bin = _mesh_preview_bin();
  unless ($bin) {
    warn "mesh-preview not found; cannot render $src\n";
    return 0;
  }

  my $tmpdir = tempdir(CLEANUP => 1);
  my $tmp    = "$tmpdir/preview.png";

  my $rc = system($bin, $src, $tmp, '--size', '512');
  if ($rc != 0 || !-f $tmp || -s $tmp < 64) {
    warn "mesh-preview failed for $src (exit $rc)\n";
    return 0;
  }

  make_path(dirname($dest));
  copy($tmp, $dest) or do {
    warn "copy thumb $tmp -> $dest: $!\n";
    return 0;
  };
  return -f $dest && -s $dest;
}

sub _find_project_image {
  my ($dir) = @_;
  return unless -d $dir;
  my @cands;
  find({
    wanted => sub {
      return unless -f $_;
      my $ext = path_ext($_);
      return unless $ext =~ /^(png|jpe?g|gif|webp)$/;
      my $p = $File::Find::name;
      my $score = 0;
      $score += 10 if $p =~ /images?\//i;
      $score += 5  if basename($p) =~ /featured|preview|cover|thumb/i;
      push @cands, [ $score, -s $p, $p ];
    },
    no_chdir => 1,
  }, $dir);
  return unless @cands;
  @cands = sort { $b->[0] <=> $a->[0] || $b->[1] <=> $a->[1] } @cands;
  return $cands[0][2];
}

sub _normalize_image {
  my ($src, $dest) = @_;
  if (-x '/usr/bin/convert' || -x '/usr/bin/magick') {
    my $cmd = -x '/usr/bin/magick' ? 'magick' : 'convert';
    my $rc = system($cmd, $src, '-resize', '512x512>', $dest);
    return 1 if $rc == 0 && -f $dest;
  }
  copy($src, $dest);
  return -f $dest;
}

1;
