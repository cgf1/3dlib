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

  if ($m{design_model_id}) {
    $m{source_site} = 'makerworld';
    $m{source_url}  = 'https://makerworld.com/en/models/' . $m{design_model_id};
    $m{source_id}   = $m{design_model_id};
  }
  return \%m;
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
  # unique preserve order
  my %seen;
  @urls = grep { !$seen{$_}++ } @urls;
  my $primary = $urls[0];
  return {
    urls        => \@urls,
    source_url  => $primary,
    source_site => $primary ? classify_site($primary) : undef,
    source_id   => _id_from_url($primary),
    sources_json => @urls ? _json_array(@urls) : undef,
  };
}

sub _id_from_url {
  my ($url) = @_;
  return unless $url;
  return $1 if $url =~ /thingiverse\.com\/thing:(\d+)/i;
  return $1 if $url =~ /printables\.com\/model\/(\d+)/i;
  return $1 if $url =~ /makerworld\.com\/(?:en|zh)\/models\/([A-Za-z0-9_-]+)/i;
  return $1 if $url =~ /cults3d\.com\/[^\/]+\/3d-model\/([^\/\?]+)/i;
  return;
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
  if ($url =~ m{makerworld\.com/(?:en|zh)/models/([A-Za-z0-9_-]+)}i) {
    return {
      design_model_id => $1,
      source_url      => "https://makerworld.com/en/models/$1",
      source_site     => 'makerworld',
      source_id       => $1,
    };
  }
  return;
}

sub parse_bambustudio_scheme {
  my ($url) = @_;
  return unless $url && $url =~ m{^bambustudio:}i;
  my %out = (scheme => 'bambustudio', raw => $url);
  # Common patterns:
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

1;
