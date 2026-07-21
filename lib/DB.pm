package DB;
use v5.40;
use experimental qw(class refaliasing declared_refs);
use DBI;
use File::Path qw(make_path);
use File::Basename qw(dirname);
use Util qw(now_ts);

my $dbh;

sub db_connect {
  my ($dbfile) = @_;
  $dbfile //= LibConfig::db_path();
  make_path(dirname($dbfile));
  $dbh = DBI->connect(
    "dbi:SQLite:dbname=$dbfile",
    undef, undef,
    {
      RaiseError     => 1,
      PrintError     => 0,
      sqlite_unicode => 1,
      AutoCommit     => 1,
    }
  );
  $dbh->do('PRAGMA foreign_keys = ON');
  $dbh->do('PRAGMA journal_mode = WAL');
  return $dbh;
}

# alias
sub connect { goto &db_connect }

# After fork(), the inherited DBI handle is not safe — open a fresh one.
sub reconnect {
  if ($dbh) {
    eval { $dbh->disconnect };
    $dbh = undef;
  }
  return db_connect();
}

sub dbh {
  $dbh = db_connect() unless $dbh;
  return $dbh;
}

sub init_schema {
  my $d = dbh();
  $d->do(q{
    CREATE TABLE IF NOT EXISTS items (
      id INTEGER PRIMARY KEY,
      kind TEXT NOT NULL,
      type TEXT NOT NULL,
      path TEXT NOT NULL UNIQUE,
      name TEXT NOT NULL,
      name_orig TEXT,
      description TEXT,
      source_site TEXT,
      source_url TEXT,
      source_id TEXT,
      sources_json TEXT,
      design_model_id TEXT,
      download_uuid TEXT,
      mtime INTEGER,
      atime INTEGER,
      size_bytes INTEGER,
      file_count INTEGER DEFAULT 1,
      content_hash TEXT,
      thumb_path TEXT,
      status TEXT DEFAULT 'active',
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL
    )
  });
  $d->do(q{
    CREATE TABLE IF NOT EXISTS files (
      id INTEGER PRIMARY KEY,
      item_id INTEGER NOT NULL REFERENCES items(id) ON DELETE CASCADE,
      path TEXT NOT NULL UNIQUE,
      relpath TEXT,
      ext TEXT,
      size_bytes INTEGER,
      mtime INTEGER,
      atime INTEGER,
      role TEXT,
      content_hash TEXT
    )
  });
  $d->do(q{
    CREATE TABLE IF NOT EXISTS rename_log (
      id INTEGER PRIMARY KEY,
      old_path TEXT NOT NULL,
      new_path TEXT NOT NULL,
      reason TEXT,
      ts INTEGER NOT NULL
    )
  });
  $d->do(q{
    CREATE TABLE IF NOT EXISTS import_log (
      id INTEGER PRIMARY KEY,
      source_path TEXT,
      dest_path TEXT,
      action TEXT,
      item_id INTEGER,
      detail TEXT,
      ts INTEGER NOT NULL
    )
  });
  $d->do('CREATE INDEX IF NOT EXISTS idx_items_type ON items(type)');
  $d->do('CREATE INDEX IF NOT EXISTS idx_items_hash ON items(content_hash)');
  $d->do('CREATE INDEX IF NOT EXISTS idx_items_design ON items(design_model_id)');
  $d->do('CREATE INDEX IF NOT EXISTS idx_items_mtime ON items(mtime)');
  $d->do('CREATE INDEX IF NOT EXISTS idx_files_item ON files(item_id)');

  # FTS
  my ($fts) = $d->selectrow_array(
    "SELECT name FROM sqlite_master WHERE type='table' AND name='items_fts'"
  );
  unless ($fts) {
    $d->do(q{
      CREATE VIRTUAL TABLE items_fts USING fts5(
        name, description, path, source_url,
        content='items', content_rowid='id'
      )
    });
    $d->do(q{
      CREATE TRIGGER IF NOT EXISTS items_ai AFTER INSERT ON items BEGIN
        INSERT INTO items_fts(rowid, name, description, path, source_url)
        VALUES (new.id, new.name, new.description, new.path, new.source_url);
      END
    });
    $d->do(q{
      CREATE TRIGGER IF NOT EXISTS items_ad AFTER DELETE ON items BEGIN
        INSERT INTO items_fts(items_fts, rowid, name, description, path, source_url)
        VALUES ('delete', old.id, old.name, old.description, old.path, old.source_url);
      END
    });
    $d->do(q{
      CREATE TRIGGER IF NOT EXISTS items_au AFTER UPDATE ON items BEGIN
        INSERT INTO items_fts(items_fts, rowid, name, description, path, source_url)
        VALUES ('delete', old.id, old.name, old.description, old.path, old.source_url);
        INSERT INTO items_fts(rowid, name, description, path, source_url)
        VALUES (new.id, new.name, new.description, new.path, new.source_url);
      END
    });
  }

  # Migrations for existing DBs
  _ensure_column($d, 'items', 'description_orig', 'TEXT');
  return 1;
}

