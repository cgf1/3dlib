package Web;
use v5.40;
use utf8;    # source has em dash / ellipsis literals; encode_utf8 in _send
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
use Meta ();

sub serve {
  my (%o) = @_;
  my $cfg  = LibConfig::load_config();
  my $host = $o{bind} // $cfg->{bind} // '0.0.0.0';
  my $port = $o{port} // $cfg->{port} // 31353;

  # Make ps(1) show "/usr/local/bin/3dlib serve …" instead of
  # "/usr/bin/perl /usr/local/bin/3dlib serve …" (Linux $0 magic).
  _set_process_title('serve', '--bind', $host, '--port', $port);

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
  say "Ctrl-C to stop; SIGHUP or SIGQUIT (Ctrl-\\) reloads code (re-exec).";
  say "Note: for LAN family use only — do not port-forward to the internet.";

  # Reap children; HTTP::Daemon is single-threaded, so we fork per connection
  # so the browser can load many /thumb/N images in parallel.
  local $SIG{CHLD} = sub {
    1 while waitpid(-1, WNOHANG) > 0;
  };

  # SIGHUP / SIGQUIT → graceful re-exec (reload Perl code; same PID for OpenRC/systemd)
  my $restart = 0;
  my $restart_sig = '';
  my $request_restart = sub ($name) {
    $restart     = 1;
    $restart_sig = $name;
  };
  local $SIG{HUP}  = sub { $request_restart->('SIGHUP') };
  local $SIG{QUIT} = sub { $request_restart->('SIGQUIT') };

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
      local $SIG{HUP}  = 'DEFAULT';    # only the parent restarts
      local $SIG{QUIT} = 'DEFAULT';
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
    say(($restart_sig || 'signal') . ": restarting 3dlib serve...");
    eval { $d->close };
    # Drop children still finishing requests (they'll exit on their own)
    my $bin = $o{reexec} // $ENV{THREEDLIB_BIN} // '/usr/local/bin/3dlib';
    my @cmd = ($bin, 'serve', '--bind', $host, '--port', $port);
    exec @cmd or die "exec @cmd failed: $!\n";
  }
}

