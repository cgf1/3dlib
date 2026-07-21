package Web;
use v5.40;
use experimental qw(class refaliasing declared_refs);
use Encode ();
use HTTP::Daemon;
use HTTP::Status;
use HTTP::Response;
use JSON::PP;
use URI::Escape qw(uri_unescape uri_escape);
use File::Basename qw(basename);
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use POSIX qw(:sys_wait_h);
use Cwd qw(abs_path);
use Archive::Zip qw(:ERROR_CODES);
use LibConfig ();
use DB ();
use Util qw(human_size fmt_time path_ext);
use Run ();
use WebAuth ();
use Delete ();

sub serve {
  my (%o) = @_;
  my $cfg  = LibConfig::load_config();
  my $host = $o{bind} // $cfg->{bind} // '0.0.0.0';
  my $port = $o{port} // $cfg->{port} // 31353;

  my $d = HTTP::Daemon->new(
    LocalAddr => $host,
    LocalPort => $port,
    ReuseAddr => 1,
    Listen    => 64,
  ) or die "Cannot bind $host:$port: $!\n";

  say "3dlib web: http://$host:$port/";
  say "Library: ", LibConfig::library_root();
  if (WebAuth::auth_enabled()) {
    say "Password protection: ON (THREEDLIB_WEB_PASSWORD or web.password)";
    if (WebAuth::admin_password_set()) {
      say "Admin password: ON (delete requires admin login, except from this host)";
    }
    else {
      say "Admin password: off (family password has full access including delete)";
    }
  }
  elsif (WebAuth::admin_password_set()) {
    say "Browse is open; delete requires admin login (or same-host access)";
  }
  else {
    say "Password protection: off (set THREEDLIB_WEB_PASSWORD for family login)";
    say "Delete via web: same-host (localhost) only until a password is set";
  }
  if (WebAuth::local_admin_enabled()) {
    say "Local admin: ON (connections from this machine get full admin, no login)";
  }
  else {
    say "Local admin: off (THREEDLIB_WEB_LOCAL_ADMIN=0)";
  }
  say "Ctrl-C to stop; Ctrl-\\ (SIGQUIT) to restart.";
  say "Note: for LAN family use only — do not port-forward to the internet.";

  # Reap children; HTTP::Daemon is single-threaded, so we fork per connection
  # so the browser can load many /thumb/N images in parallel.
  local $SIG{CHLD} = sub {
    1 while waitpid(-1, WNOHANG) > 0;
  };

  # Ctrl-\ / SIGQUIT → graceful re-exec (reload code without losing the terminal job)
  my $restart = 0;
  local $SIG{QUIT} = sub { $restart = 1; };

  while (!$restart) {
    my $c = $d->accept;
    if ($restart) {
      $c->close if $c;
      last;
    }
    next unless $c;    # accept interrupted by signal

    my $pid = fork();
    if (!defined $pid) {
      warn "fork failed: $!";
      $c->close;
      next;
    }
    if ($pid == 0) {
      # Child: handle this client only.
      # Do NOT close $d — HTTP::Daemon::ClientConn calls $daemon->url
      # (sockhost/sockport) while parsing each request; closing the listen
      # socket makes those undef and spam warnings.
      local $SIG{QUIT} = 'DEFAULT';    # only the parent restarts
      DB::reconnect();
      try {
        while (my $r = $c->get_request) {
          try {
            _handle($c, $r);
          }
          catch ($e) {
            warn "request error: $e";
            try { _send($c, 500, 'text/plain', "Error: $e") } catch ($e2) { }
          }
        }
      }
      catch ($e) {
        warn "connection error: $e";
      }
      $c->close;
      exit 0;
    }
    # Parent: close client fd, keep listening
    $c->close;
    undef $c;
  }

  if ($restart) {
    say "SIGQUIT: restarting 3dlib serve...";
    eval { $d->close };
    # Drop children still finishing requests (they'll exit on their own)
    my $bin = $o{reexec} // $ENV{THREEDLIB_BIN} // '/usr/local/bin/3dlib';
    my @cmd = ($bin, 'serve', '--bind', $host, '--port', $port);
    exec @cmd or die "exec @cmd failed: $!\n";
  }
}

