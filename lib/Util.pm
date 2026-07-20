package Util;
use v5.40;
use experimental qw(class refaliasing declared_refs);
use Exporter qw(import);
use File::Basename qw(basename dirname fileparse);
use File::Copy qw(copy move);
use File::Path qw(make_path remove_tree);
use Digest::SHA qw(sha256_hex);
use Encode qw(decode encode FB_CROAK FB_DEFAULT);
use Time::Local qw(timegm);

our @EXPORT_OK = qw(
  now_ts slugify sanitize_filename human_size fmt_time
  file_hash file_stat_info ensure_unique_path
  is_non_ascii has_han look_like_project translate_name
  read_text write_text append_log
  path_ext classify_role
  safe_rename_or_move dry_print
  text_for_db fix_utf8_mojibake decode_argv
);

sub now_ts () { time }

sub dry_print ($dryrun, @msg) {
  my $prefix = $dryrun ? '[dryrun] ' : '';
  say $prefix, @msg;
}

# ---------------------------------------------------------------------------
# UTF-8 / filesystem name hygiene
#
# Linux paths are bytes (UTF-8 on this system).  If a byte string is handed to
# DBD::SQLite with sqlite_unicode, each byte can be treated as a Latin-1
# character and re-encoded → classic "æé¾" for "拉链".  Always run names
# through text_for_db() before storing or displaying.
# ---------------------------------------------------------------------------

sub decode_argv (@args) {
  return map { text_for_db($_) } @args;
}

# Normalize a string for Unicode-aware storage/display.
sub text_for_db ($s) {
  return undef unless defined $s;
  return $s if $s eq '';

  # Byte string from OS / ARGV → character string
  unless (utf8::is_utf8($s)) {
    my $decoded = eval { decode('UTF-8', $s, FB_CROAK) };
    $s = defined $decoded ? $decoded : decode('UTF-8', $s, FB_DEFAULT);
  }

  return fix_utf8_mojibake($s);
}

# Repair UTF-8 that was mis-decoded as Latin-1 (and optionally re-encoded).
# Example: characters U+00E6 U+008B U+0089… → 拉…
sub fix_utf8_mojibake ($s) {
  return $s unless defined $s && length $s;

  # Already has non-Latin1 codepoints that aren't the mojibake pattern alone —
  # still try if it looks like double-encoded UTF-8 (only U+0080..U+00FF + ASCII).
  my $only_latin1 = ($s !~ /[^\x00-\x{FF}]/);
  return $s unless $only_latin1;
  return $s unless $s =~ /[\x80-\x{FF}]/;

  my $bytes = eval { encode('iso-8859-1', $s, FB_CROAK) };
  return $s unless defined $bytes;

  my $fixed = eval { decode('UTF-8', $bytes, FB_CROAK) };
  return $s unless defined $fixed && length $fixed;

  # Accept repair when we gain real Unicode letters (CJK etc.) or the
  # result is shorter and looks like a plausible filename/text.
  if ($fixed =~ /\p{Han}|\p{Hiragana}|\p{Katakana}|\p{Hangul}|\p{Cyrillic}|\p{Arabic}/) {
    return $fixed;
  }
  if (length($fixed) < length($s)
      && $fixed =~ /^[\x09\x0A\x0D\x20-\x7E\p{L}\p{N}\p{P}\p{S}\s]+$/
      && $fixed !~ /\p{C}/) {
    return $fixed;
  }
  return $s;
}

sub human_size ($n = 0) {
  return sprintf('%.0f B', $n) if $n < 1024;
  return sprintf('%.1f KB', $n / 1024) if $n < 1024**2;
  return sprintf('%.1f MB', $n / 1024**2) if $n < 1024**3;
  return sprintf('%.2f GB', $n / 1024**3);
}

sub fmt_time ($ts) {
  return '(unknown)' unless $ts;
  my @t = localtime($ts);
  return sprintf('%04d-%02d-%02d %02d:%02d:%02d',
    $t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0]);
}