# Rewrite process title for ps/top (Linux updates /proc/self/cmdline via $0).
sub _set_process_title {
  my (@args) = @_;
  my $prog =
      (-x '/usr/local/bin/3dlib') ? '/usr/local/bin/3dlib'
    : (defined $0 && $0 =~ m{/3dlib(?:\z|\s)} ) ? (split /\s+/, $0, 2)[0]
    : '/usr/local/bin/3dlib';
  # Single string is what ps auwwwx displays as the command line.
  $0 = join(' ', $prog, @args);
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
  if ($path =~ m{^/item/(\d+)/edit$}) {
    my $id = $1;
    return _send($c, 403, 'text/html; charset=utf-8',
      _html_wrap('Forbidden', '<p>Admin only.</p><p><a href="/item/'
        . $id . '">Back</a></p>', '', '', $role, $role_via))
      unless WebAuth::can_edit($role);
    if ($r->method eq 'POST') {
      return _do_item_edit($c, $r, $id, $role, $role_via);
    }
    return _send($c, 200, 'text/html; charset=utf-8',
      _page_item_edit($id, $role, $role_via, $qp{err}));
  }
  if ($path =~ m{^/item/(\d+)$}) {
    return _send($c, 200, 'text/html; charset=utf-8',
      _page_item($1, $role, $role_via, $qp{saved}, $qp{flash}));
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
  if ($path eq '/settings') {
    return _send($c, 403, 'text/html; charset=utf-8',
      _html_wrap('Forbidden', '<p>Admin only.</p><p><a href="/">Back</a></p>', '', '', $role, $role_via))
      unless WebAuth::can_settings($role);
    if ($r->method eq 'POST') {
      return _do_settings_save($c, $r, $role, $role_via);
    }
    return _send($c, 200, 'text/html; charset=utf-8',
      _page_settings($role, $role_via, $qp{saved}, $qp{err}));
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
  # Open: default is desktop URL scheme (browser → xdg handler → 3dlib run).
  # mode=direct forces server-side launch (usually wrong for DISPLAY; kept for debugging).
  if ($path eq '/open' || $path eq '/api/open') {
    my %f = $r->method eq 'POST' ? _parse_form($r) : ();
    my $id   = $f{id}  // $qp{id}  or die "missing id\n";
    my $app  = $f{app} // $qp{app} // 'studio';
    my $mode = lc($f{mode} // $qp{mode} // 'url');
    if ($mode ne 'direct') {
      my $url = Meta::library_open_url(id => $id, app => $app);
      if (($qp{format} // $f{format} // '') eq 'json'
        || $r->method eq 'POST')
      {
        return _send($c, 200, 'application/json',
          JSON::PP->new->utf8->encode({
            ok      => 1,
            mode    => 'url',
            app     => $app,
            url     => $url,
            message => $app eq 'freecad'
              ? 'Opening FreeCAD via system handler'
              : 'Opening Bambu Studio via system handler',
          }));
      }
      return _send(
        $c, 302, 'text/html; charset=utf-8',
        qq{<a href="} . _esc($url) . qq{">Open</a>},
        extra_headers => { Location => $url },
      );
    }
    my $res = Run::run(target => $id, no_import => 1, app => $app);
    return _send($c, 200, 'application/json',
      JSON::PP->new->utf8->encode($res));
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
    # application/x-www-form-urlencoded: '+' is space
    for ($k, $v) {
      $_ //= '';
      tr/+/ /;
      $_ = uri_unescape($_);
    }
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

sub _secret_set {
  my ($v) = @_;
  return defined $v && length $v;
}

sub _do_settings_save {
  my ($c, $r, $role, $role_via) = @_;
  my %f = _parse_form($r);

  try {
    if (($f{mode} // 'form') eq 'raw') {
      _settings_save_raw($f{raw_json} // '');
    }
    else {
      _settings_save_form(%f);
    }
  }
  catch ($e) {
    $e =~ s/\s+\z//;
    return _send($c, 200, 'text/html; charset=utf-8',
      _page_settings($role, $role_via, 0, $e));
  }

  return _send(
    $c, 302, 'text/html; charset=utf-8',
    '<a href="/settings?saved=1">Saved</a>',
    extra_headers => { Location => '/settings?saved=1' },
  );
}

sub _settings_save_raw {
  my ($raw) = @_;
  $raw //= '';
  $raw =~ s/\r\n/\n/g;
  die "Raw JSON is empty\n" unless $raw =~ /\S/;
  my $j = eval { JSON::PP->new->decode($raw) };
  die "Invalid JSON: $@\n" if $@ || ref $j ne 'HASH';
  LibConfig::save_config($j);
}

# Config / form boolean (JSON::PP::Boolean, 0/1, true/false strings).
sub _as_bool {
  my ($v, $default) = @_;
  return $default if !defined $v;
  return 0 if ref($v) && !$v;
  return 1 if ref($v) && $v;
  return 0 if !ref($v) && $v =~ /^(0|false|no|off)$/i;
  return 1 if !ref($v) && $v =~ /^(1|true|yes|on)$/i;
  return $v ? 1 : 0;
}

sub _settings_save_form {
  my (%f) = @_;
  my $cfg = LibConfig::read_config_file();
  $cfg = {} unless ref $cfg eq 'HASH';

  for my $k (qw(library_root bambu_studio bind image_viewer freecad download_dir)) {
    next unless exists $f{$k};
    my $v = $f{$k} // '';
    $v =~ s/^\s+|\s+\z//g;
    if ($k eq 'image_viewer' || $k eq 'freecad' || $k eq 'download_dir') {
      if (length $v) {
        $cfg->{$k} = $v;
      }
      else {
        delete $cfg->{$k};
      }
      next;
    }
    die "$k cannot be empty\n" unless length $v;
    $cfg->{$k} = $v;
  }
  if (exists $f{freecad_shell_present}) {
    if ($f{freecad_shell}) {
      $cfg->{freecad_shell} = 1;
    }
    else {
      delete $cfg->{freecad_shell};
    }
  }
  if (exists $f{port}) {
    my $p = $f{port} // '';
    die "port must be a number 1–65535\n" unless $p =~ /^\d+$/ && $p >= 1 && $p <= 65535;
    $cfg->{port} = 0 + $p;
  }

  my $web = ref $cfg->{web} eq 'HASH' ? { $cfg->{web}->%* } : {};

  if ($f{clear_web_password}) {
    delete $web->{password};
  }
  elsif (defined $f{web_password} && length $f{web_password}) {
    $web->{password} = $f{web_password};
  }

  if ($f{clear_admin_password}) {
    delete $web->{admin_password};
  }
  elsif (defined $f{admin_password} && length $f{admin_password}) {
    $web->{admin_password} = $f{admin_password};
  }

  # Checkbox: absent when unchecked
  if (exists $f{local_admin_present}) {
    if ($f{local_admin}) {
      delete $web->{local_admin};    # default on — omit from file
    }
    else {
      $web->{local_admin} = 0;
    }
  }

  if (defined $f{session_days} && length $f{session_days}) {
    die "session_days must be a positive number\n"
      unless $f{session_days} =~ /^\d+$/ && $f{session_days} >= 1;
    $web->{session_days} = 0 + $f{session_days};
  }

  if (keys %$web) {
    $cfg->{web} = $web;
  }
  else {
    delete $cfg->{web};
  }

  my $tr = ref $cfg->{translate} eq 'HASH' ? { $cfg->{translate}->%* } : {};

  if (exists $f{translate_enabled_present}) {
    $tr->{enabled} = $f{translate_enabled} ? 1 : 0;
  }
  if (exists $f{translate_auto_import_present}) {
    $tr->{auto_import} = $f{translate_auto_import} ? 1 : 0;
  }

  if (defined $f{translate_provider} && length $f{translate_provider}) {
    my $p = lc $f{translate_provider};
    die "provider must be openai or xai\n" unless $p eq 'openai' || $p eq 'xai' || $p eq 'grok';
    $p = 'xai' if $p eq 'grok';
    $tr->{provider} = $p;
  }
  if (defined $f{translate_detect} && length $f{translate_detect}) {
    my $d = lc $f{translate_detect};
    die "detect must be auto or cjk\n" unless $d eq 'auto' || $d eq 'cjk';
    $tr->{detect} = $d;
  }
  for my $pair (
    [ translate_model => 'model' ],
    [ translate_api_key_env => 'api_key_env' ],
    [ translate_base_url => 'base_url' ],
  ) {
    my ($fk, $ck) = @$pair;
    next unless exists $f{$fk};
    my $v = $f{$fk} // '';
    $v =~ s/^\s+|\s+\z//g;
    if (length $v) {
      $tr->{$ck} = $v;
    }
    else {
      delete $tr->{$ck};
    }
  }
  if (defined $f{translate_timeout} && length $f{translate_timeout}) {
    die "timeout must be a positive number\n"
      unless $f{translate_timeout} =~ /^\d+$/ && $f{translate_timeout} >= 1;
    $tr->{timeout} = 0 + $f{translate_timeout};
  }

  if ($f{clear_translate_api_key}) {
    delete $tr->{api_key};
  }
  elsif (defined $f{translate_api_key} && length $f{translate_api_key}) {
    $tr->{api_key} = $f{translate_api_key};
  }

  if (keys %$tr) {
    $cfg->{translate} = $tr;
  }
  else {
    delete $cfg->{translate};
  }

  LibConfig::save_config($cfg);
}

sub _page_settings {
  my ($role, $role_via, $saved, $err) = @_;
  my $disk = LibConfig::read_config_file();
  my $eff  = LibConfig::load_config();
  my $path = LibConfig::load_config_path();

  my $web = ref $disk->{web} eq 'HASH' ? $disk->{web} : {};
  my $tr  = ref $disk->{translate} eq 'HASH' ? $disk->{translate} : {};
  # Effective translate defaults for display
  my $tr_eff = eval { Translate::config() } // {};

  # Default on when omitted from file
  my $local_on = exists $web->{local_admin} ? _as_bool($web->{local_admin}, 1) : 1;

  my $banner = '';
  if ($err) {
    $banner = qq{<div class="banner err">} . _esc($err) . qq{</div>};
  }
  elsif ($saved) {
    $banner = qq{<div class="banner ok">Settings saved to <code>}
      . _esc($path)
      . qq{</code>. Bind/port changes need a serve reload (SIGHUP/SIGQUIT or service reload). Web password and translation apply on the next request.</div>};
  }

  my $pw_fam = _secret_set($web->{password})
    ? '<span class="secret-state">Currently set — leave blank to keep</span>'
    : '<span class="secret-state">Not set</span>';
  my $pw_adm = _secret_set($web->{admin_password})
    ? '<span class="secret-state">Currently set — leave blank to keep</span>'
    : '<span class="secret-state">Not set</span>';
  my $api_set = _secret_set($tr->{api_key})
    ? '<span class="secret-state">Inline key is set — leave blank to keep</span>'
    : '<span class="secret-state">No inline key (env var may still apply)</span>';

  my $prov = $tr->{provider} // $tr_eff->{provider} // 'xai';
  my $sel_openai = $prov eq 'openai' ? ' selected' : '';
  my $sel_xai    = ($prov eq 'xai' || $prov eq 'grok') ? ' selected' : '';

  my $tr_en   = exists $tr->{enabled}     ? _as_bool($tr->{enabled}, 1)     : 1;
  my $tr_auto = exists $tr->{auto_import} ? _as_bool($tr->{auto_import}, 1) : 1;

  my $raw_pretty = eval {
    JSON::PP->new->pretty->canonical->encode($disk)
  } // "{}";

  my $session_days = $web->{session_days} // 14;

  my $body = qq{
<div class="settings">
  <p><a href="/">&larr; library</a></p>
  <h1>Settings</h1>
  <p class="muted">Edit <code>} . _esc($path) . qq{</code>. Admin only. Do not expose this service to the internet.</p>
  $banner

  <form method="post" action="/settings" autocomplete="off">
    <input type="hidden" name="mode" value="form"/>

    <fieldset>
      <legend>Library &amp; server</legend>
      <div class="row">
        <label class="field" for="library_root">library_root</label>
        <input type="text" id="library_root" name="library_root" value="}
          . _esc($disk->{library_root} // $eff->{library_root} // '') . qq{"/>
        <div class="hint">Model library path. Default /share/3d.</div>
      </div>
      <div class="row">
        <label class="field" for="download_dir">download_dir</label>
        <input type="text" id="download_dir" name="download_dir" value="}
          . _esc($disk->{download_dir} // $eff->{download_dir} // LibConfig::download_dir()) . qq{"/>
        <div class="hint">Non-3D zips are moved here (intact). Default /share/tmp. Env: THREEDLIB_DOWNLOAD_DIR.</div>
      </div>
      <div class="row">
        <label class="field" for="bambu_studio">bambu_studio</label>
        <input type="text" id="bambu_studio" name="bambu_studio" value="}
          . _esc($disk->{bambu_studio} // $eff->{bambu_studio} // '') . qq{"/>
        <div class="hint">Bambu Studio binary for Open in Studio. Env not used if set here.</div>
      </div>
      <div class="row">
        <label class="field" for="freecad">freecad</label>
        <input type="text" id="freecad" name="freecad" value="}
          . _esc($disk->{freecad} // $eff->{freecad} // LibConfig::freecad_cmd()) . qq{"/>
        <div class="hint">FreeCAD launch command. Examples: <code>freecad</code>, <code>ssh -Y tomoon freecad</code>, or with <code>{file}</code> placeholder. Env: THREEDLIB_FREECAD. Path must be reachable on the FreeCAD host (shared NFS, etc.).</div>
      </div>
      <input type="hidden" name="freecad_shell_present" value="1"/>
      <div class="checks">
        <label><input type="checkbox" name="freecad_shell" value="1"}
          . (_as_bool($disk->{freecad_shell} // $eff->{freecad_shell}, 0) ? ' checked' : '')
          . qq{/> freecad_shell — run via <code>/bin/sh -c</code> (complex ssh/quoting)</label>
      </div>
      <div class="row">
        <label class="field" for="image_viewer">image_viewer</label>
        <input type="text" id="image_viewer" name="image_viewer" value="}
          . _esc($disk->{image_viewer} // $eff->{image_viewer} // LibConfig::image_viewer()) . qq{"/>
        <div class="hint">CLI <code>3dlib show</code> thumbnail viewer (e.g. feh, feh -., imv). Env: THREEDLIB_IMAGE_VIEWER.</div>
      </div>
      <div class="row">
        <label class="field" for="bind">bind</label>
        <input type="text" id="bind" name="bind" value="}
          . _esc($disk->{bind} // $eff->{bind} // '0.0.0.0') . qq{"/>
        <div class="hint">Restart serve after changing bind or port.</div>
      </div>
      <div class="row">
        <label class="field" for="port">port</label>
        <input type="number" id="port" name="port" min="1" max="65535" value="}
          . _esc($disk->{port} // $eff->{port} // 31353) . qq{"/>
      </div>
    </fieldset>

    <fieldset>
      <legend>Web access</legend>
      <div class="row">
        <label class="field" for="web_password">Family password</label>
        <div>
          <input type="password" id="web_password" name="web_password" value="" placeholder="New password (optional)" autocomplete="new-password"/>
          $pw_fam
        </div>
      </div>
      <div class="checks">
        <label><input type="checkbox" name="clear_web_password" value="1"/> Clear family password</label>
      </div>
      <div class="row">
        <label class="field" for="admin_password">Admin password</label>
        <div>
          <input type="password" id="admin_password" name="admin_password" value="" placeholder="New password (optional)" autocomplete="new-password"/>
          $pw_adm
        </div>
      </div>
      <div class="checks">
        <label><input type="checkbox" name="clear_admin_password" value="1"/> Clear admin password</label>
      </div>
      <input type="hidden" name="local_admin_present" value="1"/>
      <div class="checks">
        <label><input type="checkbox" name="local_admin" value="1"}
          . ($local_on ? ' checked' : '')
          . qq{/> Local admin (same machine gets admin without login)</label>
      </div>
      <div class="row">
        <label class="field" for="session_days">Session days</label>
        <input type="number" id="session_days" name="session_days" min="1" max="365" value="}
          . _esc($session_days) . qq{"/>
      </div>
    </fieldset>

    <fieldset>
      <legend>Translation (OpenAI / Grok)</legend>
      <p class="muted" style="margin-top:0">Translates non-English descriptions (Chinese, German, French, …) to English. Originals stay in description_orig.</p>
      <input type="hidden" name="translate_enabled_present" value="1"/>
      <input type="hidden" name="translate_auto_import_present" value="1"/>
      <div class="checks">
        <label><input type="checkbox" name="translate_enabled" value="1"}
          . ($tr_en ? ' checked' : '')
          . qq{/> Enabled</label>
        <label><input type="checkbox" name="translate_auto_import" value="1"}
          . ($tr_auto ? ' checked' : '')
          . qq{/> Auto-translate on import</label>
      </div>
      <div class="row">
        <label class="field" for="translate_detect">Detect</label>
        <select id="translate_detect" name="translate_detect">
          <option value="auto"}
          . (($tr->{detect} // $tr_eff->{detect} // 'auto') ne 'cjk' ? ' selected' : '')
          . qq{>auto — any non-English (CJK, German, …)</option>
          <option value="cjk"}
          . (($tr->{detect} // '') eq 'cjk' ? ' selected' : '')
          . qq{>cjk — Chinese/Japanese/Korean only</option>
        </select>
      </div>
      <div class="row">
        <label class="field" for="translate_provider">Provider</label>
        <select id="translate_provider" name="translate_provider">
          <option value="xai"$sel_xai>xAI Grok</option>
          <option value="openai"$sel_openai>OpenAI</option>
        </select>
      </div>
      <div class="row">
        <label class="field" for="translate_model">Model</label>
        <input type="text" id="translate_model" name="translate_model" value="}
          . _esc($tr->{model} // $tr_eff->{model} // '') . qq{"/>
      </div>
      <div class="row">
        <label class="field" for="translate_api_key_env">API key env var</label>
        <input type="text" id="translate_api_key_env" name="translate_api_key_env" value="}
          . _esc($tr->{api_key_env} // $tr_eff->{api_key_env} // '') . qq{"/>
        <div class="hint">Preferred: put the key in the environment and name the variable here.</div>
      </div>
      <div class="row">
        <label class="field" for="translate_api_key">Inline API key</label>
        <div>
          <input type="password" id="translate_api_key" name="translate_api_key" value="" placeholder="New key (optional)" autocomplete="off"/>
          $api_set
        </div>
      </div>
      <div class="checks">
        <label><input type="checkbox" name="clear_translate_api_key" value="1"/> Clear inline API key</label>
      </div>
      <div class="row">
        <label class="field" for="translate_base_url">Base URL</label>
        <input type="text" id="translate_base_url" name="translate_base_url" value="}
          . _esc($tr->{base_url} // '') . qq{" placeholder="leave blank for provider default"/>
      </div>
      <div class="row">
        <label class="field" for="translate_timeout">Timeout (sec)</label>
        <input type="number" id="translate_timeout" name="translate_timeout" min="1" value="}
          . _esc($tr->{timeout} // $tr_eff->{timeout} // 120) . qq{"/>
      </div>
    </fieldset>

    <div class="actions">
      <button type="submit" class="btn">Save settings</button>
      <a class="btn secondary" href="/settings">Reset form</a>
    </div>
  </form>

  <details class="raw-json">
    <summary>Advanced: edit raw config.json</summary>
    <p class="muted">Replaces the entire file. Must be a JSON object. Invalid JSON is rejected.</p>
    <form method="post" action="/settings">
      <input type="hidden" name="mode" value="raw"/>
      <textarea name="raw_json" spellcheck="false">} . _esc($raw_pretty) . qq{</textarea>
      <div class="actions">
        <button type="submit" class="btn danger">Save raw JSON</button>
      </div>
    </form>
  </details>
</div>
};
  return _html_wrap('Settings', $body, '', '', $role, $role_via);
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
    .card .card-actions { display:flex; flex-wrap:wrap; gap:.35rem; padding:0 .75rem .75rem; }
    .card .card-actions .btn, .card .card-actions button {
      font-size:.75rem; padding:.3rem .5rem; flex:1 1 auto; text-align:center;
    }
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
    .settings { max-width:720px; }
    .settings h1 { margin-top:0; }
    .settings h2 { margin:1.5rem 0 .6rem; font-size:1.05rem; border-bottom:1px solid var(--border); padding-bottom:.35rem; }
    .settings fieldset { border:1px solid var(--border); border-radius:10px; background:#fff; padding:1rem 1.1rem 1.15rem; margin:0 0 1rem; }
    .settings legend { font-weight:600; padding:0 .35rem; }
    .settings .row { display:grid; grid-template-columns:180px 1fr; gap:.5rem 1rem; align-items:center; margin:.55rem 0; }
    @media (max-width:640px) { .settings .row { grid-template-columns:1fr; } }
    .settings label.field { font-size:.9rem; color:var(--muted); }
    .settings input[type=text], .settings input[type=password], .settings input[type=number], .settings select, .settings textarea {
      width:100%; max-width:100%;
    }
    .settings textarea { min-height:10rem; font-family:ui-monospace,monospace; font-size:.85rem; }
    .settings .hint { font-size:.8rem; color:var(--muted); grid-column:2; margin:-.25rem 0 .25rem; }
    @media (max-width:640px) { .settings .hint { grid-column:1; } }
    .settings .checks { display:flex; flex-wrap:wrap; gap:.75rem 1.25rem; margin:.4rem 0; }
    .settings .checks label { display:flex; gap:.4rem; align-items:center; font-size:.9rem; cursor:pointer; }
    .banner { padding:.7rem 1rem; border-radius:8px; margin:0 0 1rem; font-size:.92rem; }
    .banner.ok { background:#ecfdf5; color:#065f46; border:1px solid #a7f3d0; }
    .banner.err { background:#fef2f2; color:#991b1b; border:1px solid #fecaca; }
    .settings .secret-state { font-size:.8rem; color:var(--muted); }
    .settings .actions { margin-top:1rem; display:flex; gap:.5rem; flex-wrap:wrap; align-items:center; }
    details.raw-json { margin-top:1.5rem; background:#fff; border:1px solid var(--border); border-radius:10px; padding:.75rem 1rem; }
    details.raw-json summary { cursor:pointer; font-weight:600; }
  };
}

sub _header {
  my ($q, $role, $role_via) = @_;
  $q //= '';
  my $auth = '';
  my $nav  = '';
  if (WebAuth::can_settings($role)) {
    $nav = qq{<a href="/settings">Settings</a>};
  }
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
      $auth = qq{<div class="auth"><span class="muted">$label</span>$nav$logout</div>};
    }
    else {
      $auth = qq{<div class="auth">$nav<a href="/login">Login</a></div>};
    }
  }
  elsif ($nav) {
    $auth = qq{<div class="auth">$nav</div>};
  }
  return qq{
<header>
  <a href="/">3dlib</a>
  <span class="muted">/share/3d</span>
  $auth
  <form method="get" action="/">
    <input type="search" name="q" value="} . _esc($q) . qq{" placeholder="Search"/>
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
      tag   => $qp{tag},
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

    my $has_3mf = (($it{type} // '') eq '3mf');
    my $has_fc  = (($it{type} // '') eq 'fcstd');
    # Projects / mixed: peek is expensive; type badges are enough for gallery
    my $launch = '';
    if ($has_3mf) {
      my $u = _esc(Meta::library_open_url(id => $it{id}, app => 'studio'));
      $launch .= qq{<a class="btn secondary btn-launch" href="$u" data-app="studio" data-id="$it{id}" title="Open in Bambu Studio (desktop handler)">Studio</a>};
    }
    if ($has_fc) {
      my $u = _esc(Meta::library_open_url(id => $it{id}, app => 'freecad'));
      $launch .= qq{<a class="btn secondary btn-launch" href="$u" data-app="freecad" data-id="$it{id}" title="Open in FreeCAD (desktop handler)">FreeCAD</a>};
    }
    my $actions_html = length $launch
      ? qq{<div class="card-actions">$launch</div>}
      : '';

    $cards .= qq{
      <div class="card">
        $sel
        <a href="/item/$it{id}">
          $thumb
          <div class="meta">
            <div class="name" title="} . _esc($it{name}) . qq{">} . _esc($it{name}) . qq{</div>
            <div><span class="badge">} . _esc($it{type}) . qq{</span>
            <span class="badge">} . _esc($it{kind}) . qq{</span>}
            . (
              $it{tags} && $it{tags}->@*
                ? join('', map { qq{ <span class="badge">} . _esc($_) . qq{</span>} } $it{tags}->@*)
                : ''
              )
            . qq{</div>
            <div class="muted">} . _esc(fmt_time($it{mtime})) . qq{</div>
          </div>
        </a>
        $actions_html
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
    <div class="banner ok" id="gallery-flash" hidden></div>
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
    }
    . (
      $qp{tag}
        ? qq{ · tag: <strong>} . _esc($qp{tag}) . qq{</strong> <a href="/">clear</a>}
        : ''
    )
    . qq{
    </p>
    $bulk
    <div class="grid">$cards</div>
  };

  my $extra = '';
  if ($show_bulk && $items->@*) {
    $extra .= _bulk_js(can_download => $can_dl, can_delete => $can_del);
  }
  if ($items->@*) {
    $extra .= _launch_js();
  }
  return _html_wrap('Library', $filters, $extra, $qp{q}, $role, $role_via);
}

# Launch via custom URL schemes (desktop handlers run 3dlib with the user's
# session DISPLAY / xpra). Stay on the page and show a status banner.
sub _launch_js {
  return <<'JS';
<script>
document.addEventListener('DOMContentLoaded', () => {
  function flashEl() {
    return document.getElementById('gallery-flash')
        || document.getElementById('item-flash');
  }
  function showFlash(msg, isErr) {
    const flash = flashEl();
    if (!flash) {
      if (isErr) alert(msg);
      return;
    }
    flash.hidden = false;
    flash.textContent = msg;
    flash.className = 'banner ' + (isErr ? 'err' : 'ok');
  }
  document.querySelectorAll('a.btn-launch').forEach(a => {
    a.addEventListener('click', (e) => {
      // Let the browser hand the URL to the desktop (bambustudio:// / freecad://).
      // Prevent navigating the page away if the handler consumes it.
      e.stopPropagation();
      const app = a.dataset.app || 'studio';
      const label = app === 'freecad' ? 'FreeCAD' : 'Bambu Studio';
      showFlash('Opening ' + label + ' via system handler…');
      // Do not preventDefault — href must fire for the scheme handler.
    });
  });
});
</script>
JS
}

sub _page_item ($id, $role = undef, $role_via = undef, $saved = undef, $flash = undef) {
  my $row = DB::get_item($id)
    or return _html_wrap('Missing', '<p>Item not found</p>', '', '', $role, $role_via);
  my \%it = $row;
  my $files = DB::item_files($id);
  my ($tpath, $tmt) = _thumb_info($id, \%it);
  my $thumb = $tpath
    ? qq{<img class="big" src="/thumb/$id?v=$tmt" alt=""/>}
    : qq{<div class="ph" style="aspect-ratio:1;border-radius:10px">No thumbnail</div>};

  my $can_dl   = WebAuth::can_download($role);
  my $can_del  = WebAuth::can_delete($role);
  my $can_edit = WebAuth::can_edit($role);

  my $banner = '';
  if ($saved) {
    $banner = qq{<div class="banner ok" id="item-flash">Saved catalog changes.</div>};
  }
  elsif (defined $flash && length $flash) {
    $banner = qq{<div class="banner ok" id="item-flash">} . _esc($flash) . qq{</div>};
  }
  else {
    $banner = qq{<div class="banner ok" id="item-flash" hidden></div>};
  }

  my $has_3mf = (($it{type} // '') eq '3mf')
    || grep { my \%f = $_; ($f{ext} // '') eq '3mf' } $files->@*;
  my $has_fcstd = (($it{type} // '') eq 'fcstd')
    || grep { my \%f = $_; ($f{ext} // '') eq 'fcstd' || ($f{ext} // '') eq 'f3d' } $files->@*;

  my $actions = qq{<div class="actions">};
  if ($can_dl) {
    $actions .= qq{<a class="btn" href="/download/$id">Download</a>};
  }
  if ($can_edit) {
    $actions .= qq{<a class="btn secondary" href="/item/$id/edit">Edit</a>};
  }
  if ($has_3mf) {
    my $u = _esc(Meta::library_open_url(id => $id, app => 'studio'));
    $actions .= qq{<a class="btn secondary btn-launch" href="$u" data-app="studio" data-id="$id">Open in Bambu Studio</a>};
  }
  if ($has_fcstd) {
    my $u = _esc(Meta::library_open_url(id => $id, app => 'freecad'));
    $actions .= qq{<a class="btn secondary btn-launch" href="$u" data-app="freecad" data-id="$id">Open in FreeCAD</a>};
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

  my $item_js = <<"JS";
<script>
document.addEventListener('DOMContentLoaded', () => {
  const flash = document.getElementById('item-flash');
  function showFlash(msg, isErr) {
    if (!flash) return;
    flash.hidden = false;
    flash.textContent = msg;
    flash.className = 'banner ' + (isErr ? 'err' : 'ok');
  }
  document.querySelectorAll('.btn-launch').forEach(btn => {
    btn.addEventListener('click', async () => {
      const app = btn.dataset.app || 'studio';
      const id = btn.dataset.id;
      const label = app === 'freecad' ? 'FreeCAD' : 'Bambu Studio';
      btn.disabled = true;
      const prev = btn.textContent;
      btn.textContent = 'Launching...';
      try {
        const res = await fetch('/open', {
          method: 'POST',
          headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
          body: 'id=' + encodeURIComponent(id) + '&app=' + encodeURIComponent(app),
          credentials: 'same-origin',
        });
        const text = await res.text();
        let data = {};
        try { data = JSON.parse(text); } catch (_) {}
        if (!res.ok) {
          showFlash('Failed to launch ' + label + ': ' + (data.error || text || res.status), true);
          return;
        }
        showFlash(data.message || ('Launched ' + label));
      } catch (e) {
        showFlash('Failed to launch ' + label + ': ' + e, true);
      } finally {
        btn.disabled = false;
        btn.textContent = prev;
      }
    });
  });
JS
  if ($can_del) {
    $item_js .= <<"JS";
  const delBtn = document.getElementById('btn-del-one');
  if (delBtn) {
    delBtn.addEventListener('click', async () => {
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
  }
JS
  }
  $item_js .= <<'JS';
});
</script>
JS

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
    $banner
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
          <tr><th>Tags</th><td>}
            . (
              $it{tags} && $it{tags}->@*
                ? join(' ', map {
                    qq{<a class="badge" href="/?tag=} . uri_escape($_) . qq{">} . _esc($_) . qq{</a>}
                  } $it{tags}->@*)
                : '<span class="muted">—</span>'
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
  return _html_wrap($it{name}, $body, $item_js, '', $role, $role_via);
}

sub _extra_urls_text {
  my ($primary, $sources_json) = @_;
  my @extra;
  if ($sources_json) {
    my $list = eval { JSON::PP->new->decode($sources_json) };
    if (ref $list eq 'ARRAY') {
      for my $u ($list->@*) {
        next unless defined $u && $u =~ /\S/;
        next if $primary && $u eq $primary;
        push @extra, $u;
      }
    }
  }
  return join("\n", @extra);
}

sub _parse_url_lines {
  my ($text) = @_;
  $text //= '';
  $text =~ s/\r\n/\n/g;
  my @urls;
  my %seen;
  for my $line (split /\n/, $text) {
    $line =~ s/^\s+|\s+\z//g;
    next unless length $line;
    # Allow bare domains typed without scheme
    if ($line !~ m{^https?://}i && $line =~ /\./) {
      $line = "https://$line";
    }
    next unless $line =~ m{^https?://}i;
    next if $seen{$line}++;
    push @urls, $line;
  }
  return @urls;
}

sub _do_item_edit {
  my ($c, $r, $id, $role, $role_via) = @_;
  my %f = _parse_form($r);

  try {
    my $row = DB::get_item($id) or die "Item not found\n";

    my $name = $f{name} // '';
    $name =~ s/^\s+|\s+\z//g;
    die "Name is required\n" unless length $name;

    my $source_url = $f{source_url} // '';
    $source_url =~ s/^\s+|\s+\z//g;
    if (length $source_url && $source_url !~ m{^https?://}i) {
      $source_url = "https://$source_url";
    }
    if (length $source_url && $source_url !~ m{^https?://}i) {
      die "Primary URL must be http(s)\n";
    }

    my $source_site = $f{source_site} // '';
    $source_site =~ s/^\s+|\s+\z//g;
    my $source_id = $f{source_id} // '';
    $source_id =~ s/^\s+|\s+\z//g;
    my $design_model_id = $f{design_model_id} // '';
    $design_model_id =~ s/^\s+|\s+\z//g;

    my $auto = $f{auto_from_url} ? 1 : 0;
    if ($auto && length $source_url) {
      if (my $mw = Meta::parse_makerworld_url($source_url)) {
        $source_site = $mw->{source_site} if !length $source_site;
        $source_id   = $mw->{source_id}   if !length $source_id && $mw->{source_id};
        if (!length $design_model_id && $mw->{design_model_id}) {
          $design_model_id = $mw->{design_model_id};
        }
        # Prefer normalized public URL when we recognized MakerWorld
        $source_url = $mw->{source_url} if $mw->{source_url};
      }
      elsif (!length $source_site) {
        $source_site = Meta::classify_site($source_url) // '';
        $source_site = '' if ($source_site // '') eq 'other';
      }
      if (!length $source_id) {
        $source_id = Meta::_id_from_url($source_url) // '';
      }
    }

    my @extra = _parse_url_lines($f{extra_urls} // '');
    @extra = grep { !$source_url || $_ ne $source_url } @extra;

    my @all_urls;
    push @all_urls, $source_url if length $source_url;
    push @all_urls, @extra;
    my %seen;
    @all_urls = grep { !$seen{$_}++ } @all_urls;

    my $sources_json = @all_urls ? JSON::PP->new->encode(\@all_urls) : undef;

    my $status = $f{status} // $row->{status} // 'active';
    $status =~ s/^\s+|\s+\z//g;
    $status = 'active' unless length $status;
    # Allow custom statuses (e.g. unsorted) as well as the common ones
    die "Invalid status\n" if $status =~ /[^\w.-]/;

    my $description = $f{description} // '';
    # Keep description_orig untouched unless user edits the dedicated field
    my %upd = (
      name            => $name,
      description     => $description,
      source_url      => length $source_url ? $source_url : undef,
      source_site     => length $source_site ? $source_site : undef,
      source_id       => length $source_id ? $source_id : undef,
      design_model_id => length $design_model_id ? $design_model_id : undef,
      sources_json    => $sources_json,
      status          => $status,
    );

    if (exists $f{description_orig}) {
      my $orig = $f{description_orig} // '';
      $upd{description_orig} = length $orig ? $orig : undef;
    }

    DB::update_item_fields($id, \%upd);

    # Tags: comma/space separated list replaces all tags
    if (exists $f{tags}) {
      my @tags = DB::normalize_tags($f{tags} // '');
      DB::set_item_tags($id, @tags);
    }
  }
  catch ($e) {
    $e =~ s/\s+\z//;
    return _send($c, 200, 'text/html; charset=utf-8',
      _page_item_edit($id, $role, $role_via, $e, \%f));
  }

  return _send(
    $c, 302, 'text/html; charset=utf-8',
    qq{<a href="/item/$id?saved=1">Saved</a>},
    extra_headers => { Location => "/item/$id?saved=1" },
  );
}

sub _page_item_edit {
  my ($id, $role, $role_via, $err, $draft) = @_;
  my $row = DB::get_item($id)
    or return _html_wrap('Missing', '<p>Item not found</p>', '', '', $role, $role_via);

  # Prefer re-posted draft after validation error
  my $it = { $row->%* };
  if (ref $draft eq 'HASH') {
    for my $k (qw(name description source_url source_site source_id design_model_id status description_orig extra_urls)) {
      $it->{$k} = $draft->{$k} if exists $draft->{$k};
    }
  }

  my $extra_text = exists $it->{extra_urls}
    ? ($it->{extra_urls} // '')
    : _extra_urls_text($it->{source_url}, $it->{sources_json});

  my $banner = $err
    ? qq{<div class="banner err">} . _esc($err) . qq{</div>}
    : '';

  my $status = $it->{status} // 'active';
  my %status_opts = map { $_ => 1 } qw(active hidden archived unsorted);
  $status_opts{$status} = 1 if length $status;
  my $status_html = '';
  for my $s (sort keys %status_opts) {
    my $sel = $status eq $s ? ' selected' : '';
    $status_html .= qq{<option value="} . _esc($s) . qq{"$sel>} . _esc($s) . qq{</option>};
  }

  my $body = qq{
<div class="settings">
  <p><a href="/item/$id">&larr; back to item</a></p>
  <h1>Edit item #$id</h1>
  <p class="muted">Update catalog metadata (does not rename or move files on disk).</p>
  $banner

  <form method="post" action="/item/$id/edit" autocomplete="off">
    <fieldset>
      <legend>Identity</legend>
      <div class="row">
        <label class="field" for="name">Name</label>
        <input type="text" id="name" name="name" required value="} . _esc($it->{name} // '') . qq{"/>
      </div>
      <div class="row">
        <label class="field" for="status">Status</label>
        <select id="status" name="status">$status_html</select>
      </div>
      <div class="row">
        <label class="field">Path</label>
        <code>} . _esc($it->{path} // '') . qq{</code>
        <div class="hint">Path is fixed here; use CLI import/delete to move files.</div>
      </div>
    </fieldset>

    <fieldset>
      <legend>Source URLs</legend>
      <div class="row">
        <label class="field" for="source_url">Primary URL</label>
        <input type="text" id="source_url" name="source_url" value="}
          . _esc($it->{source_url} // '') . qq{" placeholder="https://makerworld.com/…"/>
        <div class="hint">Main link shown on the item page (MakerWorld, Printables, etc.).</div>
      </div>
      <div class="row">
        <label class="field" for="extra_urls">Additional URLs</label>
        <textarea id="extra_urls" name="extra_urls" rows="4" placeholder="One URL per line">}
          . _esc($extra_text) . qq{</textarea>
        <div class="hint">Extra sources stored with the item (one per line).</div>
      </div>
      <div class="checks">
        <label><input type="checkbox" name="auto_from_url" value="1" checked/>
          Auto-fill site / ids from primary URL when those fields are empty</label>
      </div>
      <div class="row">
        <label class="field" for="source_site">Source site</label>
        <input type="text" id="source_site" name="source_site" value="}
          . _esc($it->{source_site} // '') . qq{" placeholder="makerworld, printables, …"/>
      </div>
      <div class="row">
        <label class="field" for="source_id">Source id</label>
        <input type="text" id="source_id" name="source_id" value="}
          . _esc($it->{source_id} // '') . qq{"/>
      </div>
      <div class="row">
        <label class="field" for="design_model_id">DesignModelId</label>
        <input type="text" id="design_model_id" name="design_model_id" value="}
          . _esc($it->{design_model_id} // '') . qq{" placeholder="MakerWorld US… id"/>
      </div>
    </fieldset>

    <fieldset>
      <legend>Keywords / tags</legend>
      <div class="row">
        <label class="field" for="tags">Tags</label>
        <input type="text" id="tags" name="tags" value="}
          . _esc(
              join(', ',
                $it->{tags} && ref $it->{tags} eq 'ARRAY'
                  ? $it->{tags}->@*
                  : DB::get_item_tags($id)->@*)
            )
          . qq{" placeholder="clasp, jewelry, fidget"/>
        <div class="hint">Comma-separated. Catalog-only (Bambu 3MF files have no keyword field). Used by <code>ls --tag</code> and gallery filters.</div>
      </div>
    </fieldset>

    <fieldset>
      <legend>Description</legend>
      <div class="row">
        <label class="field" for="description">Description</label>
        <textarea id="description" name="description" rows="10">}
          . _esc($it->{description} // '') . qq{</textarea>
      </div>
      <div class="row">
        <label class="field" for="description_orig">Original (optional)</label>
        <textarea id="description_orig" name="description_orig" rows="4" placeholder="Chinese / original text kept for reference">}
          . _esc($it->{description_orig} // '') . qq{</textarea>
        <div class="hint">Not shown in the main UI unless THREEDLIB_SHOW_ORIGINAL is set.</div>
      </div>
    </fieldset>

    <div class="actions">
      <button type="submit" class="btn">Save changes</button>
      <a class="btn secondary" href="/item/$id">Cancel</a>
    </div>
  </form>
</div>
};
  return _html_wrap('Edit ' . ($it->{name} // $id), $body, '', '', $role, $role_via);
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
