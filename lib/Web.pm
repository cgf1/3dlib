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
use LibConfig ();
use DB ();
use Util qw(human_size fmt_time path_ext);
use Run ();

sub serve {
  my (%o) = @_;
  my $cfg  = LibConfig::load_config();
  my $host = $o{bind} // $cfg->{bind} // '0.0.0.0';
  my $port = $o{port} // $cfg->{port} // 31353;

  my $d = HTTP::Daemon->new(
    LocalAddr => $host,
    LocalPort => $port,
    ReuseAddr => 1,
  ) or die "Cannot bind $host:$port: $!\n";

  say "3dlib web: http://$host:$port/";
  say "Library: ", LibConfig::library_root();
  say "Ctrl-C to stop.";

  while (my $c = $d->accept) {
    while (my $r = $c->get_request) {
      try {
        _handle($c, $r);
      }
      catch ($e) {
        warn "request error: $e";
        _send($c, 500, 'text/plain', "Error: $e");
      }
    }
    $c->close;
    undef $c;
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

  if ($path eq '/' || $path eq '') {
    return _send($c, 200, 'text/html; charset=utf-8', _page_home(%qp));
  }
  if ($path =~ m{^/item/(\d+)$}) {
    return _send($c, 200, 'text/html; charset=utf-8', _page_item($1));
  }
  if ($path =~ m{^/thumb/(\d+)$}) {
    return _send_thumb($c, $1);
  }
  if ($path =~ m{^/file/(\d+)$}) {
    return _send_item_file($c, $1, $qp{rel});
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
    my $body = $r->content // '';
    my %f = map {
      my ($k, $v) = split /=/, $_, 2;
      uri_unescape($k // '') => uri_unescape($v // '')
    } split /&/, $body;
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
        . _esc(JSON::PP->new->canonical->encode($res)) . '</pre>'));
  }
  if ($path eq '/stl-viewer') {
    return _send($c, 200, 'text/html; charset=utf-8', _page_stl_viewer($qp{id}, $qp{rel}));
  }
  _send($c, 404, 'text/plain', 'Not found');
}

sub _send {
  my ($c, $code, $ctype, $body) = @_;
  my $res = HTTP::Response->new($code);
  $res->header('Content-Type' => $ctype);
  $res->header('Cache-Control' => 'no-cache');
  $res->content(Encode::encode_utf8($body));
  $c->send_response($res);
}

sub _send_thumb {
  my ($c, $id) = @_;
  my $item = DB::get_item($id);
  unless ($item && $item->{thumb_path} && -f $item->{thumb_path}) {
    # 1x1 png
    return _send($c, 404, 'text/plain', 'no thumb');
  }
  open my $fh, '<:raw', $item->{thumb_path} or die $!;
  local $/;
  my $data = <$fh>;
  close $fh;
  my $res = HTTP::Response->new(200);
  $res->header('Content-Type' => 'image/png');
  $res->content($data);
  $c->send_response($res);
}

