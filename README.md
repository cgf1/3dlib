# 3dlib

Personal 3D model library manager for `/share/3d`.

## Layout

```text
/usr/local/3dlib/          # this git project
  bin/3dlib                # CLI
  lib/*.pm                 # Perl modules
  man/3dlib.1              # man page (keep in sync with CLI)
  share/applications/      # desktop entry template
  share/openrc/            # Gentoo OpenRC init + conf.d
  share/systemd/           # systemd unit (example)

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

### Reload / service files

`3dlib serve` re-execs on **SIGHUP** or **SIGQUIT** (`Ctrl-\`) so code reloads with the **same PID** (safe for service managers).

```bash
kill -HUP "$(pidof -x 3dlib)"    # or: kill -HUP <pid>
```

**Gentoo OpenRC** (ednor and friends):

```bash
sudo cp /usr/local/3dlib/share/openrc/3dlib /etc/init.d/3dlib
sudo chmod 755 /etc/init.d/3dlib
sudo cp /usr/local/3dlib/share/openrc/3dlib.conf /etc/conf.d/3dlib
# edit /etc/conf.d/3dlib if needed
sudo rc-update add 3dlib default
sudo rc-service 3dlib start
sudo rc-service 3dlib reload    # after git pull / code edits
```

**systemd** (example; not used on ednor):

```bash
sudo cp /usr/local/3dlib/share/systemd/3dlib.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now 3dlib
sudo systemctl reload 3dlib
```

## Usage

```bash
3dlib help
man 3dlib
3dlib init
3dlib import PATH [--dryrun] [--copy|--move] [--clean]
3dlib delete ID|PATH [--dryrun] [--keep-files]
3dlib edit ID|PATH --url URL [--description TEXT] [--name TEXT] …
3dlib show ID|PATH          # details + open thumbnail (feh by default)
3dlib import PATH           # detailed summary (use -q for one-liners)
3dlib tag 9 clasp jewelry   # keywords (catalog-side; not in Bambu 3MF)
3dlib ls --tag clasp
3dlib tags                  # list all tags
3dlib serve
```

Thumbnail viewer for `show` / `describe --view`:

```bash
export THREEDLIB_IMAGE_VIEWER='feh -.'   # or imv, sxiv, …
# config.json: "image_viewer": "feh"
```

### Launch apps (URL handlers + CLI)

The web UI does **not** start GUI apps from the daemon. Buttons use custom
URL schemes; the desktop session runs `3dlib` (with the right `DISPLAY` /
xpra), and `3dlib` launches the app:

| Button | URL | Handler |
|--------|-----|---------|
| Open in Bambu Studio | `bambustudio://library/ID` | `x-scheme-handler/bambustudio` |
| Open in FreeCAD | `freecad://library/ID` | `x-scheme-handler/freecad` |

Register once per user desktop:

```bash
3dlib install-handler
# verify:
xdg-mime query default x-scheme-handler/bambustudio
xdg-mime query default x-scheme-handler/freecad
```

CLI (same path the handlers use):

```bash
3dlib run 'bambustudio://library/9'
3dlib run 'freecad://library/9'
3dlib run 9                    # Studio by default
3dlib run 9 --app freecad
xdg-open 'bambustudio://library/9'
```

App binaries (used by `3dlib run` in your session):

```json
{
  "bambu_studio": "/usr/local/bin/bambu-studio",
  "freecad": "freecad",
  "freecad_shell": false
}
```

| Key / env | Purpose |
|-----------|---------|
| `bambu_studio` | Bambu Studio binary |
| `freecad` / `THREEDLIB_FREECAD` | FreeCAD command; `{file}` optional |
| `freecad_shell` / `THREEDLIB_FREECAD_SHELL=1` | Run FreeCAD via `/bin/sh -c` |

Remote FreeCAD example (shared library path on `tomoon`):

```text
"freecad": "ssh -Y tomoon freecad"
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

UI features when allowed: **Download** on item pages, multi-select checkboxes on the gallery, bulk **Download** (zip) and **Delete**. Admins can **Edit** an item to set name, description, primary/additional source URLs, site ids, and status (metadata only; does not move files).

**Settings** (header link, admin / local admin only): form editor for `/share/3d/.library/config.json` — library paths, web passwords, local admin, translation API. Secrets are write-only (leave blank to keep). Advanced section edits raw JSON.

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

Non-English catalog **names and descriptions** (Chinese, German, French, Italian,
Spanish, …) are translated via an OpenAI-compatible API. Detection covers CJK,
letters with diacritics (äöüß, …), other scripts, and common non-English function
words even in pure ASCII. Originals are stored in `name_orig` / `description_orig`
(files on disk are not renamed). `description_orig` is hidden in the web UI.

```bash
3dlib translate -v              # all non-English names/descriptions
3dlib translate 14 -v           # one item
3dlib translate --dryrun        # preview first
```

Config (`/share/3d/.library/config.json`):

```json
{
  "translate": {
    "provider": "xai",
    "model": "grok-latest",
    "api_key_env": "XAI_API_KEY",
    "auto_import": true,
    "detect": "auto"
  }
}
```

| `detect` | Meaning |
|----------|---------|
| `auto` (default) | Any non-English (CJK + European languages + …) |
| `cjk` | Chinese/Japanese/Korean only (old behavior) |

`auto_import` (default true) runs the same detection on every import when an API key is available.

When you change CLI behavior, update `man/3dlib.1` in the same change.
