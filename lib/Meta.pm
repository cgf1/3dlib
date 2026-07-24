package Meta;
use v5.40;
use experimental qw(class refaliasing declared_refs);
use Encode ();
use File::Basename qw(basename fileparse);
use Archive::Zip qw(:ERROR_CODES);
use Util qw(read_text path_ext has_han);
use LibConfig ();

# Parse Bambu cloud download filename
# UUID.3mf_at=...&name=Title.3mf
sub parse_bambu_filename {
  my ($path) = @_;
  my $base = basename($path);
  my %out;

  if ($base =~ /^([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.3mf_at=/i) {
    $out{download_uuid} = $1;
    if ($base =~ /[?&]name=([^&]+)/ || $base =~ /name=([^&]+)$/) {
      my $n = $1;
      $n =~ s/\+/ /g;
      $n =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/ge;
      $out{name} = $n;
    }
    if ($base =~ /\.download(\.\d+)?$/i || $base =~ /\.(\d+)\.download$/i) {
      $out{incomplete} = 1;
    }
  }
  # incomplete: name.3mf.12345.download
  if ($base =~ /\.download$/i) {
    $out{incomplete} = 1;
  }
  return %out ? \%out : undef;
}

sub clean_display_name {
  my ($path) = @_;
  my $base = basename($path);
  my $bambu = parse_bambu_filename($path);
  if ($bambu && $bambu->{name}) {
    $base = $bambu->{name};
  }
  $base = Util::translate_name($base);
  # strip trailing .download junk
  $base =~ s/\.\d+\.download$//i;
  $base =~ s/\.download$//i;
  return Util::sanitize_filename($base);
}

# Extract metadata from 3MF (zip)
sub extract_3mf_meta {
  my ($path) = @_;
  my %m;
  return \%m unless -f $path && $path =~ /\.3mf$/i;

  my $zip = Archive::Zip->new();
  return \%m unless $zip->read($path) == AZ_OK;

  # Prefer 3D/3dmodel.model metadata
  my $member = $zip->memberNamed('3D/3dmodel.model')
    || $zip->memberNamed('3d/3dmodel.model');
  if ($member) {
    my $xml = $member->contents();
    $xml = Encode::decode('UTF-8', $xml, Encode::FB_DEFAULT) if defined $xml;
    while ($xml =~ /<metadata\s+name="([^"]+)"\s*>(.*?)<\/metadata>/gis) {
      my ($k, $v) = ($1, $2);
      $m{meta}{$k} = _decode_entities($v);
    }
    $m{design_model_id} = $m{meta}{DesignModelId} if $m{meta}{DesignModelId};
    $m{design_profile_id} = $m{meta}{DesignProfileId} if $m{meta}{DesignProfileId};
    $m{title}    = $m{meta}{Title}    if $m{meta}{Title};
    $m{designer} = $m{meta}{Designer} if $m{meta}{Designer};
    $m{license}  = $m{meta}{License}  if $m{meta}{License};
    # Prefer model Description; strip MakerWorld chrome / HTML to plain text
    $m{description} = html_to_text(
      $m{meta}{Description} // $m{meta}{ProfileDescription} // ''
    );

    # Public MakerWorld URLs use a numeric id, not DesignModelId (US…).
    # CDN / HTML embeds: makerworld/model/DSM00000002755057/... → 2755057
    if ($xml =~ /\b(DSM0*\d+)\b/i) {
      $m{dsm_id} = $1;
      $m{numeric_id} = dsm_to_numeric($1);
    }
  }

  # Thumbnail paths inside zip
  for my $cand (
    'Auxiliaries/.thumbnails/thumbnail_middle.png',
    'Auxiliaries/.thumbnails/thumbnail_3mf.png',
    'Auxiliaries/.thumbnails/thumbnail_small.png',
    'Metadata/plate_1.png',
    'Metadata/plate_1_small.png',
  ) {
    if ($zip->memberNamed($cand)) {
      push @{ $m{thumb_members} }, $cand;
    }
  }

  if ($m{design_model_id} || $m{numeric_id}) {
    $m{source_site} = 'makerworld';
    $m{source_url}  = makerworld_public_url(
      numeric_id      => $m{numeric_id},
      title           => $m{title},
      design_model_id => $m{design_model_id},
    );
    # Prefer numeric public id for display; keep DesignModelId separately
    $m{source_id} = $m{numeric_id} // $m{design_model_id};
  }
  return \%m;
}

# DSM00000002755057 → 2755057
sub dsm_to_numeric ($dsm) {
  return unless defined $dsm && $dsm =~ /^DSM0*([1-9]\d*)$/i;
  return $1;
}