sub _handle {
  my ($c, $r) = @_;
  my $path = $r->uri->path;
  my $q    = $r->uri->query // '';
  my %qp   = map {
    my ($k, $v) = split /=/, $_, 2;
    $k => uri_unescape($v // '')
  } split /&/, $q;

  my ($role, $role_via) = WebAuth::role_for($c, $r);

  # --- auth routes (always available) ---
  if ($path eq '/login') {
    if ($r->method eq 'POST') {
      return _do_login($c, $r);
    }
    return _send($c, 200, 'text/html; charset=utf-8', _page_login($qp{err}));
  }
  if ($path eq '/logout') {
    # Local admin ignores cookies; logout still clears any session cookie.
    my $dest = ($role_via // '') eq 'local' ? '/' : '/login';
    return _send(
      $c, 302, 'text/html; charset=utf-8',
      qq{<a href="$dest">Logged out</a>},
      extra_headers => { Location => $dest, 'Set-Cookie' => WebAuth::clear_cookie_header() },
    );
  }

  # Site password gate (LAN family use — not for the public internet)
  # Same-host connections get admin via role_for and pass this check.
  if (WebAuth::auth_enabled() && !WebAuth::require_login($role)) {
    return _send(
      $c, 302, 'text/html; charset=utf-8',
      '<a href="/login">Login required</a>',
      extra_headers => { Location => '/login' },
    );
  }

  if ($path eq '/' || $path eq '') {
    return _send($c, 200, 'text/html; charset=utf-8',
      _page_home(%qp, _role => $role, _role_via => $role_via));
  }
  if ($path =~ m{^/item/(\d+)$}) {
    return _send($c, 200, 'text/html; charset=utf-8', _page_item($1, $role, $role_via));
  }
  if ($path =~ m{^/thumb/(\d+)$}) {
    return _send_thumb($c, $1);
  }
  if ($path =~ m{^/file/(\d+)$}) {
    return _send_item_file($c, $1, $qp{rel}, disposition => 'inline');
  }
  if ($path =~ m{^/download/(\d+)$}) {
    return _send($c, 403, 'text/plain', 'Forbidden') unless WebAuth::can_download($role);
    return _send_download($c, $1);
  }
  if ($path eq '/download-zip' && $r->method eq 'POST') {
    return _send($c, 403, 'text/plain', 'Forbidden') unless WebAuth::can_download($role);
    return _send_download_zip($c, $r);
  }
  if ($path eq '/api/delete' && $r->method eq 'POST') {
    return _send($c, 403, 'text/plain', 'Forbidden') unless WebAuth::can_delete($role);
    return _api_delete($c, $r);
  }
  if ($path =~ m{^/api/items$}) {
    my $items = DB::list_items(
      type   => $qp{type},
      kind   => $qp{kind},
      limit  => $qp{limit} // 200,
    );
    if ($qp{q}) {
      $items = DB::search($qp{q}, $qp{limit} // 50);
    }
    return _send($c, 200, 'application/json',
      JSON::PP->new->utf8->encode($items));
  }
  if ($path =~ m{^/api/stats$}) {
    return _send($c, 200, 'application/json',
      JSON::PP->new->utf8->encode(DB::stats()));
  }
  if ($path eq '/open' && $r->method eq 'POST') {
    my %f = _parse_form($r);
    my $id = $f{id} // $qp{id};
    die "missing id\n" unless $id;
    my $res = Run::run(target => $id, no_import => 1);
    return _send($c, 200, 'application/json',
      JSON::PP->new->utf8->encode($res));
  }
  if ($path eq '/open' && $r->method eq 'GET') {
    my $id = $qp{id} or die "missing id\n";
    my $res = Run::run(target => $id, no_import => 1);
    return _send($c, 200, 'text/html; charset=utf-8',
      _html_wrap('Opened', '<p>Launched Bambu Studio.</p><p><a href="/item/'
        . $id . '">Back</a></p><pre>'
        . _esc(JSON::PP->new->canonical->encode($res)) . '</pre>', '', '', $role, $role_via));
  }
  if ($path eq '/stl-viewer') {
    return _send($c, 200, 'text/html; charset=utf-8',
      _page_stl_viewer($qp{id}, $qp{rel}, $role, $role_via));
  }
  _send($c, 404, 'text/plain', 'Not found');
}

sub _parse_form {
  my ($r) = @_;
  my $body = $r->content // '';
  my %f;
  for my $part (split /&/, $body) {
    my ($k, $v) = split /=/, $part, 2;
    $k = uri_unescape($k // '');
    $v = uri_unescape($v // '');
    if (exists $f{$k}) {
      $f{$k} = [ $f{$k} ] unless ref $f{$k};
      push $f{$k}->@*, $v;
    }
    else {
      $f{$k} = $v;
    }
  }
  return %f;
}

sub _form_ids {
  my (%f) = @_;
  my $raw = $f{ids} // $f{id};
  my @ids;
  if (ref $raw eq 'ARRAY') {
    @ids = $raw->@*;
  }
  elsif (defined $raw && length $raw) {
    @ids = split /[,\s]+/, $raw;
  }
  @ids = grep { defined && /^\d+$/ } @ids;
  my %seen;
  return grep { !$seen{$_}++ } @ids;
}

sub _do_login {
  my ($c, $r) = @_;
  my %f    = _parse_form($r);
  my $role = WebAuth::check_password($f{password} // '');
  unless ($role) {
    return _send($c, 200, 'text/html; charset=utf-8', _page_login('Invalid password'));
  }
  my $token = WebAuth::make_token($role);
  return _send(
    $c, 302, 'text/html; charset=utf-8',
    '<a href="/">OK</a>',
    extra_headers => {
      Location     => '/',
      'Set-Cookie' => WebAuth::set_cookie_header($token),
    },
  );
}

sub _api_delete {
  my ($c, $r) = @_;
  my %f   = _parse_form($r);
  my @ids = _form_ids(%f);
  die "no ids\n" unless @ids;

  my $res = Delete::delete_items(targets => \@ids, dryrun => 0, keep_files => 0);
  return _send($c, 200, 'application/json',
    JSON::PP->new->utf8->encode({ ok => 1, deleted => scalar @ids, results => $res }));
}

sub _send {
  my ($c, $code, $ctype, $body, %opt) = @_;
  my $res = HTTP::Response->new($code);
  $res->header('Content-Type' => $ctype);
  # HTML/API should not stick in the browser after code or catalog changes
  $res->header('Cache-Control' => 'no-store, no-cache, must-revalidate');
  $res->header('Pragma'        => 'no-cache');
  if (my $extra = $opt{extra_headers}) {
    for my $k (keys $extra->%*) {
      $res->header($k => $extra->{$k});
    }
  }
  if ($opt{raw}) {
    $res->content($body // '');
  }
  else {
    $res->content(Encode::encode_utf8($body // ''));
  }
  $c->send_response($res);
}

sub _send_binary {
  my ($c, $ctype, $data, %headers) = @_;
  my $res = HTTP::Response->new(200);
  $res->header('Content-Type'   => $ctype);
  $res->header('Content-Length' => length($data));
  $res->header('Cache-Control'  => 'no-store');
  for my $k (keys %headers) {
    $res->header($k => $headers{$k});
  }
  $res->content($data);
  $c->send_response($res);
}

# Resolve thumb path + mtime for cache-busting query strings
sub _thumb_info ($id, $item = undef) {
  $item //= DB::get_item($id);
  my $path = $item && $item->{thumb_path};
  if (!$path || !-f $path) {
    my $canon = LibConfig::thumbs_dir() . "/$id.png";
    $path = $canon if -f $canon;
  }
  return unless $path && -f $path;
  my $mt = (stat($path))[9] // time;
  return ($path, $mt);
}

sub _send_thumb {
  my ($c, $id) = @_;
  my ($path, $mt) = _thumb_info($id);
  unless ($path) {
    return _send($c, 404, 'text/plain', 'no thumb');
  }
  open my $fh, '<:raw', $path or die $!;
  local $/;
  my $data = <$fh>;
  close $fh;
  my $res = HTTP::Response->new(200);
  $res->header('Content-Type'   => 'image/png');
  $res->header('Content-Length' => length($data));
  # Short cache; URL also includes ?v=mtime so refreshed thumbs bust cache
  $res->header('Cache-Control'  => 'public, max-age=300');
  $res->header('Last-Modified'  => HTTP::Date::time2str($mt)) if eval { require HTTP::Date; 1 };
  # Binary body — do not run through encode_utf8
  $res->content($data);
  $c->send_response($res);
}

sub _safe_path_under {
  my ($path, $root) = @_;
  my $ap = abs_path($path) // return;
  my $ar = abs_path($root) // return;
  $ap =~ s{/\z}{};
  $ar =~ s{/\z}{};
  return if $ap ne $ar && index($ap, $ar . '/') != 0;
  return $ap;
}

sub _read_file_raw {
  my ($path) = @_;
  open my $fh, '<:raw', $path or die "open $path: $!\n";
  local $/;
  my $data = <$fh>;
  close $fh;
  return $data;
}

sub _ctype_for_ext {
  my ($ext) = @_;
  $ext = lc($ext // '');
  return 'model/stl'  if $ext eq 'stl';
  return 'model/3mf'  if $ext eq '3mf';
  return 'image/png'  if $ext eq 'png';
  return 'image/jpeg' if $ext =~ /^jpe?g$/;
  return 'application/octet-stream';
}

sub _disposition {
  my ($mode, $filename) = @_;
  $filename //= 'download';
  $filename =~ s/[^\w.\-()+ ]+/_/g;
  $filename = 'download' unless length $filename;
  my $type = ($mode // 'attachment') eq 'inline' ? 'inline' : 'attachment';
  return qq{$type; filename="$filename"};
}

sub _send_item_file {
  my ($c, $id, $rel, %o) = @_;
  my $item = DB::get_item($id) or die "no item\n";
  my $path;
  if ($rel) {
    $path = $item->{path} . '/' . $rel;
    my $root = $item->{path};
    my $ap = abs_path($path);
    my $ar = abs_path($root);
    die "bad path\n" unless $ap && $ar && index($ap, $ar) == 0;
    $path = $ap;
  }
  else {
    $path = $item->{path};
  }
  die "missing file\n" unless -f $path;
  my $data = _read_file_raw($path);
  my $ext  = path_ext($path);
  _send_binary(
    $c,
    _ctype_for_ext($ext),
    $data,
    'Content-Disposition' => _disposition($o{disposition} // 'inline', basename($path)),
  );
}

sub _safe_arc_name {
  my ($name, $fallback) = @_;
  $name //= '';
  $name =~ s{[\\/]+}{_}g;
  $name =~ s/[^\w.\-()+ ]+/_/g;
  $name =~ s/^\.+//;
  $name = $fallback if !length $name;
  return $name;
}

sub _add_item_to_zip {
  my ($zip, $item, $prefix) = @_;
  my $lib  = LibConfig::library_root();
  my $path = _safe_path_under($item->{path}, $lib)
    // die "path outside library for #$item->{id}\n";
  my $base = _safe_arc_name($item->{name}, "item-$item->{id}");
  my $root = defined $prefix && length $prefix
    ? "$prefix/" . _safe_arc_name("item-$item->{id}_$base", "item-$item->{id}")
    : $base;

  if (-f $path) {
    my $fn = _safe_arc_name(basename($path), "file-$item->{id}");
    # Flat names: multi-item zips get models/<id>-filename.ext
    my $arc = (defined $prefix && length $prefix)
      ? "$prefix/" . _safe_arc_name("$item->{id}-$fn", $fn)
      : $fn;
    # addFile returns a Member object (not AZ_OK); addTree returns AZ_OK.
    defined $zip->addFile($path, $arc)
      or die "zip addFile $path failed\n";
  }
  elsif (-d $path) {
    my $arc_root = (defined $prefix && length $prefix)
      ? "$prefix/" . _safe_arc_name("$item->{id}_$base", "item-$item->{id}")
      : $base;
    $zip->addTree($path, $arc_root) == AZ_OK
      or die "zip addTree $path failed\n";
  }
  else {
    die "missing path for #$item->{id}: $path\n";
  }
}

sub _zip_to_bytes {
  my ($zip) = @_;
  my $tmpdir = tempdir(CLEANUP => 1);
  my $zippath = "$tmpdir/bundle.zip";
  $zip->writeToFileNamed($zippath) == AZ_OK
    or die "failed to write zip\n";
  return _read_file_raw($zippath);
}

sub _send_download {
  my ($c, $id) = @_;
  my $item = DB::get_item($id) or die "no item\n";
  my $lib  = LibConfig::library_root();
  my $path = _safe_path_under($item->{path}, $lib)
    // die "path outside library\n";

  if (-f $path) {
    my $data = _read_file_raw($path);
    return _send_binary(
      $c,
      _ctype_for_ext(path_ext($path)),
      $data,
      'Content-Disposition' => _disposition('attachment', basename($path)),
    );
  }

  if (-d $path) {
    my $zip = Archive::Zip->new();
    _add_item_to_zip($zip, $item, undef);
    my $data = _zip_to_bytes($zip);
    my $name = _safe_arc_name($item->{name}, "item-$id") . '.zip';
    return _send_binary(
      $c,
      'application/zip',
      $data,
      'Content-Disposition' => _disposition('attachment', $name),
    );
  }

  die "missing path for item $id\n";
}

sub _send_download_zip {
  my ($c, $r) = @_;
  my %f   = _parse_form($r);
  my @ids = _form_ids(%f);
  die "no ids\n" unless @ids;
  die "too many items (max 50)\n" if @ids > 50;

  my $zip = Archive::Zip->new();
  my $n   = 0;
  for my $id (@ids) {
    my $item = DB::get_item($id) or next;
    _add_item_to_zip($zip, $item, @ids > 1 ? 'models' : undef);
    $n++;
  }
  die "no valid items\n" unless $n;

  my $data = _zip_to_bytes($zip);
  my $name = $n == 1 ? "model-$ids[0].zip" : "3dlib-$n-models.zip";
  return _send_binary(
    $c,
    'application/zip',
    $data,
    'Content-Disposition' => _disposition('attachment', $name),
  );
}

sub _esc {
  my ($s) = @_;
  $s //= '';
  $s =~ s/&/&amp;/g;
  $s =~ s/</&lt;/g;
  $s =~ s/>/&gt;/g;
  $s =~ s/"/&quot;/g;
  return $s;
}

# Escape text, then turn http(s) URLs into links (safe against injected HTML).
sub _linkify {
  my ($s) = @_;
  $s = _esc($s // '');
  $s =~ s{
    (https?://[^\s<>"']+)
  }{
    my $full = $1;
    my $url  = $full;
    $url =~ s/[.,;:!?)]+$//;    # trim trailing punctuation from the href/text
    my $trail = length($full) > length($url) ? substr($full, length($url)) : '';
    qq{<a href="$url" target="_blank" rel="noopener noreferrer">$url</a>$trail}
  }gex;
  return $s;
}

sub _source_html {
  my ($site, $url, $sources_json) = @_;
  my @bits;
  if ($url) {
    my $label = $site && length $site ? "$site — $url" : $url;
    push @bits, qq{<a href="} . _esc($url) . qq{" target="_blank" rel="noopener noreferrer">}
      . _esc($label) . qq{</a>};
  }
  elsif ($site) {
    push @bits, _esc($site);
  }

  if ($sources_json) {
    require JSON::PP;
    my $list = eval { JSON::PP->new->utf8->decode($sources_json) };
    if (ref $list eq 'ARRAY') {
      for my $u ($list->@*) {
        next unless $u && $u =~ m{^https?://}i;
        next if $url && $u eq $url;
        push @bits, qq{<a href="} . _esc($u) . qq{" target="_blank" rel="noopener noreferrer">}
          . _esc($u) . qq{</a>};
      }
    }
  }

  return @bits ? join('<br>', @bits) : '<span class="muted">—</span>';
}

sub _css {
  return q{
    :root {
      --bg:#f4f6f9;
      --card:#ffffff;
      --fg:#1a2332;
      --muted:#5a6a7e;
      --acc:#2563eb;
      --ok:#059669;
      --danger:#dc2626;
      --border:#d8dee8;
      --input:#ffffff;
      --panel:#eef2f7;
    }
    * { box-sizing: border-box; }
    body { margin:0; font-family: system-ui, sans-serif; background:var(--bg); color:var(--fg); }
    header { padding:1rem 1.5rem; border-bottom:1px solid var(--border); background:#fff; display:flex; gap:1rem; align-items:center; flex-wrap:wrap; }
    header a { color:var(--acc); text-decoration:none; font-weight:600; }
    header form { margin-left:auto; display:flex; gap:.5rem; }
    header .auth { display:flex; gap:.75rem; align-items:center; font-size:.9rem; }
    input, select, button { background:var(--input); color:var(--fg); border:1px solid var(--border); border-radius:6px; padding:.4rem .7rem; }
    input:focus, select:focus { outline:2px solid #93c5fd; border-color:var(--acc); }
    button, .btn { background:var(--acc); color:#fff; border:none; cursor:pointer; text-decoration:none; display:inline-block; border-radius:6px; padding:.45rem .8rem; font-size:.9rem; }
    button:hover, .btn:hover { filter:brightness(1.05); }
    .btn.secondary { background:#e8eef6; color:var(--fg); border:1px solid var(--border); }
    .btn.danger, button.danger { background:var(--danger); color:#fff; }
    .btn:disabled, button:disabled { opacity:.45; cursor:not-allowed; filter:none; }
    main { padding:1.25rem; }
    .grid { display:grid; grid-template-columns:repeat(auto-fill,minmax(180px,1fr)); gap:1rem; }
    .card { background:var(--card); border-radius:10px; overflow:hidden; border:1px solid var(--border); box-shadow:0 1px 2px rgba(16,24,40,.04); transition:.15s; position:relative; }
    .card:hover { border-color:var(--acc); transform:translateY(-2px); box-shadow:0 4px 12px rgba(16,24,40,.08); }
    .card.selected { border-color:var(--acc); box-shadow:0 0 0 2px rgba(37,99,235,.25); }
    .card a { color:inherit; text-decoration:none; }
    .card img { width:100%; aspect-ratio:1; object-fit:cover; background:var(--panel); display:block; }
    .card .ph { width:100%; aspect-ratio:1; display:flex; align-items:center; justify-content:center; background:var(--panel); color:var(--muted); font-size:.85rem; }
    .card .meta { padding:.6rem .75rem .8rem; }
    .card .name { font-weight:600; font-size:.92rem; white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }
    .card .sel { position:absolute; top:.45rem; left:.45rem; z-index:2; background:rgba(255,255,255,.92); border-radius:6px; padding:.2rem .3rem; border:1px solid var(--border); box-shadow:0 1px 2px rgba(0,0,0,.06); }
    .card .sel input { width:1.05rem; height:1.05rem; margin:0; accent-color:var(--acc); cursor:pointer; }
    .badge { display:inline-block; font-size:.7rem; padding:.1rem .4rem; border-radius:4px; background:var(--panel); color:var(--muted); text-transform:uppercase; border:1px solid var(--border); }
    .muted { color:var(--muted); font-size:.8rem; }
    a { color:var(--acc); }
    .detail { display:grid; grid-template-columns:280px 1fr; gap:1.5rem; }
    @media (max-width:800px) { .detail { grid-template-columns:1fr; } }
    .detail img.big { width:100%; border-radius:10px; background:var(--panel); border:1px solid var(--border); }
    table { width:100%; border-collapse:collapse; }
    td, th { text-align:left; padding:.4rem .5rem; border-bottom:1px solid var(--border); font-size:.9rem; }
    th { color:var(--muted); font-weight:600; }
    pre { background:var(--panel); padding:1rem; border-radius:8px; overflow:auto; white-space:pre-wrap; border:1px solid var(--border); }
    pre.desc a { word-break: break-all; }
    .actions { display:flex; gap:.5rem; flex-wrap:wrap; margin:1rem 0; }
    .bulk-bar { display:flex; flex-wrap:wrap; gap:.75rem; align-items:center; background:#fff; border:1px solid var(--border); border-radius:10px; padding:.65rem 1rem; margin:0 0 1rem; box-shadow:0 1px 2px rgba(16,24,40,.04); position:sticky; top:0; z-index:5; }
    .bulk-bar label { display:flex; gap:.4rem; align-items:center; font-size:.9rem; cursor:pointer; user-select:none; }
    .login-wrap { max-width:380px; margin:4rem auto; background:#fff; border:1px solid var(--border); border-radius:12px; padding:1.75rem; box-shadow:0 4px 16px rgba(16,24,40,.06); }
    .login-wrap h1 { margin:0 0 .35rem; font-size:1.35rem; }
    .login-wrap form { display:flex; flex-direction:column; gap:.75rem; margin-top:1.25rem; }
    .login-wrap input[type=password] { width:100%; padding:.6rem .75rem; }
    .login-wrap .err { color:var(--danger); font-size:.9rem; margin:0; }
    .note { font-size:.85rem; color:var(--muted); margin-top:1rem; line-height:1.4; }
    #viewer { width:100%; height:480px; background:#e8eef5; border-radius:10px; border:1px solid var(--border); }
    code { background:var(--panel); padding:.1rem .35rem; border-radius:4px; font-size:.9em; }
  };
}

sub _header {
  my ($q, $role, $role_via) = @_;
  $q //= '';
  my $auth = '';
  my $show_auth = WebAuth::auth_enabled()
    || WebAuth::admin_password_set()
    || defined $role
    || WebAuth::local_admin_enabled();
  if ($show_auth) {
    if (defined $role) {
      my $label = ($role_via // '') eq 'local'
        ? 'local admin'
        : ($role eq 'admin' ? 'admin' : 'signed in');
      # Local admin is peer-based; logout only clears cookies (still admin here).
      my $logout = ($role_via // '') eq 'local'
        ? ''
        : qq{<a href="/logout">Logout</a>};
      $auth = qq{<div class="auth"><span class="muted">$label</span>$logout</div>};
    }
    else {
      $auth = qq{<div class="auth"><a href="/login">Login</a></div>};
    }
  }
  return qq{
<header>
  <a href="/">3dlib</a>
  <span class="muted">/share/3d</span>
  $auth
  <form method="get" action="/">
    <input type="search" name="q" value="} . _esc($q) . qq{" placeholder="Search…"/>
    <button type="submit">Search</button>
  </form>
</header>
};
}

sub _html_wrap {
  my ($title, $body, $extra_head, $q, $role, $role_via) = @_;
  $extra_head //= '';
  return qq{<!DOCTYPE html>
<html lang="en"><head>
<meta charset="utf-8"/>
<meta name="viewport" content="width=device-width, initial-scale=1"/>
<title>} . _esc($title) . qq{ - 3dlib</title>
<meta http-equiv="Cache-Control" content="no-store"/>
<style>} . _css() . qq{</style>
$extra_head
</head><body>
} . _header($q, $role, $role_via) . qq{
<main>$body</main>
</body></html>};
}

sub _page_login {
  my ($err) = @_;
  my $err_html = $err
    ? qq{<p class="err">} . _esc($err) . qq{</p>}
    : '';
  my $body = qq{
<div class="login-wrap">
  <h1>3dlib</h1>
  <p class="muted">Enter the family password to browse and download models.</p>
  $err_html
  <form method="post" action="/login">
    <input type="password" name="password" placeholder="Password" autofocus required autocomplete="current-password"/>
    <button type="submit">Sign in</button>
  </form>
  <p class="note">LAN use only — keep this service off the public internet (no port-forward / no reverse proxy without extra auth).</p>
</div>
};
  # Minimal shell without full header search (still logged out)
  return qq{<!DOCTYPE html>
<html lang="en"><head>
<meta charset="utf-8"/>
<meta name="viewport" content="width=device-width, initial-scale=1"/>
<title>Login - 3dlib</title>
<meta http-equiv="Cache-Control" content="no-store"/>
<style>} . _css() . qq{</style>
</head><body>
<main>$body</main>
</body></html>};
}

sub _bulk_js {
  my (%o) = @_;
  my $can_dl  = $o{can_download} ? 1 : 0;
  my $can_del = $o{can_delete}   ? 1 : 0;
  # Script is injected in <head>; wait for DOM so checkboxes/buttons exist.
  return qq{
<script>
document.addEventListener('DOMContentLoaded', () => {
  const canDl = $can_dl;
  const canDel = $can_del;
  const boxes = () => [...document.querySelectorAll('.item-sel')];
  const selAll = document.getElementById('sel-all');
  const countEl = document.getElementById('sel-count');
  const btnDl = document.getElementById('btn-dl');
  const btnDel = document.getElementById('btn-del');

  function selected() {
    return boxes().filter(b => b.checked).map(b => b.value);
  }
  function refresh() {
    const ids = selected();
    if (countEl) countEl.textContent = ids.length + ' selected';
    if (btnDl) {
      btnDl.disabled = !canDl || ids.length === 0;
      btnDl.title = ids.length ? 'Download selected' : 'Select one or more items first';
    }
    if (btnDel) {
      btnDel.disabled = !canDel || ids.length === 0;
      btnDel.title = ids.length ? 'Delete selected from library and disk' : 'Select one or more items first';
    }
    boxes().forEach(b => {
      const card = b.closest('.card');
      if (card) card.classList.toggle('selected', b.checked);
    });
    if (selAll) {
      const all = boxes();
      selAll.checked = all.length > 0 && all.every(b => b.checked);
      selAll.indeterminate = ids.length > 0 && ids.length < all.length;
    }
  }
  // Keep card link from stealing clicks on the checkbox
  document.querySelectorAll('.card .sel').forEach(lab => {
    lab.addEventListener('click', (e) => e.stopPropagation());
  });
  boxes().forEach(b => b.addEventListener('change', refresh));
  if (selAll) {
    selAll.addEventListener('change', () => {
      boxes().forEach(b => { b.checked = selAll.checked; });
      refresh();
    });
  }
  if (btnDl) {
    btnDl.addEventListener('click', () => {
      const ids = selected();
      if (!ids.length) return;
      if (ids.length === 1) {
        window.location = '/download/' + ids[0];
        return;
      }
      const form = document.createElement('form');
      form.method = 'POST';
      form.action = '/download-zip';
      ids.forEach(id => {
        const i = document.createElement('input');
        i.type = 'hidden';
        i.name = 'ids';
        i.value = id;
        form.appendChild(i);
      });
      document.body.appendChild(form);
      form.submit();
      form.remove();
    });
  }
  if (btnDel) {
    btnDel.addEventListener('click', async () => {
      const ids = selected();
      if (!ids.length) return;
      const msg = 'Delete ' + ids.length + ' item(s) from the library and disk?\\n\\nThis cannot be undone.';
      if (!confirm(msg)) return;
      const body = ids.map(id => 'ids=' + encodeURIComponent(id)).join('&');
      try {
        const res = await fetch('/api/delete', {
          method: 'POST',
          headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
          body,
          credentials: 'same-origin',
        });
        if (!res.ok) {
          const t = await res.text();
          alert('Delete failed: ' + (t || res.status));
          return;
        }
        window.location.reload();
      } catch (e) {
        alert('Delete failed: ' + e);
      }
    });
  }
  refresh();
});
</script>
};
}

sub _page_home {
  my (%qp) = @_;
  my $role     = $qp{_role};
  my $role_via = $qp{_role_via};
  my $items;
  if ($qp{q}) {
    $items = DB::search($qp{q}, 200);
  }
  else {
    $items = DB::list_items(
      type  => $qp{type},
      kind  => $qp{kind},
      limit => $qp{limit} // 200,
    );
  }
  my $st        = DB::stats();
  my $can_dl    = WebAuth::can_download($role);
  my $can_del   = WebAuth::can_delete($role);
  my $show_bulk = $can_dl || $can_del;

  my $cards = '';
  for my $row ($items->@*) {
    my \%it = $row;
    my ($tpath, $tmt) = _thumb_info($it{id}, \%it);
    my $thumb = $tpath
      ? qq{<img src="/thumb/$it{id}?v=$tmt" alt="" loading="lazy"/>}
      : qq{<div class="ph">} . _esc(uc($it{type} // '?')) . qq{</div>};
    my $sel = $show_bulk
      ? qq{<label class="sel" title="Select"><input type="checkbox" class="item-sel" value="$it{id}"/></label>}
      : '';
    $cards .= qq{
      <div class="card">
        $sel
        <a href="/item/$it{id}">
          $thumb
          <div class="meta">
            <div class="name" title="} . _esc($it{name}) . qq{">} . _esc($it{name}) . qq{</div>
            <div><span class="badge">} . _esc($it{type}) . qq{</span>
            <span class="badge">} . _esc($it{kind}) . qq{</span></div>
            <div class="muted">} . _esc(fmt_time($it{mtime})) . qq{</div>
          </div>
        </a>
      </div>};
  }
  $cards = '<p class="muted">No items yet. Import something with <code>3dlib import PATH</code>.</p>'
    unless $items->@*;

  my $bulk = '';
  if ($show_bulk && $items->@*) {
    my $dl_btn  = $can_dl  ? qq{<button type="button" class="btn secondary" id="btn-dl" disabled>Download</button>} : '';
    my $del_btn = $can_del ? qq{<button type="button" class="btn danger" id="btn-del" disabled>Delete</button>} : '';
    $bulk = qq{
      <div class="bulk-bar" id="bulk-bar">
        <label><input type="checkbox" id="sel-all"/> Select all</label>
        <span class="muted" id="sel-count">0 selected</span>
        $dl_btn
        $del_btn
      </div>
    };
  }

  my $filters = qq{
    <p class="muted">}
    . ($st->{total} // 0) . qq{ items
    · } . ($st->{no_thumb} // 0) . qq{ without thumb
    · } . ($st->{no_source} // 0) . qq{ without source
    · filter:
    <a href="/">all</a>
    <a href="/?type=3mf">3mf</a>
    <a href="/?type=stl">stl</a>
    <a href="/?type=step">step</a>
    <a href="/?type=fcstd">fcstd</a>
    <a href="/?kind=project">projects</a>
    </p>
    $bulk
    <div class="grid">$cards</div>
  };
  my $extra = $show_bulk && $items->@*
    ? _bulk_js(can_download => $can_dl, can_delete => $can_del)
    : '';
  return _html_wrap('Library', $filters, $extra, $qp{q}, $role, $role_via);
}

sub _page_item ($id, $role = undef, $role_via = undef) {
  my $row = DB::get_item($id)
    or return _html_wrap('Missing', '<p>Item not found</p>', '', '', $role, $role_via);
  my \%it = $row;
  my $files = DB::item_files($id);
  my ($tpath, $tmt) = _thumb_info($id, \%it);
  my $thumb = $tpath
    ? qq{<img class="big" src="/thumb/$id?v=$tmt" alt=""/>}
    : qq{<div class="ph" style="aspect-ratio:1;border-radius:10px">No thumbnail</div>};

  my $can_dl  = WebAuth::can_download($role);
  my $can_del = WebAuth::can_delete($role);

  my $actions = qq{<div class="actions">};
  if ($can_dl) {
    $actions .= qq{<a class="btn" href="/download/$id">Download</a>};
  }
  if (($it{type} // '') eq '3mf' || grep { my \%f = $_; ($f{ext} // '') eq '3mf' } $files->@*) {
    $actions .= qq{<a class="btn secondary" href="/open?id=$id">Open in Bambu Studio</a>};
  }
  my ($stl) = grep { my \%f = $_; ($f{ext} // '') eq 'stl' } $files->@*;
  if ($stl || ($it{type} // '') eq 'stl') {
    my \%stlf = $stl // {};
    my $rel = $stl ? uri_escape($stlf{relpath} // '') : '';
    $actions .= qq{<a class="btn secondary" href="/stl-viewer?id=$id&rel=$rel">Inspect STL</a>};
  }
  if ($it{source_url}) {
    $actions .= qq{<a class="btn secondary" href="} . _esc($it{source_url}) . qq{" target="_blank" rel="noopener">Source</a>};
  }
  if ($can_del) {
    $actions .= qq{<button type="button" class="btn danger" id="btn-del-one">Delete</button>};
  }
  $actions .= qq{</div>};

  my $del_js = '';
  if ($can_del) {
    # Script is in <head>; wait for the button to exist.
    $del_js = qq{
<script>
document.addEventListener('DOMContentLoaded', () => {
  const btn = document.getElementById('btn-del-one');
  if (!btn) return;
  btn.addEventListener('click', async () => {
    if (!confirm('Delete this item from the library and disk?\\n\\nThis cannot be undone.')) return;
    try {
      const res = await fetch('/api/delete', {
        method: 'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        body: 'ids=' + encodeURIComponent('$id'),
        credentials: 'same-origin',
      });
      if (!res.ok) {
        alert('Delete failed: ' + (await res.text() || res.status));
        return;
      }
      window.location = '/';
    } catch (e) {
      alert('Delete failed: ' + e);
    }
  });
});
</script>
};
  }

  my $rows = '';
  for my $f ($files->@*) {
    my \%file = $f;
    $rows .= '<tr><td>' . _esc($file{relpath} // basename($file{path}))
      . '</td><td>' . _esc($file{role})
      . '</td><td>' . _esc($file{ext})
      . '</td><td>' . human_size($file{size_bytes})
      . '</td></tr>';
  }

  my $body = qq{
    <p><a href="/">&larr; library</a></p>
    <div class="detail">
      <div>$thumb</div>
      <div>
        <h1>} . _esc($it{name}) . qq{</h1>
        <p>
          <span class="badge">} . _esc($it{type}) . qq{</span>
          <span class="badge">} . _esc($it{kind}) . qq{</span>
          <span class="badge">} . _esc($it{status}) . qq{</span>
        </p>
        $actions
        <table>
          <tr><th>Path</th><td><code>} . _esc($it{path}) . qq{</code></td></tr>
          <tr><th>Source</th><td>}
            . _source_html($it{source_site}, $it{source_url}, $it{sources_json})
            . qq{</td></tr>
          <tr><th>DesignModelId</th><td>}
            . (
              $it{design_model_id}
                ? (
                    $it{source_url}
                      ? qq{<a href="} . _esc($it{source_url}) . qq{" target="_blank" rel="noopener noreferrer">}
                        . _esc($it{design_model_id}) . qq{</a>}
                      : _esc($it{design_model_id})
                  )
                : ''
              )
            . qq{</td></tr>
          <tr><th>Modified</th><td>} . _esc(fmt_time($it{mtime})) . qq{</td></tr>
          <tr><th>Size</th><td>} . human_size($it{size_bytes}) . qq{</td></tr>
          <tr><th>Files</th><td>} . ($it{file_count} // 0) . qq{</td></tr>
        </table>
        <h2>Description</h2>
        <pre class="desc">} . _linkify($it{description} // '') . qq{</pre>
};
  # Original CJK text is kept in DB (description_orig) but not shown in the UI
  $body .= qq{
        <h2>Files</h2>
        <table><tr><th>Path</th><th>Role</th><th>Ext</th><th>Size</th></tr>$rows</table>
      </div>
    </div>
  };
  return _html_wrap($it{name}, $body, $del_js, '', $role, $role_via);
}

sub _page_stl_viewer {
  my ($id, $rel, $role, $role_via) = @_;
  my $it = DB::get_item($id)
    or return _html_wrap('Missing', '<p>Not found</p>', '', '', $role, $role_via);
  my $url = "/file/$id";
  $url .= "?rel=" . uri_escape($rel) if defined $rel && length $rel;
  # if item is bare stl file
  if (($it->{type} // '') eq 'stl' && $it->{kind} eq 'file') {
    $url = "/file/$id";
  }
  my $extra = q{
<script type="importmap">
{
  "imports": {
    "three": "https://cdn.jsdelivr.net/npm/three@0.160.0/build/three.module.js",
    "three/addons/": "https://cdn.jsdelivr.net/npm/three@0.160.0/examples/jsm/"
  }
}
</script>
<script type="module">
import * as THREE from 'three';
import { OrbitControls } from 'three/addons/controls/OrbitControls.js';
import { STLLoader } from 'three/addons/loaders/STLLoader.js';

const el = document.getElementById('viewer');
const scene = new THREE.Scene();
scene.background = new THREE.Color(0xe8eef5);
const camera = new THREE.PerspectiveCamera(45, el.clientWidth/el.clientHeight, 0.1, 10000);
camera.position.set(0, 40, 80);
const renderer = new THREE.WebGLRenderer({ antialias: true });
renderer.setSize(el.clientWidth, el.clientHeight);
el.appendChild(renderer.domElement);
const controls = new OrbitControls(camera, renderer.domElement);
controls.enableDamping = true;
scene.add(new THREE.AmbientLight(0xffffff, 0.55));
const dir = new THREE.DirectionalLight(0xffffff, 0.85);
dir.position.set(50, 100, 40);
scene.add(dir);
scene.add(new THREE.GridHelper(100, 20, 0x2563eb, 0xc5d0e0));

const loader = new STLLoader();
const stlUrl = } . '"' . $url . '"' . q{;
loader.load(stlUrl, (geometry) => {
  geometry.center();
  geometry.computeVertexNormals();
  const mat = new THREE.MeshStandardMaterial({ color: 0x3d9cf0, metalness: 0.1, roughness: 0.55 });
  const mesh = new THREE.Mesh(geometry, mat);
  scene.add(mesh);
  geometry.computeBoundingSphere();
  const r = geometry.boundingSphere.radius || 20;
  camera.position.set(r*1.5, r*1.2, r*1.8);
  controls.target.set(0,0,0);
  controls.update();
}, undefined, (err) => {
  el.innerHTML = '<p style="padding:1rem;color:#f66">Failed to load STL</p>';
  console.error(err);
});
function animate() {
  requestAnimationFrame(animate);
  controls.update();
  renderer.render(scene, camera);
}
animate();
window.addEventListener('resize', () => {
  camera.aspect = el.clientWidth/el.clientHeight;
  camera.updateProjectionMatrix();
  renderer.setSize(el.clientWidth, el.clientHeight);
});
</script>
};
  my $body = qq{
    <p><a href="/item/$id">&larr; back</a></p>
    <h1>STL: } . _esc($it->{name}) . qq{</h1>
    <div id="viewer"></div>
  };
  return _html_wrap('STL viewer', $body, $extra, '', $role, $role_via);
}

1;