sub path_ext ($path) {
  my ($name, $dir, $ext) = fileparse($path, qr/\.[^.]*/);
  $ext =~ s/^\.//;
  return lc $ext;
}

sub file_stat_info {
  my ($path) = @_;
  my @s = stat($path) or return;
  return {
    size  => $s[7],
    atime => $s[8],
    mtime => $s[9],
    ctime => $s[10],
  };
}

sub file_hash {
  my ($path, $max) = @_;
  $max //= 50 * 1024 * 1024;    # hash first 50MB + size for huge files
  open my $fh, '<:raw', $path or return;
  my $sha = Digest::SHA->new(256);
  my $buf;
  my $total = 0;
  while (read($fh, $buf, 1024 * 1024)) {
    $sha->add($buf);
    $total += length($buf);
    last if $total >= $max;
  }
  close $fh;
  my $st = file_stat_info($path);
  if ($st && $st->{size} > $max) {
    $sha->add("size=$st->{size}");
  }
  return $sha->hexdigest;
}

sub slugify {
  my ($s) = @_;
  $s //= '';
  $s = decode('UTF-8', $s, Encode::FB_DEFAULT) unless utf8::is_utf8($s);
  # basic CJK placeholder: keep for translate_name
  $s =~ s/[^\w\s\-\.\(\)\[\]]+/_/g;
  $s =~ s/\s+/_/g;
  $s =~ s/_+/_/g;
  $s =~ s/^_+|_+$//g;
  $s = 'unnamed' if $s eq '';
  return $s;
}