sub title_to_slug ($title) {
  return unless defined $title && length $title;
  my $s = lc $title;
  $s =~ s/[^a-z0-9]+/-/g;
  $s =~ s/^-+|-+$//g;
  return length($s) ? $s : undef;
}

# Public model page, e.g. https://makerworld.com/en/models/2755057
# (slug suffix is optional on MakerWorld; numeric id alone is enough and more stable)
# DesignModelId-only (US…) is a last-resort fallback.
sub makerworld_public_url {
  my (%o) = @_;
  my $num = $o{numeric_id};
  return "https://makerworld.com/en/models/${num}" if $num;
  return unless $o{design_model_id};
  return 'https://makerworld.com/en/models/' . $o{design_model_id};
}

# Normalize a source URL for catalog storage.
# - MakerWorld page URLs → stable https://makerworld.com/en/models/<id>
# - CDN embeds (makerworld.bblmw.com/.../model/DSM… or US…) → public page
# - Other sites left as-is (trimmed, https:// if scheme missing)
sub canonicalize_source_url {
  my ($url) = @_;
  return unless defined $url;
  $url =~ s/^\s+|\s+\z//g;
  return unless length $url;
  $url = "https://$url" if $url !~ m{^[a-z][a-z0-9+.-]*:}i;

  # Already a MakerWorld model page?
  if (my $mw = parse_makerworld_url($url)) {
    return $mw->{source_url} if $mw->{source_url};
  }

  # CDN / asset hosts: .../makerworld/model/DSM00000002755057/... or .../model/USxxxx/...
  if ($url =~ m{(?:bblmw\.com|makerworld\.com|bambulab\.com)}i) {
    if ($url =~ m{/model/(DSM0*\d+)}i) {
      my $num = dsm_to_numeric($1);
      return makerworld_public_url(numeric_id => $num) if $num;
    }
    if ($url =~ m{/model/(US[A-Za-z0-9]+)}i) {
      return makerworld_public_url(design_model_id => $1);
    }
    # Bare DSM id anywhere in the URL
    if ($url =~ m{\b(DSM0*\d+)\b}i) {
      my $num = dsm_to_numeric($1);
      return makerworld_public_url(numeric_id => $num) if $num;
    }
  }

  return $url;
}

sub extract_3mf_thumb_to {
  my ($path, $outfile) = @_;
  my $zip = Archive::Zip->new();
  return 0 unless $zip->read($path) == AZ_OK;
  for my $cand (
    'Auxiliaries/.thumbnails/thumbnail_middle.png',
    'Auxiliaries/.thumbnails/thumbnail_3mf.png',
    'Metadata/plate_1.png',
    'Auxiliaries/.thumbnails/thumbnail_small.png',
    'Metadata/plate_1_small.png',
  ) {
    my $m = $zip->memberNamed($cand);
    next unless $m;
    return 1 if $m->extractToFileNamed($outfile) == AZ_OK;
  }
  # fall back to system thumbnailer
  if (-x '/usr/local/bin/3mf-thumbnailer') {
    system('/usr/local/bin/3mf-thumbnailer', $path, $outfile);
    return -f $outfile && -s $outfile;
  }
  return 0;
}

# Decode HTML entities, including double-encoded MakerWorld forms (&amp;#34; → ").
sub _decode_entities ($s) {
  return '' unless defined $s;
  for (1 .. 6) {
    my $prev = $s;
    $s =~ s/&nbsp;/ /gi;
    $s =~ s/&amp;/&/g;
    $s =~ s/&lt;/</g;
    $s =~ s/&gt;/>/g;
    $s =~ s/&quot;/"/g;
    $s =~ s/&apos;/'/g;
    $s =~ s/&#0*34;/"/g;
    $s =~ s/&#0*39;/'/g;
    $s =~ s/&#x0*22;/"/gi;
    $s =~ s/&#x0*27;/'/gi;
    $s =~ s/&#(\d+);/chr($1)/ge;
    $s =~ s/&#x([0-9a-fA-F]+);/chr(hex($1))/ge;
    last if $s eq $prev;
  }
  return $s;
}

