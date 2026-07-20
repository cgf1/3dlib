package Import;
use v5.40;
use experimental qw(class refaliasing declared_refs);
use File::Basename qw(basename dirname fileparse);
use File::Find qw(find);
use File::Path qw(make_path remove_tree);
use File::Temp qw(tempdir);
use File::Copy qw(copy);
use Archive::Zip qw(:ERROR_CODES);
use Cwd qw(abs_path);

use LibConfig qw(library_root);
use Util qw(
  dry_print file_hash file_stat_info ensure_unique_path sanitize_filename
  look_like_project path_ext classify_role read_text safe_rename_or_move
  translate_name human_size fmt_time now_ts text_for_db
);
use Meta ();
use DB ();

sub import_path {
  my (%o) = @_;
  my $path   = $o{path} // die "import_path: path required\n";
  my $dryrun = $o{dryrun} // 0;
  my $copy   = $o{copy} // 0;      # 0 = move (default)
  my $clean  = $o{clean} // 0;
  my $root   = library_root();

  # Normalize UTF-8 before path ops / DB storage (avoids "æé¾" mojibake)
  $path = text_for_db($path);
  $path = abs_path($path) // $path;
  $path = text_for_db($path);    # abs_path may return bytes
  die "Not found: $path\n" unless -e $path;

  # Reject non-3D single files
  if (-f $path) {
    my $ext = path_ext($path);
    if ($ext eq 'zip') {
      return _import_zip($path, %o);
    }
    unless (LibConfig::is_model_ext($ext)) {
      die "Not a 3D model file (.$ext): $path\nUse a model extension or a directory.\n";
    }
    return _import_file($path, %o);
  }

  if (-d $path) {
    return _import_directory($path, %o);
  }
  die "Cannot import: $path\n";
}

sub _import_directory {
  my ($dir, %o) = @_;
  my $dryrun = $o{dryrun} // 0;
  my $copy   = $o{copy} // 0;
  my $clean  = $o{clean} // 0;
  my @results;

  # If the directory itself is a project, import as one unit
  if (look_like_project($dir)) {
    push @results, _import_project($dir, %o);
    return \@results;
  }

  # Otherwise: only 3D files (and zips); subdirs that look like projects
  my @projects;
  my @files;
  my @zips;
  my $skipped = 0;

  find({
    wanted => sub {
      my $p = text_for_db($File::Find::name);
      return if $p eq $dir;
      # skip deep into project dirs we'll handle as units
      if (-d $p && look_like_project($p)) {
        push @projects, $p;
        $File::Find::prune = 1;
        return;
      }
      return unless -f $p;
      my $ext = path_ext($p);
      if ($ext eq 'zip') {
        push @zips, $p;
        return;
      }
      if (LibConfig::is_model_ext($ext)) {
        push @files, $p;
        return;
      }
      $skipped++;
    },
    no_chdir => 1,
  }, $dir);

  dry_print($dryrun, "Directory scan: ",
    scalar(@projects), " projects, ",
    scalar(@files), " models, ",
    scalar(@zips), " zips, ",
    $skipped, " non-3d skipped");

  for my $p (sort @projects) {
    push @results, _import_project($p, %o);
  }
  for my $z (sort @zips) {
    push @results, _import_zip($z, %o);
  }
  for my $f (sort @files) {
    push @results, _import_file($f, %o);
  }

  if ($clean && !$dryrun) {
    # Only clean if we moved everything we care about
    unless ($copy) {
      dry_print(0, "Note: --clean with directory: removing empty dirs under $dir if empty");
      _clean_empty($dir);
    }
  }
  elsif ($clean && $dryrun) {
    dry_print(1, "would clean empty leftovers under $dir (if move mode)");
  }

  return \@results;
}

