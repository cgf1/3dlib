package WebAuth;
use v5.40;
use experimental qw(class refaliasing declared_refs);
use Digest::SHA qw(hmac_sha256_hex sha256_hex);
use MIME::Base64 qw(encode_base64 decode_base64);
use LibConfig ();

# Optional LAN password gate. Not a substitute for keeping this off the public internet.
# Connections from this machine (loopback / own IPs) are treated as admin by default.

sub web_cfg {
  my $cfg = LibConfig::load_config();
  my $w   = $cfg->{web} // {};
  $w = {} unless ref $w eq 'HASH';
  my $password = $w->{password} // $ENV{THREEDLIB_WEB_PASSWORD};
  my $admin    = $w->{admin_password} // $ENV{THREEDLIB_WEB_ADMIN_PASSWORD};
  my $secret   = $w->{secret} // $ENV{THREEDLIB_WEB_SECRET}
    // sha256_hex(($password // '') . '|' . ($admin // '') . '|' . LibConfig::library_root());
  return {
    password       => $password,
    admin_password => $admin,
    secret         => $secret,
    cookie_name    => $w->{cookie_name} // '3dlib_session',
    max_age        => $w->{session_days} ? int($w->{session_days}) * 86400 : 14 * 86400,
    # Local (same-host) peers get admin without a password (default on).
    local_admin    => $w->{local_admin} // $ENV{THREEDLIB_WEB_LOCAL_ADMIN},
  };
}

sub auth_enabled {
  my $c = web_cfg();
  return defined $c->{password} && length $c->{password};
}

sub admin_password_set {
  my $c = web_cfg();
  return defined $c->{admin_password} && length $c->{admin_password};
}

# Default on. Set web.local_admin=false or THREEDLIB_WEB_LOCAL_ADMIN=0 to disable.
sub local_admin_enabled {
  my $c = web_cfg();
  my $v = $c->{local_admin};
  return 0 if defined $v && $v =~ /^(0|false|no|off)$/i;
  return 1;
}

# Returns role: 'admin' | 'user' | undef
sub check_password {
  my ($pass) = @_;
  my $c = web_cfg();
  return unless defined $pass;
  if (admin_password_set() && _const_eq($pass, $c->{admin_password})) {
    return 'admin';
  }
  if (auth_enabled() && _const_eq($pass, $c->{password})) {
    # If no separate admin password, login is full access (admin)
    return admin_password_set() ? 'user' : 'admin';
  }
  # Admin-only mode: only admin_password configured, no public password
  if (!auth_enabled() && admin_password_set() && _const_eq($pass, $c->{admin_password})) {
    return 'admin';
  }
  return;
}

sub _const_eq {
  my ($a, $b) = @_;
  return 0 unless defined $a && defined $b;
  return 0 unless length($a) == length($b);
  my $r = 0;
  $r |= ord(substr($a, $_, 1)) ^ ord(substr($b, $_, 1)) for 0 .. length($a) - 1;
  return $r == 0;
}

sub make_token {
  my ($role) = @_;
  my $c   = web_cfg();
  my $exp = time + $c->{max_age};
  my $payload = "$exp:$role";
  my $sig = hmac_sha256_hex($payload, $c->{secret});
  my $raw = encode_base64("$payload:$sig", '');
  $raw =~ tr{+/}{-_};
  $raw =~ s/=+$//;
  return $raw;
}

sub parse_token {
  my ($token) = @_;
  return unless defined $token && length $token;
  my $c = web_cfg();
  my $b64 = $token;
  $b64 =~ tr{-_}{+/};
  $b64 .= '=' x ((4 - length($b64) % 4) % 4);
  my $raw = eval { decode_base64($b64) };
  return unless defined $raw && $raw =~ /^(\d+):(admin|user):([0-9a-f]+)$/;
  my ($exp, $role, $sig) = ($1, $2, $3);
  return if time > $exp;
  my $payload = "$exp:$role";
  my $expect  = hmac_sha256_hex($payload, $c->{secret});
  return unless _const_eq($sig, $expect);
  return $role;
}

