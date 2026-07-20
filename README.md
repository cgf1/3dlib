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

When you change CLI behavior, update `man/3dlib.1` in the same change.
