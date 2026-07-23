package Item;
use v5.40;
use experimental qw(class refaliasing declared_refs);

use JSON::PP ();
use DB ();
use Meta ();
use Util qw(fmt_time human_size text_for_db);

# Catalog row as a Corinna-style class (feature 'class').
class Item {
  field $id :param :reader;
  field $kind :param :reader = 'file';
  field $type :param :reader = 'other';
  field $path :param :reader;
  field $name :param :reader = '';
  field $name_orig :param :reader = undef;
  field $description :param :reader = undef;
  field $source_site :param :reader = undef;
  field $source_url :param :reader = undef;
  field $source_id :param :reader = undef;
  field $design_model_id :param :reader = undef;
  field $mtime :param :reader = undef;
  field $size_bytes :param :reader = undef;
  field $file_count :param :reader = 1;
  field $content_hash :param :reader = undef;
  field $thumb_path :param :reader = undef;
  field $status :param :reader = 'active';

  method files () {
    return DB::item_files($id);
  }

  method openable_path ($prefer = undef) {
    # $prefer: optional ext like '3mf' or 'fcstd'
    if ($prefer) {
      $prefer = lc $prefer;
      $prefer =~ s/^\.//;
      if ($kind eq 'file' && -f $path) {
        require Util;
        return $path if Util::path_ext($path) eq $prefer;
      }
      for my $f ($self->files->@*) {
        my \%file = $f;
        return $file{path}
          if ($file{ext} // '') eq $prefer && -f ($file{path} // '');
      }
    }
    return $path if $kind eq 'file' && -f $path;
    for my $f ($self->files->@*) {
      my \%file = $f;
      return $file{path} if ($file{ext} // '') eq '3mf' && -f $file{path};
    }
    for my $f ($self->files->@*) {
      my \%file = $f;
      return $file{path} if ($file{ext} // '') eq 'fcstd' && -f $file{path};
    }
    for my $f ($self->files->@*) {
      my \%file = $f;
      return $file{path} if ($file{role} // '') eq 'model' && -f $file{path};
    }
    return $path;
  }

  method has_thumb () {
    return defined $thumb_path && length $thumb_path && -f $thumb_path;
  }

  method describe_to ($fh = *STDOUT) {
    # Optional: show Chinese/original fields (off by default — catalog is English-facing)
    my $show_orig = $ENV{THREEDLIB_SHOW_ORIGINAL} ? 1 : 0;

    say {$fh} "id:              $id";
    say {$fh} "name:            $name";
    # Always show original name when it differs (kept after translation)
    if (defined $name_orig && length $name_orig && $name_orig ne $name) {
      say {$fh} "name_orig:       ", $name_orig;
    }
    say {$fh} "kind/type:       $kind / $type";
    say {$fh} "path:            $path";
    say {$fh} "status:          ", $status // '';
    say {$fh} "source_site:     ", $source_site // '';
    say {$fh} "source_url:      ", $source_url // '';
    say {$fh} "design_model_id: ", $design_model_id // '';
    my $tags = DB::get_item_tags($id);
    say {$fh} "tags:            ", ($tags->@* ? join(', ', $tags->@*) : '(none)');
    say {$fh} "mtime:           ", fmt_time($mtime);
    say {$fh} "size:            ", human_size($size_bytes);
    say {$fh} "files:           ", $file_count // 0;
    say {$fh} "thumb:           ", $thumb_path // '';
    say {$fh} "hash:            ", $content_hash // '';
    say {$fh} "--- description ---";
    say {$fh} $description // '';
    if ($show_orig) {
      if (my $row = DB::get_item($id)) {
        if ($row->{description_orig} && length $row->{description_orig}) {
          say {$fh} "--- description (original) ---";
          say {$fh} $row->{description_orig};
        }
      }
    }
    my $files = $self->files;
    if ($files->@*) {
      say {$fh} "--- files ---";
      for my $f ($files->@*) {
        my \%file = $f;
        printf {$fh} "  %-10s %-6s %10s  %s\n",
          $file{role} // '', $file{ext} // '', human_size($file{size_bytes}),
          $file{relpath} // $file{path};
      }
    }
  }

  method as_hash () {
    return {
      id              => $id,
      kind            => $kind,
      type            => $type,
      path            => $path,
      name            => $name,
      name_orig       => $name_orig,
      description     => $description,
      source_site     => $source_site,
      source_url      => $source_url,
      source_id       => $source_id,
      design_model_id => $design_model_id,
      mtime           => $mtime,
      size_bytes      => $size_bytes,
      file_count      => $file_count,
      content_hash    => $content_hash,
      thumb_path      => $thumb_path,
      status          => $status,
    };
  }
}

# Factory helpers (class methods not yet first-class in core class feature)
sub from_row ($row) {
  return unless $row;
  my \%r = $row;
  return Item->new(
    id              => $r{id},
    kind            => $r{kind} // 'file',
    type            => $r{type} // 'other',
    path            => text_for_db($r{path}),
    name            => text_for_db($r{name} // ''),
    name_orig       => text_for_db($r{name_orig}),
    description     => text_for_db($r{description}),
    source_site     => $r{source_site},
    source_url      => $r{source_url},
    source_id       => $r{source_id},
    design_model_id => $r{design_model_id},
    mtime           => $r{mtime},
    size_bytes      => $r{size_bytes},
    file_count      => $r{file_count} // 1,
    content_hash    => $r{content_hash},
    thumb_path      => $r{thumb_path},
    status          => $r{status} // 'active',
  );
}

sub load ($id_or_path) {
  my $row =
      $id_or_path =~ /^\d+$/
    ? DB::get_item($id_or_path)
    : DB::find_by_path($id_or_path);
  return from_row($row);
}

# ---------------------------------------------------------------------------
# Partial catalog metadata edit (CLI). Only keys present in %o change.
#
#   target          => id or path (required)
#   dryrun          => 0/1
#   name, description, description_orig, status
#   source_url, source_site, source_id, design_model_id
#   add_urls        => [url, ...]  append additional sources
#   clear_url       => clear primary URL
#   clear_urls      => clear primary + all additional + related site ids
#   auto_from_url   => fill empty site/ids from URL (default: on when source_url set)
#
# Returns { id, name, path, changes => { field => { old, new } }, dryrun, noop? }
# ---------------------------------------------------------------------------
sub edit {
  my (%o) = @_;
  my $target = $o{target} // die "edit: target (id or path) required\n";
  my $row;
  if ($target =~ /^\d+$/) {
    $row = DB::get_item($target);
  }
  else {
    require Cwd;
    my $ap = Cwd::abs_path($target) // $target;
    $row = DB::find_by_path(text_for_db($ap)) // DB::find_by_path(text_for_db($target));
  }
  die "edit: not in catalog: $target\n" unless $row;

  my $id = $row->{id};
  my %upd;
  my %changes;

  my $set = sub ($key, $new) {
    my $orig = $row->{$key};
    $orig = undef if defined $orig && !length $orig;
    my $cur  = exists $upd{$key} ? $upd{$key} : $orig;
    $cur = undef if defined $cur && !length $cur;
    $new = undef if defined $new && !length $new;
    return if ($cur // '') eq ($new // '');
    $upd{$key} = $new;
    # Keep original "old" across multiple sets of the same key
    my $old_for_diff = exists $changes{$key} ? $changes{$key}{old} : $orig;
    if (($old_for_diff // '') eq ($new // '')) {
      # Net no change vs original — drop the pending update
      delete $upd{$key};
      delete $changes{$key};
      return;
    }
    $changes{$key} = { old => $old_for_diff, new => $new };
  };

  if (exists $o{name}) {
    my $n = text_for_db($o{name} // '');
    $n =~ s/^\s+|\s+\z//g if defined $n;
    die "edit: --name cannot be empty\n" unless defined $n && length $n;
    $set->('name', $n);
  }
  if (exists $o{description}) {
    $set->('description', text_for_db($o{description} // ''));
  }
  if (exists $o{description_orig}) {
    my $v = text_for_db($o{description_orig} // '');
    $set->('description_orig', (defined $v && length $v) ? $v : undef);
  }
  if (exists $o{status}) {
    my $st = $o{status} // '';
    $st =~ s/^\s+|\s+\z//g;
    die "edit: invalid --status\n" if !length $st || $st =~ /[^\w.-]/;
    $set->('status', $st);
  }

  # Tags / keywords (catalog-side; Bambu 3MF files do not ship keywords)
  my $tags_changed = 0;
  my @tags_orig    = DB::get_item_tags($id)->@*;
  my @tags_now     = @tags_orig;

  if ($o{clear_tags}) {
    @tags_now = ();
  }
  if (exists $o{tags_set}) {
    @tags_now = DB::normalize_tags(
      ref $o{tags_set} eq 'ARRAY' ? $o{tags_set}->@* : ($o{tags_set} // ())
    );
  }
  if ($o{tags_add}) {
    my @add = DB::normalize_tags(
      ref $o{tags_add} eq 'ARRAY' ? $o{tags_add}->@* : ($o{tags_add} // ())
    );
    my %have = map { $_ => 1 } @tags_now;
    push @tags_now, grep { !$have{$_}++ } @add;
    @tags_now = sort @tags_now;
  }
  if ($o{tags_remove}) {
    my %rm = map { $_ => 1 } DB::normalize_tags(
      ref $o{tags_remove} eq 'ARRAY' ? $o{tags_remove}->@* : ($o{tags_remove} // ())
    );
    @tags_now = grep { !$rm{$_} } @tags_now;
  }

  {
    my $old_s = join(', ', @tags_orig);
    my $new_s = join(', ', @tags_now);
    if ($old_s ne $new_s) {
      $tags_changed = 1;
      $changes{tags} = { old => $old_s, new => $new_s };
      DB::set_item_tags($id, @tags_now) unless $o{dryrun};
    }
  }

  my $primary = $row->{source_url};
  $primary = undef if defined $primary && !length $primary;
  my @extras  = _sources_list($row->{sources_json}, $primary);
  my $rebuild_sources = 0;

  if ($o{clear_urls}) {
    $primary         = undef;
    @extras          = ();
    $rebuild_sources = 1;
    $set->('source_url',      undef);
    $set->('source_site',     undef) unless exists $o{source_site};
    $set->('source_id',       undef) unless exists $o{source_id};
    $set->('design_model_id', undef) unless exists $o{design_model_id};
  }
  elsif ($o{clear_url}) {
    $primary         = undef;
    $rebuild_sources = 1;
    $set->('source_url', undef);
  }

  if (exists $o{source_url}) {
    $primary         = _normalize_url($o{source_url});
    $rebuild_sources = 1;
    $set->('source_url', $primary);
  }

  if ($o{add_urls} && ref $o{add_urls} eq 'ARRAY') {
    for my $u ($o{add_urls}->@*) {
      my $nu = eval { _normalize_url($u) };
      next unless $nu;
      next if $primary && $nu eq $primary;
      unless (grep { $_ eq $nu } @extras) {
        push @extras, $nu;
        $rebuild_sources = 1;
      }
    }
  }

  if ($rebuild_sources) {
    @extras = grep { !$primary || $_ ne $primary } @extras;
    my @all;
    push @all, $primary if $primary;
    push @all, @extras;
    my %seen;
    @all = grep { defined && !$seen{$_}++ } @all;
    $set->('sources_json', @all ? JSON::PP->new->encode(\@all) : undef);
  }

  # Explicit metadata fields
  if (exists $o{source_site}) {
    my $v = text_for_db($o{source_site} // '');
    $v =~ s/^\s+|\s+\z//g if defined $v;
    $set->('source_site', (defined $v && length $v) ? $v : undef);
  }
  if (exists $o{source_id}) {
    my $v = text_for_db($o{source_id} // '');
    $v =~ s/^\s+|\s+\z//g if defined $v;
    $set->('source_id', (defined $v && length $v) ? $v : undef);
  }
  if (exists $o{design_model_id}) {
    my $v = text_for_db($o{design_model_id} // '');
    $v =~ s/^\s+|\s+\z//g if defined $v;
    $set->('design_model_id', (defined $v && length $v) ? $v : undef);
  }

  # Auto-fill empty site / ids from primary URL
  my $eff_url = exists $upd{source_url} ? $upd{source_url} : $row->{source_url};
  $eff_url = undef if defined $eff_url && !length $eff_url;
  my $auto = exists $o{auto_from_url} ? !!$o{auto_from_url} : (exists $o{source_url} ? 1 : 0);

  if ($auto && $eff_url) {
    my $cur_site = exists $upd{source_site} ? $upd{source_site} : $row->{source_site};
    my $cur_sid  = exists $upd{source_id}   ? $upd{source_id}   : $row->{source_id};
    my $cur_dmid = exists $upd{design_model_id} ? $upd{design_model_id} : $row->{design_model_id};

    if (my $mw = Meta::parse_makerworld_url($eff_url)) {
      if (exists $o{source_url} && $mw->{source_url}) {
        $set->('source_url', $mw->{source_url});
        $eff_url = $mw->{source_url};
      }
      $set->('source_site', $mw->{source_site})
        if (!defined $cur_site || !length $cur_site) && $mw->{source_site};
      $set->('source_id', $mw->{source_id})
        if (!defined $cur_sid || !length $cur_sid) && $mw->{source_id};
      $set->('design_model_id', $mw->{design_model_id})
        if (!defined $cur_dmid || !length $cur_dmid) && $mw->{design_model_id};
    }
    else {
      if (!defined $cur_site || !length $cur_site) {
        my $c = Meta::classify_site($eff_url) // '';
        $set->('source_site', $c) if $c && $c ne 'other';
      }
      if (!defined $cur_sid || !length $cur_sid) {
        my $id_from = Meta::_id_from_url($eff_url);
        $set->('source_id', $id_from) if $id_from;
      }
    }
  }

  if (!keys %upd && !$tags_changed) {
    return {
      id      => $id,
      name    => $row->{name},
      path    => $row->{path},
      changes => {},
      dryrun  => $o{dryrun} ? 1 : 0,
      noop    => 1,
    };
  }

  if ($o{dryrun}) {
    return {
      id      => $id,
      name    => $row->{name},
      path    => $row->{path},
      changes => \%changes,
      dryrun  => 1,
    };
  }

  DB::update_item_fields($id, \%upd) if keys %upd;
  return {
    id      => $id,
    name    => exists $upd{name} ? $upd{name} : $row->{name},
    path    => $row->{path},
    changes => \%changes,
    dryrun  => 0,
  };
}

sub _normalize_url {
  my ($u) = @_;
  return unless defined $u;
  $u = text_for_db($u);
  $u =~ s/^\s+|\s+\z//g;
  return unless length $u;
  $u = "https://$u" if $u !~ m{^https?://}i;
  die "edit: invalid URL (need http/https): $u\n" unless $u =~ m{^https?://}i;
  return $u;
}

sub _sources_list {
  my ($sources_json, $primary) = @_;
  my @extra;
  return @extra unless $sources_json;
  my $list = eval { JSON::PP->new->decode($sources_json) };
  return @extra unless ref $list eq 'ARRAY';
  my %seen;
  for my $u ($list->@*) {
    next unless defined $u && $u =~ /\S/;
    next if $primary && $u eq $primary;
    next if $seen{$u}++;
    push @extra, $u;
  }
  return @extra;
}

1;