sub _send_item_file {
  my ($c, $id, $rel) = @_;
  my $item = DB::get_item($id) or die "no item\n";
  my $path;
  if ($rel) {
    $path = $item->{path} . '/' . $rel;
    # prevent escape
    my $root = $item->{path};
    require Cwd;
    my $ap = Cwd::abs_path($path);
    my $ar = Cwd::abs_path($root);
    die "bad path\n" unless $ap && $ar && index($ap, $ar) == 0;
  }
  else {
    $path = $item->{path};
  }
  die "missing file\n" unless -f $path;
  open my $fh, '<:raw', $path or die $!;
  local $/;
  my $data = <$fh>;
  close $fh;
  my $ext = path_ext($path);
  my $ctype = 'application/octet-stream';
  $ctype = 'model/stl' if $ext eq 'stl';
  $ctype = 'model/3mf' if $ext eq '3mf';
  $ctype = 'image/png' if $ext eq 'png';
  $ctype = 'image/jpeg' if $ext =~ /^jpe?g$/;
  my $res = HTTP::Response->new(200);
  $res->header('Content-Type' => $ctype);
  $res->header('Content-Disposition' => 'inline; filename="' . basename($path) . '"');
  $res->content($data);
  $c->send_response($res);
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

sub _css {
  return q{
    :root { --bg:#0f1419; --card:#1a2332; --fg:#e7ecf3; --muted:#8b9bb4; --acc:#3d9cf0; --ok:#3ecf8e; }
    * { box-sizing: border-box; }
    body { margin:0; font-family: system-ui, sans-serif; background:var(--bg); color:var(--fg); }
    header { padding:1rem 1.5rem; border-bottom:1px solid #243044; display:flex; gap:1rem; align-items:center; flex-wrap:wrap; }
    header a { color:var(--acc); text-decoration:none; font-weight:600; }
    header form { margin-left:auto; display:flex; gap:.5rem; }
    input, select, button { background:#0b1018; color:var(--fg); border:1px solid #2a3a52; border-radius:6px; padding:.4rem .7rem; }
    button, .btn { background:var(--acc); color:#fff; border:none; cursor:pointer; text-decoration:none; display:inline-block; border-radius:6px; padding:.45rem .8rem; }
    .btn.secondary { background:#2a3a52; }
    main { padding:1.25rem; }
    .grid { display:grid; grid-template-columns:repeat(auto-fill,minmax(180px,1fr)); gap:1rem; }
    .card { background:var(--card); border-radius:10px; overflow:hidden; border:1px solid #243044; transition:.15s; }
    .card:hover { border-color:var(--acc); transform:translateY(-2px); }
    .card a { color:inherit; text-decoration:none; }
    .card img { width:100%; aspect-ratio:1; object-fit:cover; background:#0b1018; display:block; }
    .card .ph { width:100%; aspect-ratio:1; display:flex; align-items:center; justify-content:center; background:#0b1018; color:var(--muted); font-size:.85rem; }
    .card .meta { padding:.6rem .75rem .8rem; }
    .card .name { font-weight:600; font-size:.92rem; white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }
    .badge { display:inline-block; font-size:.7rem; padding:.1rem .4rem; border-radius:4px; background:#2a3a52; color:var(--muted); text-transform:uppercase; }
    .muted { color:var(--muted); font-size:.8rem; }
    .detail { display:grid; grid-template-columns:280px 1fr; gap:1.5rem; }
    @media (max-width:800px) { .detail { grid-template-columns:1fr; } }
    .detail img.big { width:100%; border-radius:10px; background:#0b1018; }
    table { width:100%; border-collapse:collapse; }
    td, th { text-align:left; padding:.4rem .5rem; border-bottom:1px solid #243044; font-size:.9rem; }
    pre { background:#0b1018; padding:1rem; border-radius:8px; overflow:auto; white-space:pre-wrap; }
    .actions { display:flex; gap:.5rem; flex-wrap:wrap; margin:1rem 0; }
    #viewer { width:100%; height:480px; background:#0b1018; border-radius:10px; }
  };
}

sub _header {
  my ($q) = @_;
  $q //= '';
  return qq{
<header>
  <a href="/">3dlib</a>
  <span class="muted">/share/3d</span>
  <form method="get" action="/">
    <input type="search" name="q" value="} . _esc($q) . qq{" placeholder="Search…"/>
    <button type="submit">Search</button>
  </form>
</header>
};
}

sub _html_wrap {
  my ($title, $body, $extra_head, $q) = @_;
  $extra_head //= '';
  return qq{<!DOCTYPE html>
<html lang="en"><head>
<meta charset="utf-8"/>
<meta name="viewport" content="width=device-width, initial-scale=1"/>
<title>} . _esc($title) . qq{ - 3dlib</title>
<style>} . _css() . qq{</style>
$extra_head
</head><body>
} . _header($q) . qq{
<main>$body</main>
</body></html>};
}

sub _page_home {
  my (%qp) = @_;
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
  my $st = DB::stats();
  my $cards = '';
  for my $row ($items->@*) {
    my \%it = $row;
    my $thumb = $it{thumb_path} && -f $it{thumb_path}
      ? qq{<img src="/thumb/$it{id}" alt=""/>}
      : qq{<div class="ph">} . _esc(uc($it{type} // '?')) . qq{</div>};
    $cards .= qq{
      <div class="card">
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
    <div class="grid">$cards</div>
  };
  return _html_wrap('Library', $filters, '', $qp{q});
}

sub _page_item ($id) {
  my $row = DB::get_item($id) or return _html_wrap('Missing', '<p>Item not found</p>');
  my \%it = $row;
  my $files = DB::item_files($id);
  my $thumb = $it{thumb_path} && -f $it{thumb_path}
    ? qq{<img class="big" src="/thumb/$id" alt=""/>}
    : qq{<div class="ph" style="aspect-ratio:1;border-radius:10px">No thumbnail</div>};

  my $actions = qq{<div class="actions">};
  if (($it{type} // '') eq '3mf' || grep { my \%f = $_; ($f{ext} // '') eq '3mf' } $files->@*) {
    $actions .= qq{<a class="btn" href="/open?id=$id">Open in Bambu Studio</a>};
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
  $actions .= qq{</div>};

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
          <tr><th>Original name</th><td>} . _esc($it{name_orig} // '') . qq{</td></tr>
          <tr><th>Source</th><td>} . _esc($it{source_site} // '') . ' '
            . ($it{source_url} ? qq{<a href="}._esc($it{source_url}).qq{">}._esc($it{source_url}).qq{</a>} : '')
            . qq{</td></tr>
          <tr><th>DesignModelId</th><td>} . _esc($it{design_model_id} // '') . qq{</td></tr>
          <tr><th>Modified</th><td>} . _esc(fmt_time($it{mtime})) . qq{</td></tr>
          <tr><th>Size</th><td>} . human_size($it{size_bytes}) . qq{</td></tr>
          <tr><th>Files</th><td>} . ($it{file_count} // 0) . qq{</td></tr>
        </table>
        <h2>Description</h2>
        <pre>} . _esc($it{description} // '') . qq{</pre>
        <h2>Files</h2>
        <table><tr><th>Path</th><th>Role</th><th>Ext</th><th>Size</th></tr>$rows</table>
      </div>
    </div>
  };
  return _html_wrap($it{name}, $body);
}

sub _page_stl_viewer {
  my ($id, $rel) = @_;
  my $it = DB::get_item($id) or return _html_wrap('Missing', '<p>Not found</p>');
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
scene.background = new THREE.Color(0x0b1018);
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
scene.add(new THREE.GridHelper(100, 20, 0x3d9cf0, 0x243044));

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
  return _html_wrap('STL viewer', $body, $extra);
}

1;