sub _import_project {
  my ($dir, %o) = @_;
  my $dryrun = $o{dryrun} // 0;
  my $copy   = $o{copy} // 0;
  my $clean  = $o{clean} // 0;
  my $root   = library_root();

  my $name_orig = text_for_db(basename($dir));
  my $name = sanitize_filename(translate_name($name_orig));
  $name =~ s/\s+/_/g;

  my $src = Meta::harvest_project_sources($dir);
  my $dest = ensure_unique_path("$root/projects/$name");

  dry_print($dryrun, "project: $dir -> $dest");

  if ($dryrun) {
    return {
      action => 'project',
      source => $dir,
      dest   => $dest,
      dryrun => 1,
      name   => $name,
      source_url => $src->{source_url},
    };
  }

  # Move or copy tree
  if ($copy) {
    _copy_tree($dir, $dest);
  }
  else {
    if (!rename($dir, $dest)) {
      _copy_tree($dir, $dest);
      remove_tree($dir);
    }
  }
  if ($name_orig ne basename($dest)) {
    DB::log_rename($dir, $dest, 'project import');
  }

  my $item_id = _catalog_project($dest, $name_orig, $src);
  DB::log_import(
    source => $dir, dest => $dest, action => ($copy ? 'copy-project' : 'move-project'),
    item_id => $item_id, detail => $name
  );

  if ($clean && $copy && -e $dir) {
    remove_tree($dir);
    dry_print(0, "cleaned source $dir");
  }

  # thumbs
  try { require Thumbs; Thumbs::ensure_item_thumb($item_id) } catch ($e) { warn "thumb: $e" };

  return {
    action  => 'project',
    source  => $dir,
    dest    => $dest,
    item_id => $item_id,
    name    => $name,
  };
}

