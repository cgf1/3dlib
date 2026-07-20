package Item;
use v5.40;
use experimental qw(class refaliasing declared_refs);

use DB ();
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

  method openable_path () {
    return $path if $kind eq 'file' && -f $path;
    for my $f ($self->files->@*) {
      my \%file = $f;
      return $file{path} if ($file{ext} // '') eq '3mf' && -f $file{path};
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
    say {$fh} "id:              $id";
    say {$fh} "name:            $name";
    say {$fh} "name_orig:       ", $name_orig // '';
    say {$fh} "kind/type:       $kind / $type";
    say {$fh} "path:            $path";
    say {$fh} "status:          ", $status // '';
    say {$fh} "source_site:     ", $source_site // '';
    say {$fh} "source_url:      ", $source_url // '';
    say {$fh} "design_model_id: ", $design_model_id // '';
    say {$fh} "mtime:           ", fmt_time($mtime);
    say {$fh} "size:            ", human_size($size_bytes);
    say {$fh} "files:           ", $file_count // 0;
    say {$fh} "thumb:           ", $thumb_path // '';
    say {$fh} "hash:            ", $content_hash // '';
    say {$fh} "--- description ---";
    say {$fh} $description // '';
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

1;
