# 3dlib

Personal 3D model library manager for `/share/3d`.

## Layout

```text
/usr/local/3dlib/          # this git project
  bin/3dlib                # CLI
  lib/*.pm                 # Perl modules
  man/3dlib.1              # man page (keep in sync with CLI)
  share/applications/      # desktop entry template

/usr/local/bin/3dlib                    -> bin/3dlib
/usr/local/share/man/man1/3dlib.1       -> man/3dlib.1
/usr/local/lib/3dlib                    -> lib/   (optional convenience)

/share/3d/                 # model library + SQLite + thumbs (data, not this repo)
```

## Install / re-link

```bash
ln -sfn /usr/local/3dlib/bin/3dlib /usr/local/bin/3dlib
ln -sfn /usr/local/3dlib/man/3dlib.1 /usr/local/share/man/man1/3dlib.1
ln -sfn /usr/local/3dlib/lib /usr/local/lib/3dlib
```

## Usage

```bash
3dlib help
man 3dlib
3dlib init
3dlib import PATH [--dryrun] [--copy|--move] [--clean]
3dlib delete ID|PATH [--dryrun] [--keep-files]
3dlib serve
```

### Web UI (LAN family use)

```bash
# Optional: password so family (e.g. your son) can browse/download models.
# Do NOT port-forward this service to the public internet.
export THREEDLIB_WEB_PASSWORD='family-secret'

# Optional separate admin password for delete in the UI
export THREEDLIB_WEB_ADMIN_PASSWORD='admin-secret'

3dlib serve
# http://localhost:31353/  (or http://<lan-ip>:31353/)
```

| Setup | Browse / download | Delete in UI |
|-------|-------------------|--------------|
| No passwords | Open on LAN | **Same machine only** (localhost / this host’s IPs) |
| Family password only | Login required; full access | Yes (after login); same machine always admin |
| Family + admin passwords | Family login | Admin login, **or** same machine |
| Admin password only | Open on LAN | Admin login, **or** same machine |

**Local admin (default on):** a browser on the same computer as `3dlib serve` is treated as admin with no password. Detection uses the TCP peer address (loopback and this host’s interface IPs). Disable with `THREEDLIB_WEB_LOCAL_ADMIN=0` or `"local_admin": false` under `web` in config.

Config alternative under `/share/3d/.library/config.json`:

```json
{
  "web": {
    "password": "family-secret",
    "admin_password": "admin-secret"
  }
}
```

UI features when allowed: **Download** on item pages, multi-select checkboxes on the gallery, bulk **Download** (zip) and **Delete**.

### Mesh previews (STL / STEP / …)

System `trimesh` + Gentoo `pyglet-2` cannot call `scene.save_image()` (trimesh requires `pyglet<2`). A dedicated venv fixes that:

```text
/usr/local/3dlib/venv-mesh/          # pyglet 1.5 + trimesh + numpy + pillow + scipy
/usr/local/3dlib/bin/mesh-preview    # auto re-execs under that venv
/usr/local/bin/mesh-preview          # symlink
```

```bash
mesh-preview model.stl out.png --size 512
mesh-preview part.step out.png          # FreeCAD tessellate, then render
mesh-preview model.stl --backend simple # no OpenGL (edge preview)
```

Backends: `auto` (default), `trimesh` (shaded GL), `simple` (wireframe), `freecad` (CAD → mesh).

Recreate the venv if needed:

```bash
python3 -m venv /usr/local/3dlib/venv-mesh
/usr/local/3dlib/venv-mesh/bin/pip install -r /usr/local/3dlib/venv-mesh-requirements.txt
```

### Description translation (OpenAI / Grok)

Chinese (CJK) descriptions can be translated via an OpenAI-compatible API.

```bash
# Uses OPENAI_API_KEY + gpt-4o-mini by default
3dlib translate 8 -v
3dlib translate            # all items still containing CJK
```

For xAI Grok, put in `/share/3d/.library/config.json`:

```json
{
  "translate": {
    "provider": "xai",
    "model": "grok-3-mini",
    "api_key_env": "XAI_API_KEY",
    "auto_import": true
  }
}
```

`auto_import` (default true) translates on import when a key is present. Original text is kept in `description_orig`.

When you change CLI behavior, update `man/3dlib.1` in the same change.