sub _import_file {
  my ($file, %o) = @_;
  my $dryrun = $o{dryrun} // 0;
  my $copy   = $o{copy} // 0;
  my $clean  = $o{clean} // 0;
  my $root   = library_root();

  my $ext  = path_ext($file);
  my $type = LibConfig::type_for_ext($ext);
  my $bambu = Meta::parse_bambu_filename($file);
  if ($bambu && $bambu->{incomplete}) {
    dry_print($dryrun, "SKIP incomplete download: $file");
    return { action => 'skip', source => $file, reason => 'incomplete download' };
  }

  my $meta3 = ($ext eq '3mf') ? Meta::extract_3mf_meta($file) : {};
  my $hash  = file_hash($file);

  # Dedupe
  if (my $ex = DB::find_by_hash($hash)) {
    dry_print($dryrun, "DUPLICATE hash -> existing #$ex->{id} $ex->{path}");
    DB::log_import(
      source => $file, dest => $ex->{path}, action => 'duplicate-hash',
      item_id => $ex->{id}, detail => $hash
    ) unless $dryrun;
    if ($clean && !$copy && !$dryrun) {
      unlink($file) or warn "clean failed: $file: $!\n";
    }
    return {
      action  => 'duplicate',
      source  => $file,
      dest    => $ex->{path},
      item_id => $ex->{id},
      existing => 1,
    };
  }
  if ($meta3->{design_model_id}) {
    if (my $ex = DB::find_by_design_id($meta3->{design_model_id})) {
      dry_print($dryrun, "DUPLICATE DesignModelId -> existing #$ex->{id}");
      DB::log_import(
        source => $file, dest => $ex->{path}, action => 'duplicate-design',
        item_id => $ex->{id}, detail => $meta3->{design_model_id}
      ) unless $dryrun;
      if ($clean && !$copy && !$dryrun) {
        unlink($file) or warn "clean failed: $file: $!\n";
      }
      return {
        action  => 'duplicate',
        source  => $file,
        dest    => $ex->{path},
        item_id => $ex->{id},
        existing => 1,
      };
    }
  }

  # Prefer filename name= (Bambu downloads), then 3MF Title, then basename
  my $display = ($bambu && $bambu->{name}) || $meta3->{title} || basename($file);
  $display = text_for_db($display);
  $display = translate_name($display);
  $display = sanitize_filename($display);
  # ensure extension
  my ($stem, undef, $fext) = fileparse($display, qr/\.[^.]*/);
  if (lc($fext // '') ne ".$ext") {
    $display = "$stem.$ext";
    $display =~ s/\.+$ext\.$ext$/.$ext/i;
    $display = sanitize_filename($stem) . ".$ext" unless $display =~ /\.$ext$/i;
  }
  # fix double ext
  $display =~ s/\.3mf\.3mf$/.3mf/i;

  my $subdir = $LibConfig::TYPE_DIRS{$ext} // $LibConfig::TYPE_DIRS{$type} // 'inbox';
  my $dest   = ensure_unique_path("$root/$subdir/$display");

  dry_print($dryrun, ($copy ? 'copy' : 'move'), " file: $file -> $dest");

  if ($dryrun) {
    return {
      action => 'file',
      source => $file,
      dest   => $dest,
      type   => $type,
      dryrun => 1,
      name   => $display,
      design_model_id => $meta3->{design_model_id},
      source_url => $meta3->{source_url},
    };
  }

  my $name_orig = text_for_db(basename($file));
  $dest = safe_rename_or_move(src => $file, dest => $dest, copy => $copy, dryrun => 0);
  $dest = text_for_db($dest);
  if ($name_orig ne text_for_db(basename($dest)) || dirname($file) ne dirname($dest)) {
    DB::log_rename($file, $dest, 'file import rename');
  }

  my $st = file_stat_info($dest);
  my $summary = $meta3->{description} || $meta3->{title} || $stem;
  my $desc = Meta::build_description(
    summary    => $summary,
    designer   => $meta3->{designer},
    license    => $meta3->{license},
    source_url => $meta3->{source_url},
    mtime      => $st->{mtime},
  );

  my $item_id = DB::upsert_item({
    kind            => 'file',
    type            => $type,
    path            => $dest,
    name            => text_for_db(basename($dest)),
    name_orig       => $name_orig,
    description     => $desc,
    source_site     => $meta3->{source_site},
    source_url      => $meta3->{source_url},
    source_id       => $meta3->{source_id},
    design_model_id => $meta3->{design_model_id},
    download_uuid   => $bambu && $bambu->{download_uuid},
    mtime           => $st->{mtime},
    atime           => $st->{atime},
    size_bytes      => $st->{size},
    file_count      => 1,
    content_hash    => $hash,
    status          => 'unsorted',
  });
  DB::replace_files($item_id, [{
    path => $dest, relpath => basename($dest), ext => $ext,
    size_bytes => $st->{size}, mtime => $st->{mtime}, atime => $st->{atime},
    role => 'model', content_hash => $hash,
  }]);
  DB::log_import(
    source => $file, dest => $dest,
    action => ($copy ? 'copy-file' : 'move-file'),
    item_id => $item_id, detail => $type
  );

  if ($clean && $copy && -e $file) {
    unlink($file) or warn "clean $file: $!\n";
  }

  try { require Thumbs; Thumbs::ensure_item_thumb($item_id) } catch ($e) { warn "thumb: $e" };

  return {
    action  => 'file',
    source  => $file,
    dest    => $dest,
    item_id => $item_id,
    type    => $type,
    name    => basename($dest),
  };
}

sub _import_zip {
  my ($zipfile, %o) = @_;
  my $dryrun = $o{dryrun} // 0;
  my $copy   = $o{copy} // 0;
  my $clean  = $o{clean} // 0;
  my $root   = library_root();

  my $base = text_for_db(basename($zipfile));
  $base =~ s/\.zip$//i;
  $base = sanitize_filename(translate_name($base));
  $base =~ s/\s+/_/g;

  my $dest_proj = ensure_unique_path("$root/projects/$base");
  dry_print($dryrun, "unpack zip: $zipfile -> $dest_proj");

  if ($dryrun) {
    return {
      action => 'zip',
      source => $zipfile,
      dest   => $dest_proj,
      dryrun => 1,
    };
  }

  make_path($dest_proj);
  my $zip = Archive::Zip->new();
  if ($zip->read($zipfile) != AZ_OK) {
    # fallback unzip
    my $rc = system('unzip', '-q', '-o', $zipfile, '-d', $dest_proj);
    die "Failed to unpack $zipfile\n" if $rc != 0;
  }
  else {
    $zip->extractTree('', "$dest_proj/");
  }

  # If zip had a single top-level dir, flatten
  _maybe_flatten($dest_proj);

  my $src = Meta::harvest_project_sources($dest_proj);
  my $item_id = _catalog_project($dest_proj, text_for_db(basename($zipfile)), $src);

  DB::log_import(
    source => $zipfile, dest => $dest_proj, action => 'unpack-zip',
    item_id => $item_id, detail => $base
  );

  if (!$copy) {
    unlink($zipfile) or warn "could not remove zip $zipfile: $!\n";
  }
  elsif ($clean) {
    unlink($zipfile) or warn "clean zip $zipfile: $!\n";
  }

  try { require Thumbs; Thumbs::ensure_item_thumb($item_id) } catch ($e) { warn "thumb: $e" };

  return {
    action  => 'zip',
    source  => $zipfile,
    dest    => $dest_proj,
    item_id => $item_id,
  };
}

sub _maybe_flatten {
  my ($dir) = @_;
  opendir my $dh, $dir or return;
  my @ents = grep { $_ ne '.' && $_ ne '..' } readdir($dh);
  closedir $dh;
  return unless @ents == 1 && -d "$dir/$ents[0]";
  my $inner = "$dir/$ents[0]";
  opendir my $ih, $inner or return;
  my @inner = grep { $_ ne '.' && $_ ne '..' } readdir($ih);
  closedir $ih;
  for my $e (@inner) {
    rename("$inner/$e", "$dir/$e") or copy("$inner/$e", "$dir/$e");
  }
  remove_tree($inner);
}

sub _catalog_project {
  my ($dest, $name_orig, $src) = @_;
  $src //= Meta::harvest_project_sources($dest);

  my @files;
  my ($mtime, $atime, $size, $count) = (0, 0, 0, 0);
  my %types;
  find({
    wanted => sub {
      return unless -f $_;
      my $p = $File::Find::name;
      my $ext = path_ext($p);
      my $role = classify_role($p);
      return if $role eq 'backup';
      # keep models, images, readme, url, source, license
      return unless $role =~ /^(model|image|readme|url|source|license|other)$/;
      return if $role eq 'other' && !LibConfig::is_model_ext($ext)
        && $ext !~ /^(txt|md|png|jpe?g|gif|webp)$/;

      my $st = file_stat_info($p);
      my $rel = $p;
      $rel =~ s/^\Q$dest\E\/?//;
      my $h = ($role eq 'model') ? file_hash($p) : undef;
      push @files, {
        path => $p, relpath => $rel, ext => $ext,
        size_bytes => $st->{size}, mtime => $st->{mtime}, atime => $st->{atime},
        role => $role, content_hash => $h,
      };
      $count++;
      $size += $st->{size} // 0;
      $mtime = $st->{mtime} if ($st->{mtime} // 0) > $mtime;
      $atime = $st->{atime} if ($st->{atime} // 0) > $atime;
      $types{ LibConfig::type_for_ext($ext) }++ if LibConfig::is_model_ext($ext);
    },
    no_chdir => 1,
  }, $dest);

  my $type = 'mixed';
  my @tk = keys %types;
  $type = $tk[0] if @tk == 1;

  # Prefer 3mf meta from first 3mf
  my ($m3url, $m3desc, $m3design);
  for my $f (@files) {
    next unless ($f->{ext} // '') eq '3mf';
    my $m = Meta::extract_3mf_meta($f->{path});
    $m3url = $m->{source_url};
    $m3desc = $m->{description} || $m->{title};
    $m3design = $m->{design_model_id};
    last;
  }

  my $source_url  = $src->{source_url} // $m3url;
  my $source_site = $src->{source_site} // ($m3url ? 'makerworld' : undef);
  my $summary = $m3desc || "Project: " . basename($dest);
  my $desc = Meta::build_description(
    summary    => $summary,
    source_url => $source_url,
    mtime      => $mtime,
  );

  # primary hash: first model file
  my $phash;
  for my $f (@files) {
    if ($f->{role} eq 'model' && $f->{content_hash}) {
      $phash = $f->{content_hash};
      last;
    }
  }

  my $item_id = DB::upsert_item({
    kind            => 'project',
    type            => $type,
    path            => text_for_db($dest),
    name            => text_for_db(basename($dest)),
    name_orig       => text_for_db($name_orig),
    description     => $desc,
    source_site     => $source_site,
    source_url      => $source_url,
    source_id       => $src->{source_id},
    sources_json    => $src->{sources_json},
    design_model_id => $m3design,
    mtime           => $mtime,
    atime           => $atime,
    size_bytes      => $size,
    file_count      => $count,
    content_hash    => $phash,
    status          => 'active',
  });
  DB::replace_files($item_id, \@files);
  return $item_id;
}

sub _copy_tree {
  my ($src, $dest) = @_;
  make_path($dest);
  find({
    wanted => sub {
      my $p = $File::Find::name;
      my $rel = $p;
      $rel =~ s/^\Q$src\E\/?//;
      return if $rel eq '';
      my $t = "$dest/$rel";
      if (-d $p) {
        make_path($t);
      }
      elsif (-f $p) {
        make_path(dirname($t));
        copy($p, $t) or die "copy $p -> $t: $!\n";
      }
    },
    no_chdir => 1,
  }, $src);
}

sub _clean_empty {
  my ($dir) = @_;
  return unless -d $dir;
  finddepth({
    wanted => sub {
      return unless -d $_;
      rmdir $_;    # only if empty
    },
    no_chdir => 1,
  }, $dir);
}

sub scan_library {
  my (%o) = @_;
  my $root = library_root();
  my $dryrun = $o{dryrun} // 0;
  my @results;

  for my $bucket (qw(projects stl 3mf step fcstd inbox)) {
    my $d = "$root/$bucket";
    next unless -d $d;
    opendir my $dh, $d or next;
    while (my $e = readdir($dh)) {
      next if $e =~ /^\./;
      $e = text_for_db($e);
      my $p = text_for_db("$d/$e");
      if ($bucket eq 'projects' && -d $p) {
        next if DB::find_by_path($p) && !$o{force};
        if ($dryrun) {
          dry_print(1, "would catalog project $p");
          next;
        }
        my $id = _catalog_project($p, $e, Meta::harvest_project_sources($p));
        push @results, { path => $p, item_id => $id, kind => 'project' };
        try { require Thumbs; Thumbs::ensure_item_thumb($id) } catch ($err) { warn "thumb: $err" };
      }
      elsif (-f $p && LibConfig::is_model_ext(path_ext($p))) {
        next if DB::find_by_path($p) && !$o{force};
        if ($dryrun) {
          dry_print(1, "would catalog file $p");
          next;
        }
        # catalog in place without moving
        my $id = _catalog_inplace_file($p);
        push @results, { path => $p, item_id => $id, kind => 'file' };
        try { require Thumbs; Thumbs::ensure_item_thumb($id) } catch ($err) { warn "thumb: $err" };
      }
    }
    closedir $dh;
  }

  # Fix any mojibake already sitting in the catalog
  repair_catalog_encoding(dryrun => $dryrun) unless $o{no_repair};

  return \@results;
}

# Repair name / name_orig / path text that was stored as Latin-1-decoded UTF-8.
sub repair_catalog_encoding {
  my (%o) = @_;
  my $dryrun = $o{dryrun} // 0;
  my $items  = DB::list_items(limit => 100_000);
  my $n      = 0;
  for my $row ($items->@*) {
    my %upd = %$row;
    my $changed = 0;
    for my $k (qw(name name_orig path description)) {
      next unless defined $upd{$k};
      my $fixed = text_for_db($upd{$k});
      next if $fixed eq $upd{$k};
      $upd{$k} = $fixed;
      $changed = 1;
    }
    next unless $changed;
    $n++;
    dry_print($dryrun, "encoding fix #$upd{id}: ",
      ($row->{name_orig} // ''), " -> ", ($upd{name_orig} // ''));
    next if $dryrun;
    DB::upsert_item(\%upd);
  }
  dry_print($dryrun, "encoding repair: $n item(s)");
  return $n;
}

sub _catalog_exists_file {
  my ($file) = @_;
  my $ext  = path_ext($file);
  my $type = LibConfig::type_for_ext($ext);
  my $meta3 = ($ext eq '3mf') ? Meta::extract_3mf_meta($file) : {};
  my $hash = file_hash($file);
  my $st = file_stat_info($file);
  my $bambu = Meta::parse_bambu_filename($file);
  my $desc = Meta::build_description(
    summary    => $meta3->{description} || $meta3->{title} || basename($file),
    designer   => $meta3->{designer},
    license    => $meta3->{license},
    source_url => $meta3->{source_url},
    mtime      => $st->{mtime},
  );
  my $item_id = DB::upsert_item({
    kind => 'file', type => $type, path => text_for_db($file),
    name => text_for_db(basename($file)), name_orig => text_for_db(basename($file)),
    description => $desc,
    source_site => $meta3->{source_site},
    source_url => $meta3->{source_url},
    source_id => $meta3->{source_id},
    design_model_id => $meta3->{design_model_id},
    download_uuid => $bambu && $bambu->{download_uuid},
    mtime => $st->{mtime}, atime => $st->{atime}, size_bytes => $st->{size},
    content_hash => $hash, status => 'unsorted',
  });
  DB::replace_files($item_id, [{
    path => $file, relpath => basename($file), ext => $ext,
    size_bytes => $st->{size}, mtime => $st->{mtime}, atime => $st->{atime},
    role => 'model', content_hash => $hash,
  }]);
  return $item_id;
}

1;