# MakerWorld 3MF descriptions are HTML (often with nested &amp; entities) plus
# commercial/membership chrome we don't want in a plain-text catalog summary.
sub html_to_text ($s) {
  return '' unless defined $s && length $s;

  # Drop membership / commercial banners (source of "Membership Primary Commercial License")
  $s =~ s{<commercialme\b[^>]*>.*?</commercialme>}{}gis;
  $s =~ s{<commercial\w*\b[^>]*>.*?</commercial\w*>}{}gis;

  # Drop non-text chrome
  $s =~ s{<script\b[^>]*>.*?</script>}{}gis;
  $s =~ s{<style\b[^>]*>.*?</style>}{}gis;
  $s =~ s{<figure\b[^>]*>.*?</figure>}{}gis;
  $s =~ s{<img\b[^>]*/?>}{}gi;

  # Block boundaries → spaces/newlines before tag strip
  $s =~ s{<br\s*/?>}{ }gi;
  $s =~ s{</p>}{ }gi;
  $s =~ s{</h[1-6]>}{ }gi;
  $s =~ s{</li>}{ }gi;
  $s =~ s{<li\b[^>]*>}{- }gi;

  $s =~ s/<[^>]+>/ /g;
  $s = _decode_entities($s);

  # Collapse whitespace
  $s =~ s/[\r\n\t]+/ /g;
  $s =~ s/ +/ /g;
  $s =~ s/^\s+|\s+$//g;

  # Truncate for catalog summary
  return length($s) > 800 ? substr($s, 0, 797) . '...' : $s;
}

# Back-compat alias
sub _strip_html { goto &html_to_text }

