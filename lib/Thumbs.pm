package Thumbs;
use v5.40;
use experimental qw(class refaliasing declared_refs);
use File::Basename qw(basename dirname);
use File::Copy qw(copy);
use File::Path qw(make_path);
use File::Find qw(find);
use LibConfig qw(thumbs_dir library_root);
use DB ();
use Meta ();
use Util qw(path_ext);

sub ensure_item_thumb ($item_id) {
  my $row = DB::get_item($item_id) or return;
  my \%item = $row;
  return $item{thumb_path} if $item{thumb_path} && -f $item{thumb_path};

  my $tdir = thumbs_dir();
  make_path($tdir);
  my $out = "$tdir/$item_id.png";

  if ($item{kind} eq 'project') {
    # prefer images/ in project
    my $img = _find_project_image($item{path});
    if ($img) {
      _normalize_image($img, $out);
    }
  }

  unless (-f $out && -s $out) {
    # try primary 3mf
    my $files = DB::item_files($item_id);
    for my $f ($files->@*) {
      my \%file = $f;
      next unless ($file{ext} // '') eq '3mf' || ($file{path} // '') =~ /\.3mf$/i;
      if (Meta::extract_3mf_thumb_to($file{path}, $out)) {
        last;
      }
    }
    if ((!-f $out || !-s $out) && $item{path} =~ /\.3mf$/i) {
      Meta::extract_3mf_thumb_to($item{path}, $out);
    }
  }

  if (-f $out && -s $out) {
    DB::dbh()->do('UPDATE items SET thumb_path = ?, updated_at = ? WHERE id = ?',
      undef, $out, time, $item_id);
    return $out;
  }
  return;
}

sub generate_missing {
  my (%o) = @_;
  my $items = DB::list_items(no_thumb => 1, limit => $o{limit} // 5000);
  my $n = 0;
  for my $row ($items->@*) {
    my \%it = $row;
    my $t = ensure_item_thumb($it{id});
    $n++ if $t;
    say "thumb #$it{id}: ", ($t // 'none') if $o{verbose};
  }
  return $n;
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