sub sanitize_filename {
  my ($name) = @_;
  $name //= 'unnamed';
  $name =~ s/[\/\\:\0]//g;
  $name =~ s/[<>"|?*]/_/g;
  $name =~ s/\s+/ /g;
  $name =~ s/^\s+|\s+$//g;
  $name =~ s/\.+$//;
  $name = 'unnamed' if $name eq '' || $name eq '.' || $name eq '..';
  # limit length preserving extension
  if (length($name) > 180) {
    my ($base, $dir, $ext) = fileparse($name, qr/\.[^.]*/);
    $base = substr($base, 0, 160);
    $name = $base . $ext;
  }
  return $name;
}

sub ensure_unique_path {
  my ($dest) = @_;
  return $dest unless -e $dest;
  my ($name, $dir, $ext) = fileparse($dest, qr/\.[^.]*/);
  my $n = 2;
  while (1) {
    my $try = "$dir$name-$n$ext";
    return $try unless -e $try;
    $n++;
    die "Too many collisions for $dest\n" if $n > 9999;
  }
}

sub is_non_ascii ($s) {
  return $s =~ /[^\x00-\x7F]/;
}

sub has_han ($s) {
  return $s =~ /\p{Han}/;
}

# Simple Chinese token map for common filenames we saw; unknown Han → pinyin-ish stub
my %HAN_MAP = (
  '棉签发射器'           => 'cotton-swab-launcher',
  '鱼缸延长管'           => 'aquarium-extension-tube',
  '飞环'                 => 'flying-ring',
  '烟斗1'                => 'pipe-1',
  '组合体'               => 'assembly',
  '水妖精'               => 'water-fairy',
  '恐龙笔筒'             => 'dinosaur-pen-holder',
  '钻石剑'               => 'diamond-sword',
  '过滤箱MINI版本'       => 'filter-box-mini',
  '静音过滤箱打印文件'   => 'silent-filter-box',
  '洗碗池_洗手池下水回形管' => 'sink-p-trap-pipe',
  '火车笛'               => 'train-whistle',
  '无限8'                => 'infinity-8',
  '调整参数，提高打印效率' => 'tuned-print-efficiency',
  '坐立不安'             => 'restless',
  '单色'                 => 'single-color',
  '多色'                 => 'multi-color',
);

sub translate_name {
  my ($name) = @_;
  return $name unless has_han($name);
  my ($base, $d, $ext) = fileparse($name, qr/\.[^.]*/);
  for my $k (sort { length($b) <=> length($a) } keys %HAN_MAP) {
    $base =~ s/\Q$k\E/$HAN_MAP{$k}/g;
  }
  # remaining Han → hex stub
  $base =~ s/(\p{Han}+)/sprintf('zh-%s', unpack('H*', encode('UTF-8', $1)))/ge;
  return $base . $ext;
}

sub look_like_project {
  my ($dir) = @_;
  require LibConfig;
  return 0 unless -d $dir;
  my $has_model = 0;
  my $has_marker = 0;
  my $model_count = 0;
  opendir my $dh, $dir or return 0;
  my @entries = readdir($dh);
  closedir $dh;
  for my $e (@entries) {
    next if $e eq '.' || $e eq '..';
    my $p = "$dir/$e";
    if (-f $p) {
      my $el = lc $e;
      $has_marker = 1 if $el eq 'url' || $el eq 'readme.txt' || $el eq 'readme.md'
        || $el eq 'license.txt' || $el eq 'license';
      my $ext = path_ext($p);
      if (LibConfig::is_model_ext($ext)) {
        $has_model = 1;
        $model_count++;
      }
    }
    if (-d $p && ($e eq 'files' || $e eq 'images' || $e eq 'Files' || $e eq 'Images')) {
      $has_marker = 1;
      # count models in files/
      if (lc($e) eq 'files' && opendir my $fd, $p) {
        while (my $f = readdir($fd)) {
          next if $f =~ /^\./;
          $model_count++ if LibConfig::is_model_ext(path_ext("$p/$f"));
          $has_model = 1 if LibConfig::is_model_ext(path_ext("$p/$f"));
        }
        closedir $fd;
      }
    }
  }
  return 1 if $has_marker && $has_model;
  return 1 if $model_count >= 2;
  return 0;
}

sub classify_role {
  my ($path, $rel) = @_;
  my $base = lc basename($path);
  my $ext  = path_ext($path);
  return 'url'     if $base eq 'url' || $base eq 'url.txt';
  return 'readme'  if $base =~ /^readme/;
  return 'license' if $base =~ /^license/;
  return 'image'   if $ext =~ /^(png|jpe?g|gif|webp|bmp)$/;
  return 'gcode'   if $ext eq 'gcode';
  return 'backup'  if $ext eq 'fcbak' || $path =~ /\.FCStd1$/i;
  return 'source'  if $ext =~ /^(fcstd|step|stp|f3d|scad)$/;
  return 'model'   if LibConfig::is_model_ext($ext);
  return 'other';
}

sub read_text {
  my ($path) = @_;
  open my $fh, '<:raw', $path or return;
  local $/;
  my $raw = <$fh>;
  close $fh;
  return unless defined $raw;
  my $t = eval { decode('UTF-8', $raw, FB_CROAK) };
  $t = decode('UTF-8', $raw, Encode::FB_DEFAULT) unless defined $t;
  return $t;
}

sub write_text {
  my ($path, $text) = @_;
  make_path(dirname($path));
  open my $fh, '>:encoding(UTF-8)', $path or die "write $path: $!\n";
  print {$fh} $text;
  close $fh;
}

sub append_log {
  my ($path, $line) = @_;
  make_path(dirname($path));
  open my $fh, '>>:encoding(UTF-8)', $path or return;
  say {$fh} $line;
  close $fh;
}

sub safe_rename_or_move {
  my (%o) = @_;
  my $src    = $o{src};
  my $dest   = $o{dest};
  my $copy   = $o{copy} // 0;
  my $dryrun = $o{dryrun} // 0;

  $dest = ensure_unique_path($dest) if -e $dest && !$dryrun;
  if ($dryrun) {
    dry_print(1, ($copy ? 'copy' : 'move'), " $src -> $dest");
    return $dest;
  }
  make_path(dirname($dest));
  if ($copy) {
    copy($src, $dest) or die "copy $src -> $dest: $!\n";
  }
  else {
    # try rename first (same fs), else copy+unlink
    if (!rename($src, $dest)) {
      copy($src, $dest) or die "move-copy $src -> $dest: $!\n";
      unlink($src) or warn "Could not remove source $src: $!\n";
    }
  }
  return $dest;
}

1;
