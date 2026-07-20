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

When you change CLI behavior, update `man/3dlib.1` in the same change.