sub session_from_request {
  my ($r) = @_;
  my $c    = web_cfg();
  my $name = $c->{cookie_name};
  my $cookie = $r->header('Cookie') // '';
  for my $part (split /;\s*/, $cookie) {
    my ($k, $v) = split /=/, $part, 2;
    next unless defined $k && $k eq $name;
    return parse_token($v);
  }
  return;
}

# TCP peer address of the HTTP client connection (not X-Forwarded-For).
sub peer_ip {
  my ($conn) = @_;
  return unless $conn;
  my $ip = eval { $conn->peerhost };
  return unless defined $ip && length $ip;
  # Normalize IPv4-mapped IPv6
  $ip =~ s/^::ffff://i;
  return $ip;
}

sub is_loopback_ip {
  my ($ip) = @_;
  return 0 unless defined $ip && length $ip;
  return 1 if $ip eq '127.0.0.1' || $ip eq '::1' || lc($ip) eq 'localhost';
  return 1 if $ip =~ /^127\.\d+\.\d+\.\d+\z/;    # 127.0.0.0/8
  return 0;
}

# Cache this host's interface addresses (loopback + LAN IPs).
sub _own_ips {
  state $cache = do {
    my %ips = (
      '127.0.0.1' => 1,
      '::1'       => 1,
    );
    if (open my $ip_fh, '-|', 'ip', '-o', 'addr', 'show') {
      while (my $line = <$ip_fh>) {
        # "2: eth0    inet 192.168.1.10/24 ..."
        if ($line =~ /\binet6?\s+([0-9a-fA-F:.]+)/) {
          my $a = $1;
          $a =~ s/^::ffff://i;
          $ips{$a} = 1 if length $a;
        }
      }
      close $ip_fh;
    }
    elsif (open my $hn_fh, '-|', 'hostname', '-I') {
      local $/;
      my $raw = <$hn_fh> // '';
      close $hn_fh;
      for my $a (split /\s+/, $raw) {
        $a =~ s/^::ffff://i;
        $ips{$a} = 1 if length $a;
      }
    }
    \%ips;
  };
  return $cache;
}

# True if the peer is this machine (loopback or one of our interface IPs).
sub is_local_peer {
  my ($ip) = @_;
  return 0 unless defined $ip && length $ip;
  return 1 if is_loopback_ip($ip);
  return 1 if _own_ips()->{$ip};
  return 0;
}

# Resolve effective role from cookie + peer address.
# Localhost / same-host peers get 'admin' when local_admin is enabled (default).
# Cookie role is still used for remote clients; local always wins as admin.
# Returns ($role, $via) where $via is 'local' | 'cookie' | undef.
sub role_for {
  my ($conn, $r) = @_;
  if (local_admin_enabled()) {
    my $ip = peer_ip($conn);
    if ($ip && is_local_peer($ip)) {
      return ('admin', 'local');
    }
  }
  my $role = session_from_request($r);
  return ($role, defined $role ? 'cookie' : undef);
}

sub set_cookie_header {
  my ($token) = @_;
  my $c = web_cfg();
  my $max = $c->{max_age};
  return sprintf(
    '%s=%s; Path=/; HttpOnly; SameSite=Lax; Max-Age=%d',
    $c->{cookie_name}, $token, $max
  );
}

sub clear_cookie_header {
  my $c = web_cfg();
  return sprintf('%s=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0', $c->{cookie_name});
}

# When auth is enabled, anonymous users must log in.
# When only admin_password is set, browsing is open but delete needs admin.
# Local admin (same-host) always satisfies the login gate.
sub require_login {
  my ($role) = @_;
  return 1 unless auth_enabled();
  return defined $role;
}

sub can_delete {
  my ($role) = @_;
  return 0 unless defined $role;
  return 1 if $role eq 'admin';
  # No separate admin password → user session can delete
  return 1 if $role eq 'user' && !admin_password_set();
  return 0;
}

sub can_download {
  my ($role) = @_;
  # Open browse when no site password; otherwise need login
  return 1 unless auth_enabled();
  return defined $role;
}

1;
