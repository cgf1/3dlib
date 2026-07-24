package Delete;
use v5.40;
use experimental qw(class refaliasing declared_refs);

use File::Path qw(remove_tree);
use Cwd qw(abs_path);
use LibConfig qw(library_root thumbs_dir);
use Util qw(dry_print text_for_db);
use DB ();

# Delete catalog item(s) by id or path.
# Default: remove DB rows, thumbnail, and on-disk files under the library root.
# --keep-files: catalog/thumb only.
sub delete_items {
  my (%o) = @_;
  my $targets    = $o{targets} // [];
  my $dryrun     = $o{dryrun} // 0;
  my $keep_files = $o{keep_files} // 0;
  my $root       = abs_path(library_root()) // library_root();

  die "delete: no targets\n" unless @$targets;

  my @results;
  for my $t (@$targets) {
    $t = text_for_db($t);
    my $row = DB::resolve_item_ref($t);
    die "Not in catalog: $t\n" unless $row;

    my \%it = $row;
    my $path = $it{path} // '';
    my $ap   = abs_path($path) // $path;
    $ap = text_for_db($ap);

    my $under_lib = _is_under($ap, $root);
    my @removed_files;

    if (!$keep_files) {
      if (!$under_lib) {
        die "Refusing to delete files outside library ($root): $ap\n"
          . "Use --keep-files to remove only the catalog entry.\n";
      }
      if ($dryrun) {
        dry_print(1, "would remove ", (-d $ap ? "dir " : "file "), $ap);
      }
      else {
        if (-d $ap) {
          remove_tree($ap);
          push @removed_files, $ap;
        }
        elsif (-e $ap) {
          unlink($ap) or warn "unlink $ap: $!\n";
          push @removed_files, $ap;
        }
        else {
          dry_print(0, "note: path already missing: $ap");
        }
      }
    }

    # Thumbnail
    my $thumb = $it{thumb_path};
    if (!$thumb || !length $thumb) {
      my $cand = thumbs_dir() . "/$it{id}.png";
      $thumb = $cand if -f $cand;
    }
    if ($thumb && -f $thumb) {
      if ($dryrun) {
        dry_print(1, "would remove thumb $thumb");
      }
      else {
        unlink($thumb) or warn "unlink thumb $thumb: $!\n";
      }
    }

    if ($dryrun) {
      dry_print(1, "would remove catalog #$it{id} $it{name} ($it{path})");
    }
    else {
      DB::delete_item($it{id});
      dry_print(0, "deleted #$it{id} $it{name}");
    }

    push @results, {
      id            => $it{id},
      name          => $it{name},
      path          => $it{path},
      removed_files => \@removed_files,
      keep_files    => $keep_files,
      dryrun        => $dryrun,
    };
  }
  return \@results;
}

sub _is_under ($path, $root) {
  return 0 unless defined $path && defined $root && length $path && length $root;
  $path =~ s{/\z}{};
  $root =~ s{/\z}{};
  return 1 if $path eq $root;
  return index($path, $root . '/') == 0;
}

1;