sub harvest_urls_from_text {
  my ($text) = @_;
  return () unless $text;
  my @urls = $text =~ m{(https?://[^\s<>"'\)]+)}g;
  s/[.,;:]+$// for @urls;
  return @urls;
}

sub classify_site {
  my ($url) = @_;
  return 'makerworld'  if $url =~ /makerworld\.com|bambulab\.com/i;
  return 'thingiverse' if $url =~ /thingiverse\.com/i;
  return 'printables'  if $url =~ /printables\.com/i;
  return 'thangs'      if $url =~ /thangs\.com/i;
  return 'cults'       if $url =~ /cults3d\.com/i;
  return 'mymini'      if $url =~ /myminifactory\.com/i;
  return 'other';
}

sub harvest_project_sources {
  my ($dir) = @_;
  my @urls;
  my @files = (
    map { "$dir/$_" } qw(URL url URL.txt url.txt),
    glob("$dir/README*"),
    glob("$dir/readme*"),
  );
  for my $f (@files) {
    next unless -f $f;
    my $t = read_text($f);
    push @urls, harvest_urls_from_text($t) if $t;
  }
  # Canonicalize + unique preserve order
  my %seen;
  my @canon;
  for my $u (@urls) {
    my $c = canonicalize_source_url($u) // $u;
    next unless defined $c && length $c;
    next if $seen{$c}++;
    push @canon, $c;
  }
  my $primary = $canon[0];
  return {
    urls         => \@canon,
    source_url   => $primary,
    source_site  => $primary ? classify_site($primary) : undef,
    source_id    => ($primary ? _id_from_url($primary) : undef),
    sources_json => (@canon ? _json_array(@canon) : undef),
  };
}

# Merge an explicit --source-url (or handler URL) over harvested sources.
# Preferential primary; append harvested URLs as extras.
sub merge_source_url {
  my ($src, $url) = @_;
  $src = {} unless ref $src eq 'HASH';
  return $src unless defined $url && length $url;
  my $primary = canonicalize_source_url($url) // $url;
  $primary =~ s/^\s+|\s+\z//g;
  return $src unless length $primary;

  my @urls = ($primary);
  my %seen = ($primary => 1);
  for my $u (@{ $src->{urls} // [] }) {
    next unless defined $u && length $u;
    my $c = canonicalize_source_url($u) // $u;
    next if $seen{$c}++;
    push @urls, $c;
  }
  if ($src->{source_url}) {
    my $c = canonicalize_source_url($src->{source_url}) // $src->{source_url};
    unless ($seen{$c}++) {
      push @urls, $c;
    }
  }
  return {
    urls         => \@urls,
    source_url   => $primary,
    source_site  => classify_site($primary) // undef,
    source_id    => (_id_from_url($primary) // undef),
    sources_json => (_json_array(@urls) // undef),
  };
}

sub _id_from_url {
  my ($url) = @_;
  return undef unless $url;
  return $1 if $url =~ /thingiverse\.com\/thing:(\d+)/i;
  return $1 if $url =~ /printables\.com\/model\/(\d+)/i;
  return $1 if $url =~ /makerworld\.com\/(?:en|zh)\/models\/([A-Za-z0-9_-]+)/i;
  return $1 if $url =~ /cults3d\.com\/[^\/]+\/3d-model\/([^\/\?]+)/i;
  return undef;
}

sub _json_array {
  require JSON::PP;
  return JSON::PP->new->utf8->encode([@_]);
}

sub build_description {
  my (%o) = @_;
  my @parts;
  push @parts, $o{summary} if $o{summary};
  push @parts, "Designer: $o{designer}" if $o{designer};
  push @parts, "License: $o{license}"   if $o{license};
  push @parts, "Source: $o{source_url}" if $o{source_url};
  push @parts, 'Last modified: ' . Util::fmt_time($o{mtime}) if $o{mtime};
  # atime intentionally omitted — many filesystems mount with noatime/relatime
  return join("\n", @parts);
}

sub parse_makerworld_url {
  my ($url) = @_;
  return unless $url;
  # Numeric (+ optional slug): /models/2755057-flexi-zipper-fidget-toy
  if ($url =~ m{makerworld\.com/(?:en|zh)/models/(\d+)(?:-([A-Za-z0-9_-]+))?}i) {
    my ($num, $slug) = ($1, $2);
    return {
      numeric_id  => $num,
      slug        => $slug,
      source_url  => makerworld_public_url(numeric_id => $num, slug => $slug),
      source_site => 'makerworld',
      source_id   => $num,
    };
  }
  # DesignModelId form (legacy / deep links): /models/USxxxxxxxx
  if ($url =~ m{makerworld\.com/(?:en|zh)/models/(US[A-Za-z0-9]+)}i) {
    return {
      design_model_id => $1,
      source_url      => makerworld_public_url(design_model_id => $1),
      source_site     => 'makerworld',
      source_id       => $1,
    };
  }
  return;
}

sub parse_bambustudio_scheme {
  my ($url) = @_;
  return unless $url && $url =~ m{^bambustudio:}i;
  my %out = (scheme => 'bambustudio', app => 'studio', raw => $url);
  # Catalog item (preferred for web UI):
  #   bambustudio://library/42
  #   bambustudio://open?id=42
  #   bambustudio://item/42
  if ($url =~ m{bambustudio://(?:library|item)/(\d+)}i) {
    $out{item_id} = $1;
    return \%out;
  }
  if ($url =~ m{[?&]id=(\d+)}) {
    $out{item_id} = $1;
  }
  # Common MakerWorld / Studio patterns:
  # bambustudio://open/?file=/path
  # bambustudio://open/https://...
  # bambustudio://open?file=...
  if ($url =~ m{file=([^&]+)}) {
    my $f = $1;
    $f =~ s/\+/ /g;
    $f =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/ge;
    $out{file} = $f;
  }
  if ($url =~ m{bambustudio://open/?(https?://\S+)}i) {
    $out{http_url} = $1;
    $out{http_url} =~ s/[&\s].*//;
  }
  if ($url =~ m{(https?://[^\s\"']+)}) {
    $out{http_url} //= $1;
  }
  return \%out;
}

# freecad://library/42
# freecad://open?id=42
# freecad://open/?file=/path/to/model.FCStd
sub parse_freecad_scheme {
  my ($url) = @_;
  return unless $url && $url =~ m{^freecad:}i;
  my %out = (scheme => 'freecad', app => 'freecad', raw => $url);
  if ($url =~ m{freecad://(?:library|item|open)/(\d+)}i) {
    $out{item_id} = $1;
    return \%out;
  }
  if ($url =~ m{[?&]id=(\d+)}) {
    $out{item_id} = $1;
  }
  if ($url =~ m{file=([^&]+)}) {
    my $f = $1;
    $f =~ s/\+/ /g;
    $f =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/ge;
    $out{file} = $f;
  }
  # freecad://open//share/3d/...  (rare)
  if (!$out{file} && $url =~ m{freecad://open(/[^\s?#]+)}i) {
    $out{file} = $1;
  }
  return \%out;
}

# Unified scheme (optional): 3dlib://studio/42  3dlib://freecad/42
sub parse_3dlib_scheme {
  my ($url) = @_;
  return unless $url && $url =~ m{^3dlib:}i;
  my %out = (scheme => '3dlib', raw => $url);
  if ($url =~ m{3dlib://(studio|bambu|bambustudio|freecad|fcstd)/(\d+)}i) {
    my ($app, $id) = (lc $1, $2);
    $app = 'studio'  if $app =~ /^(bambu|bambustudio)\z/;
    $app = 'freecad' if $app eq 'fcstd';
    $out{app}     = $app;
    $out{item_id} = $id;
    return \%out;
  }
  if ($url =~ m{3dlib://open/(studio|freecad)/(\d+)}i) {
    $out{app}     = lc $1;
    $out{item_id} = $2;
    return \%out;
  }
  return \%out;
}

# Build library deep links for the web UI / clipboard.
sub library_open_url {
  my (%o) = @_;
  my $id  = $o{id} // die "library_open_url: id required\n";
  my $app = lc($o{app} // 'studio');
  return "freecad://library/$id" if $app eq 'freecad' || $app eq 'fcstd' || $app eq 'fc';
  return "bambustudio://library/$id";
}

1;