sub _ensure_column {
  my ($d, $table, $col, $typedef) = @_;
  my $rows = $d->selectall_arrayref("PRAGMA table_info($table)");
  for my $r ($rows->@*) {
    return if ($r->[1] // '') eq $col;
  }
  $d->do("ALTER TABLE $table ADD COLUMN $col $typedef");
}

sub log_rename {
  my ($old, $new, $reason) = @_;
  dbh()->do(
    'INSERT INTO rename_log(old_path, new_path, reason, ts) VALUES (?,?,?,?)',
    undef, $old, $new, $reason // '', now_ts()
  );
  my $log = LibConfig::library_root() . '/.library/renames.jsonl';
  Util::append_log($log, sprintf('{"ts":%d,"old":%s,"new":%s,"reason":%s}',
    now_ts(), _jstr($old), _jstr($new), _jstr($reason // '')));
}

sub log_import {
  my (%o) = @_;
  dbh()->do(
    'INSERT INTO import_log(source_path, dest_path, action, item_id, detail, ts)
     VALUES (?,?,?,?,?,?)',
    undef,
    $o{source}, $o{dest}, $o{action}, $o{item_id}, $o{detail}, now_ts()
  );
}

sub _jstr {
  my ($s) = @_;
  $s //= '';
  $s =~ s/\\/\\\\/g;
  $s =~ s/"/\\"/g;
  return "\"$s\"";
}

sub find_by_hash {
  my ($hash) = @_;
  return unless $hash;
  return dbh()->selectrow_hashref(
    'SELECT * FROM items WHERE content_hash = ? LIMIT 1', undef, $hash
  );
}

sub find_by_design_id {
  my ($id) = @_;
  return unless $id;
  return dbh()->selectrow_hashref(
    'SELECT * FROM items WHERE design_model_id = ? LIMIT 1', undef, $id
  );
}

sub find_by_path {
  my ($path) = @_;
  return dbh()->selectrow_hashref(
    'SELECT * FROM items WHERE path = ?', undef, $path
  );
}

sub get_item {
  my ($id) = @_;
  return dbh()->selectrow_hashref('SELECT * FROM items WHERE id = ?', undef, $id);
}

sub delete_item {
  my ($id) = @_;
  my $d = dbh();
  # files table cascades via FK when supported; delete explicitly for safety
  $d->do('DELETE FROM files WHERE item_id = ?', undef, $id);
  my $n = $d->do('DELETE FROM items WHERE id = ?', undef, $id);
  return $n;
}

sub item_files {
  my ($id) = @_;
  return dbh()->selectall_arrayref(
    'SELECT * FROM files WHERE item_id = ? ORDER BY relpath, path',
    { Slice => {} }, $id
  );
}

sub upsert_item {
  my ($row) = @_;
  require Util;
  # Ensure Unicode text fields are real characters, not mojibake byte-as-latin1
  for my $k (qw(path name name_orig description description_orig source_url source_id designer)) {
    $row->{$k} = Util::text_for_db($row->{$k}) if defined $row->{$k};
  }
  my $d  = dbh();
  my $ts = now_ts();
  my $existing = find_by_path($row->{path});
  if ($existing) {
    $d->do(
      q{
        UPDATE items SET
          kind=?, type=?, name=?, name_orig=?, description=?, description_orig=?,
          source_site=?, source_url=?, source_id=?, sources_json=?,
          design_model_id=?, download_uuid=?,
          mtime=?, atime=?, size_bytes=?, file_count=?,
          content_hash=?, thumb_path=COALESCE(?, thumb_path),
          status=?, updated_at=?
        WHERE id=?
      },
      undef,
      $row->{kind}, $row->{type}, $row->{name}, $row->{name_orig},
      $row->{description}, $row->{description_orig},
      $row->{source_site}, $row->{source_url}, $row->{source_id},
      $row->{sources_json},
      $row->{design_model_id}, $row->{download_uuid},
      $row->{mtime}, $row->{atime}, $row->{size_bytes}, $row->{file_count} // 1,
      $row->{content_hash}, $row->{thumb_path},
      $row->{status} // 'active', $ts, $existing->{id}
    );
    return $existing->{id};
  }
  $d->do(
    q{
      INSERT INTO items(
        kind, type, path, name, name_orig, description, description_orig,
        source_site, source_url, source_id, sources_json,
        design_model_id, download_uuid,
        mtime, atime, size_bytes, file_count, content_hash, thumb_path,
        status, created_at, updated_at
      ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
    },
    undef,
    $row->{kind}, $row->{type}, $row->{path}, $row->{name}, $row->{name_orig},
    $row->{description}, $row->{description_orig},
    $row->{source_site}, $row->{source_url}, $row->{source_id},
    $row->{sources_json},
    $row->{design_model_id}, $row->{download_uuid},
    $row->{mtime}, $row->{atime}, $row->{size_bytes}, $row->{file_count} // 1,
    $row->{content_hash}, $row->{thumb_path},
    $row->{status} // 'active', $ts, $ts
  );
  return $d->sqlite_last_insert_rowid;
}

sub replace_files {
  my ($item_id, $files) = @_;
  my $d = dbh();
  $d->do('DELETE FROM files WHERE item_id = ?', undef, $item_id);
  for my $f (@$files) {
    $d->do(
      q{
        INSERT INTO files(item_id, path, relpath, ext, size_bytes, mtime, atime, role, content_hash)
        VALUES (?,?,?,?,?,?,?,?,?)
      },
      undef,
      $item_id, $f->{path}, $f->{relpath}, $f->{ext},
      $f->{size_bytes}, $f->{mtime}, $f->{atime}, $f->{role}, $f->{content_hash}
    );
  }
}

sub search {
  my ($q, $limit) = @_;
  $limit //= 50;
  my $d = dbh();
  if ($q && $q =~ /\S/) {
    my $fts = $q;
    $fts =~ s/"//g;
    return $d->selectall_arrayref(
      q{
        SELECT items.* FROM items_fts
        JOIN items ON items.id = items_fts.rowid
        WHERE items_fts MATCH ?
        ORDER BY items.mtime DESC
        LIMIT ?
      },
      { Slice => {} }, $fts, $limit
    );
  }
  return $d->selectall_arrayref(
    'SELECT * FROM items ORDER BY mtime DESC LIMIT ?',
    { Slice => {} }, $limit
  );
}

sub list_items {
  my (%o) = @_;
  my @w;
  my @b;
  if ($o{type}) {
    push @w, 'type = ?';
    push @b, $o{type};
  }
  if ($o{kind}) {
    push @w, 'kind = ?';
    push @b, $o{kind};
  }
  if ($o{status}) {
    push @w, 'status = ?';
    push @b, $o{status};
  }
  if ($o{no_thumb}) {
    push @w, "(thumb_path IS NULL OR thumb_path = '')";
  }
  if ($o{no_source}) {
    push @w, "(source_url IS NULL OR source_url = '')";
  }
  my $where = @w ? ('WHERE ' . join(' AND ', @w)) : '';
  my $limit = $o{limit} // 200;
  my $sql   = "SELECT * FROM items $where ORDER BY mtime DESC LIMIT ?";
  push @b, $limit;
  return dbh()->selectall_arrayref($sql, { Slice => {} }, @b);
}

sub stats {
  my $d = dbh();
  my $total = $d->selectrow_array('SELECT COUNT(*) FROM items');
  my $by_type = $d->selectall_arrayref(
    'SELECT type, COUNT(*) c FROM items GROUP BY type ORDER BY c DESC',
    { Slice => {} }
  );
  my $by_kind = $d->selectall_arrayref(
    'SELECT kind, COUNT(*) c FROM items GROUP BY kind',
    { Slice => {} }
  );
  my $no_thumb = $d->selectrow_array(
    "SELECT COUNT(*) FROM items WHERE thumb_path IS NULL OR thumb_path = ''"
  );
  my $no_src = $d->selectrow_array(
    "SELECT COUNT(*) FROM items WHERE source_url IS NULL OR source_url = ''"
  );
  return {
    total    => $total,
    by_type  => $by_type,
    by_kind  => $by_kind,
    no_thumb => $no_thumb,
    no_source => $no_src,
  };
}

1;
