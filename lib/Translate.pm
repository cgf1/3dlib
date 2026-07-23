package Translate;
use v5.40;
use experimental qw(class refaliasing declared_refs);
use utf8;
use HTTP::Tiny;
use JSON::PP;
use LibConfig ();
use Util qw(has_han dry_print text_for_db);
use DB ();

# OpenAI-compatible chat completions (OpenAI, xAI Grok, etc.)
# Detects non-English catalog text (CJK, Latin-with-diacritics, other scripts,
# and common DE/FR/IT/ES/… function words even in pure ASCII) and translates
# to English. Original text is kept in description_orig.

sub config {
  my $cfg = LibConfig::load_config();
  my $t   = $cfg->{translate} // {};
  $t = {} unless ref $t eq 'HASH';

  my $provider = lc($t->{provider} // _default_provider());
  my %defaults = (
    openai => {
      base_url    => 'https://api.openai.com/v1',
      model       => 'gpt-4o-mini',
      api_key_env => 'OPENAI_API_KEY',
    },
    xai => {
      base_url    => 'https://api.x.ai/v1',
      model       => 'grok-3-mini',
      api_key_env => 'XAI_API_KEY',
    },
    grok => {    # alias for xai
      base_url    => 'https://api.x.ai/v1',
      model       => 'grok-3-mini',
      api_key_env => 'XAI_API_KEY',
    },
  );
  $provider = 'xai' if $provider eq 'grok';
  my $d = $defaults{$provider} // $defaults{openai};

  # detect: auto (default) | cjk | non_english
  my $detect = lc($t->{detect} // 'auto');
  $detect = 'auto' unless $detect =~ /^(auto|cjk|non_english|non-english)\z/;
  $detect = 'auto' if $detect eq 'non-english';

  return {
    enabled     => exists $t->{enabled} ? !!$t->{enabled} : 1,
    provider    => $provider,
    base_url    => $t->{base_url} // $d->{base_url},
    model       => $t->{model} // $d->{model},
    api_key_env => $t->{api_key_env} // $d->{api_key_env},
    api_key     => $t->{api_key},    # optional inline (prefer env)
    timeout     => $t->{timeout} // 120,
    auto_import => exists $t->{auto_import} ? !!$t->{auto_import} : 1,
    detect      => $detect eq 'non_english' ? 'auto' : $detect,
  };
}

sub _default_provider {
  return 'openai' if $ENV{OPENAI_API_KEY};
  return 'xai'    if $ENV{XAI_API_KEY} || $ENV{GROK_API_KEY};
  return 'openai';
}

sub api_key {
  my ($c) = @_;
  $c //= config();
  return $c->{api_key} if defined $c->{api_key} && length $c->{api_key};
  my $env = $c->{api_key_env} // 'OPENAI_API_KEY';
  return $ENV{$env} // $ENV{GROK_API_KEY} // $ENV{XAI_API_KEY} // $ENV{OPENAI_API_KEY};
}

# ---------------------------------------------------------------------------
# Language detection (cheap heuristics — no API call)
# ---------------------------------------------------------------------------

# Strong non-English signal: scripts other than Latin, or Latin with diacritics.
sub has_non_latin_or_diacritics {
  my ($s) = @_;
  return 0 unless defined $s && length $s;
  return 1 if has_han($s);
  return 1 if $s =~ /\p{Script=Hiragana}|\p{Script=Katakana}|\p{Script=Hangul}/;
  return 1 if $s =~ /\p{Script=Cyrillic}|\p{Script=Greek}|\p{Script=Arabic}|\p{Script=Hebrew}/;
  return 1 if $s =~ /\p{Script=Thai}|\p{Script=Devanagari}/;
  # Latin Extended (äöüßàéèñç…), including German ß
  return 1 if $s =~ /[\x{00C0}-\x{024F}\x{1E00}-\x{1EFF}]/;
  return 0;
}

# Common function words. Used only when text is pure ASCII so we still catch
# German/French/etc. without umlauts.
my %EN_WORDS = map { $_ => 1 } qw(
  the and for with from this that are was were have has not can will which
  when what where how your you its into over under onto about after before
  between through during without within print model parts piece easy simple
  required requires using used use size mm cm file license source designer
  last modified description assembly support supports
);

my %OTHER_WORDS = map { $_ => 1 } (
  # German
  qw(
    der die das und für fur mit zum zur eine einer eines einem einen nicht
    oder sowie wird wurde werden sind auch bei von den dem des ein ist
    dieser diese dieses speziell entwickelt einfache einfacher sichere
    sicherer verbindung armbänder armbander verschluss klickverschluss
    universell universelle um zu einer als auf im in am nach noch nur
    kann können konnen wird wurden wurden hat haben man sie wir
    paracord klick drehen verschieben werkzeug
  ),
  # French
  qw(
    les des une pour avec dans est sont cette ces qui que sur par plus
    sans sont aussi comme tout toute tous dans
  ),
  # Italian
  qw(
    per con della delle degli questo questa questi queste sono della
    una uno degli alla allo degli
  ),
  # Spanish
  qw(
    para con una del los las este esta estos estas son por sin como
    más mas también tambien
  ),
  # Dutch
  qw(
    het een van voor met niet of ook naar bij zijn deze dit
  ),
  # Portuguese
  qw(
    para com uma dos das este esta são sao por sem como mais
  ),
);

sub _word_lang_scores {
  my ($s) = @_;
  my ($en, $other) = (0, 0);
  # Strip catalog boilerplate lines that are already English labels
  my $body = $s;
  $body =~ s{^(Designer|License|Source|Last modified|DesignModelId)\s*:.*$}{}gmi;
  for my $w ($body =~ /\b([A-Za-z]{2,})\b/g) {
    my $lw = lc $w;
    $en++    if $EN_WORDS{$lw};
    $other++ if $OTHER_WORDS{$lw};
  }
  return ($en, $other);
}

# True if catalog text should be sent through the translation API.
sub needs_translation {
  my ($text, %o) = @_;
  return 0 unless defined $text && $text =~ /\S/;
  $text = text_for_db($text);

  my $mode = $o{detect} // eval { config()->{detect} } // 'auto';
  $mode = 'auto' if $mode eq 'non_english';

  if ($mode eq 'cjk') {
    return has_han($text) ? 1 : 0;
  }

  # auto / non_english
  return 1 if has_non_latin_or_diacritics($text);

  # Pure ASCII: function-word heuristic (German without umlauts, etc.)
  my ($en, $other) = _word_lang_scores($text);
  return 1 if $other >= 3 && $other > $en;
  return 1 if $other >= 2 && $en == 0 && length($text) > 40;
  return 1 if $other >= 2 && $other >= $en + 2;
  return 0;
}

sub translate_text {
  my ($text, %o) = @_;
  $text = text_for_db($text) // '';
  my $c = $o{config} // config();
  my $kind = $o{kind} // 'description';    # description | name
  return $text unless needs_translation($text, detect => $c->{detect});

  die "Translation disabled in config\n" unless $c->{enabled};

  my $key = api_key($c);
  die "No API key (set $c->{api_key_env} or OPENAI_API_KEY / XAI_API_KEY)\n"
    unless $key && length $key;

  my $base = $c->{base_url} // 'https://api.openai.com/v1';
  $base =~ s{/$}{};
  my $url = "$base/chat/completions";

  my $system = $kind eq 'name'
    ? join(
      ' ',
      'You translate 3D model display names into concise clear English.',
      'The source may be Chinese, German, French, or any other language.',
      'Keep product/model codes, sizes (e.g. 5cm), and file extensions (.3mf .stl) unchanged.',
      'Prefer short natural English suitable as a catalog title; use spaces or hyphens, not long sentences.',
      'If already English, return it unchanged.',
      'Output only the translated name, no quotes or preamble.',
      )
    : join(
      ' ',
      'You translate 3D-printing model catalog text into clear English.',
      'The source may be Chinese, German, French, Italian, Spanish, or any other language.',
      'Preserve technical meaning, sizes, materials, part names that are already English, and structure.',
      'Keep Designer/License/Source/Last modified lines intact if present;',
      'translate only the human description parts that are not English.',
      'If the text is already English, return it unchanged.',
      'Output only the translated catalog text, no preamble or quotes.',
      );

  my $body = {
    model       => $c->{model},
    temperature => 0.2,
    messages    => [
      { role => 'system', content => $system },
      { role => 'user',   content => $text },
    ],
  };

  my $http = HTTP::Tiny->new(timeout => $c->{timeout} // 120);
  my $res  = $http->post(
    $url,
    {
      headers => {
        'Content-Type'  => 'application/json',
        'Authorization' => "Bearer $key",
      },
      content => _json_encode($body),
    }
  );

  unless ($res->{success}) {
    my $detail = $res->{content} // '';
    $detail = substr($detail, 0, 400);
    die "Translate API error $res->{status}: $detail\n";
  }

  my $data = eval { _json_decode($res->{content}) };
  die "Translate API: invalid JSON\n" unless $data && ref $data eq 'HASH';
  my $out = $data->{choices}[0]{message}{content} // '';
  $out =~ s/^\s+|\s+$//g;
  die "Translate API: empty response\n" unless length $out;
  return text_for_db($out);
}

sub _json_encode {
  return JSON::PP->new->utf8->encode($_[0]);
}

sub _json_decode {
  return JSON::PP->new->utf8->decode($_[0]);
}

# Pick source text for a field: current if non-English, else orig if non-English.
sub _field_source {
  my ($current, $orig, $detect, $force) = @_;
  $current //= '';
  $orig    //= '';
  if ($force) {
    return $orig if length $orig && needs_translation($orig, detect => $detect);
    return $current if length $current && needs_translation($current, detect => $detect);
    return length $orig ? $orig : (length $current ? $current : undef);
  }
  return $current if length $current && needs_translation($current, detect => $detect);
  return $orig    if length $orig    && needs_translation($orig,    detect => $detect);
  return;
}

# Translate an item's description and/or name in place. Returns 1 if anything updated.
sub translate_item {
  my ($item_id, %o) = @_;
  my $force  = $o{force} // 0;
  my $dryrun = $o{dryrun} // 0;
  my $row    = DB::get_item($item_id) or die "No item $item_id\n";
  my \%it    = $row;
  my $c      = $o{config} // config();
  my $detect = $c->{detect};

  my $desc_src = _field_source($it{description}, $it{description_orig}, $detect, $force);
  my $name_src = _field_source($it{name},        $it{name_orig},        $detect, $force);

  unless ($desc_src || $name_src) {
    dry_print($dryrun, "skip #$item_id (name + description already English)");
    return 0;
  }

  my @bits;
  push @bits, 'name' if $name_src;
  push @bits, 'description' if $desc_src;
  dry_print($dryrun, "translate #$item_id (", join('+', @bits), ") via API...");

  if ($dryrun) {
    return 1;
  }

  my %upd;
  if ($desc_src) {
    $upd{description} = translate_text($desc_src, config => $c, kind => 'description');
    $upd{description_orig} =
      (defined $it{description_orig} && length $it{description_orig})
      ? $it{description_orig}
      : $desc_src;
  }
  if ($name_src) {
    my $en_name = translate_text($name_src, config => $c, kind => 'name');
    # Preserve extension from the source name if the model dropped it
    if ($name_src =~ /(\.[A-Za-z0-9]+)\z/ && $en_name !~ /\Q$1\E\z/i) {
      $en_name .= $1;
    }
    $upd{name} = $en_name;
    # Prefer recording the text we just translated. Keep an existing name_orig
    # only when it is a different non-English string (e.g. earlier Chinese title).
    my $prev = $it{name_orig} // '';
    if (length $prev
      && $prev ne $name_src
      && $prev ne $en_name
      && needs_translation($prev, detect => $detect))
    {
      $upd{name_orig} = $prev;
    }
    else {
      $upd{name_orig} = $name_src;
    }
  }

  DB::update_item_fields($item_id, \%upd);
  return 1;
}

sub translate_many {
  my (%o) = @_;
  my $force   = $o{force} // 0;
  my $dryrun  = $o{dryrun} // 0;
  my $verbose = $o{verbose} // 0;
  my $limit   = $o{limit} // 5000;
  my @ids     = @{ $o{ids} // [] };
  my $c       = config();
  my $detect  = $c->{detect};

  my @rows;
  if (@ids) {
    for my $id (@ids) {
      my $row = DB::get_item($id) or die "No item $id\n";
      push @rows, $row;
    }
  }
  else {
    for my $row (DB::list_items(limit => $limit)->@*) {
      my \%it = $row;
      my $need =
           needs_translation($it{description} // '', detect => $detect)
        || needs_translation($it{name} // '',        detect => $detect)
        || (
        $force
        && (  needs_translation($it{description_orig} // '', detect => $detect)
           || needs_translation($it{name_orig} // '',        detect => $detect))
        );
      push @rows, $row if $need;
    }
  }

  my $n = 0;
  for my $row (@rows) {
    my \%it = $row;
    try {
      my $ok = translate_item($it{id}, force => $force, dryrun => $dryrun, config => $c);
      $n++ if $ok;
      say "translate #$it{id}: ", ($ok ? 'ok' : 'skip') if $verbose;
    }
    catch ($e) {
      warn "translate #$it{id} failed: $e";
    }
  }
  return $n;
}

# Used on import: translate description if non-English and auto_import on.
sub maybe_translate_description {
  my ($description, %o) = @_;
  my $c = config();
  return $description
    unless defined $description && needs_translation($description, detect => $c->{detect});
  return $description unless $c->{enabled} && $c->{auto_import};
  return $description unless api_key($c);

  try {
    my $en = translate_text($description, config => $c, kind => 'description');
    $o{orig_ref} && (${ $o{orig_ref} } = $description);
    return $en;
  }
  catch ($e) {
    warn "auto-translate description failed (keeping original): $e";
    return $description;
  }
}

# Used on import: translate display name if non-English. Keeps original via orig_ref.
# Does not rename files on disk — only the catalog name field.
sub maybe_translate_name {
  my ($name, %o) = @_;
  my $c = config();
  return $name unless defined $name && needs_translation($name, detect => $c->{detect});
  return $name unless $c->{enabled} && $c->{auto_import};
  return $name unless api_key($c);

  try {
    my $en = translate_text($name, config => $c, kind => 'name');
    if ($name =~ /(\.[A-Za-z0-9]+)\z/ && $en !~ /\Q$1\E\z/i) {
      $en .= $1;
    }
    $o{orig_ref} && (${ $o{orig_ref} } = $name);
    return $en;
  }
  catch ($e) {
    warn "auto-translate name failed (keeping original): $e";
    return $name;
  }
}

1;
