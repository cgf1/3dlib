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

  return {
    enabled     => exists $t->{enabled} ? !!$t->{enabled} : 1,
    provider    => $provider,
    base_url    => $t->{base_url} // $d->{base_url},
    model       => $t->{model} // $d->{model},
    api_key_env => $t->{api_key_env} // $d->{api_key_env},
    api_key     => $t->{api_key},    # optional inline (prefer env)
    timeout     => $t->{timeout} // 120,
    auto_import => exists $t->{auto_import} ? !!$t->{auto_import} : 1,
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

sub needs_translation {
  my ($text) = @_;
  return 0 unless defined $text && $text =~ /\S/;
  return 1 if has_han($text);
  # Common CJK punctuation-only blocks already handled by has_han on content
  return 0;
}

sub translate_text {
  my ($text, %o) = @_;
  $text = text_for_db($text) // '';
  return $text unless needs_translation($text);

  my $c = $o{config} // config();
  die "Translation disabled in config\n" unless $c->{enabled};

  my $key = api_key($c);
  die "No API key (set $c->{api_key_env} or OPENAI_API_KEY / XAI_API_KEY)\n"
    unless $key && length $key;

  my $base = $c->{base_url} // 'https://api.openai.com/v1';
  $base =~ s{/$}{};
  my $url = "$base/chat/completions";

  my $body = {
    model       => $c->{model},
    temperature => 0.2,
    messages    => [
      {
        role    => 'system',
        content => join(
          ' ',
          'You translate 3D-printing model catalog text into clear English.',
          'Preserve technical meaning, sizes, materials, and structure.',
          'Keep Designer/License/Source/Last modified lines intact if present;',
          'translate only the human description parts that are not English.',
          'Output only the translated catalog text, no preamble.',
        ),
      },
      { role => 'user', content => $text },
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

# Translate an item's description in place. Returns 1 if updated.
sub translate_item {
  my ($item_id, %o) = @_;
  my $force  = $o{force} // 0;
  my $dryrun = $o{dryrun} // 0;
  my $row    = DB::get_item($item_id) or die "No item $item_id\n";
  my \%it    = $row;

  my $desc = $it{description} // '';
  my $orig = $it{description_orig};

  # Already have English description (CJK original may be in description_orig, not shown in UI)
  if (!$force && length $desc && !needs_translation($desc)) {
    dry_print(
      $dryrun,
      "skip #$item_id (already English"
        . (
        (defined $orig && length $orig)
        ? '; original kept in DB, hidden from UI'
        : ''
        )
        . ')'
    );
    return 0;
  }

  my $source = needs_translation($desc) ? $desc
    : (defined $orig && needs_translation($orig) ? $orig : undef);
  unless ($source) {
    dry_print($dryrun, "skip #$item_id (no CJK text to translate)");
    return 0;
  }

  dry_print($dryrun, "translate #$item_id via API...");
  if ($dryrun) {
    return 1;
  }

  my $english = translate_text($source);
  # Keep original Chinese once
  my $keep_orig = (defined $orig && length $orig) ? $orig : $source;

  DB::dbh()->do(
    q{
      UPDATE items
      SET description = ?, description_orig = ?, updated_at = ?
      WHERE id = ?
    },
    undef, $english, $keep_orig, time, $item_id
  );
  return 1;
}

sub translate_many {
  my (%o) = @_;
  my $force   = $o{force} // 0;
  my $dryrun  = $o{dryrun} // 0;
  my $verbose = $o{verbose} // 0;
  my $limit   = $o{limit} // 5000;
  my @ids     = @{ $o{ids} // [] };

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
      my $desc = $it{description} // '';
      my $orig = $it{description_orig} // '';
      if ($force) {
        push @rows, $row if needs_translation($desc) || needs_translation($orig);
      }
      else {
        # missing translation: description still has Han, or never processed
        push @rows, $row if needs_translation($desc);
      }
    }
  }

  my $n = 0;
  for my $row (@rows) {
    my \%it = $row;
    try {
      my $ok = translate_item($it{id}, force => $force, dryrun => $dryrun);
      $n++ if $ok;
      say "translate #$it{id}: ", ($ok ? 'ok' : 'skip') if $verbose;
    }
    catch ($e) {
      warn "translate #$it{id} failed: $e";
    }
  }
  return $n;
}

# Used on import: translate summary/description if CJK and auto_import on.
sub maybe_translate_description {
  my ($description, %o) = @_;
  return $description unless defined $description && needs_translation($description);
  my $c = config();
  return $description unless $c->{enabled} && $c->{auto_import};
  return $description unless api_key($c);

  try {
    my $en = translate_text($description, config => $c);
    $o{orig_ref} && (${ $o{orig_ref} } = $description);
    return $en;
  }
  catch ($e) {
    warn "auto-translate failed (keeping original): $e";
    return $description;
  }
}

1;
