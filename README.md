# takeout.sh

**NOTE**: This readme is incomplete

## Remarks
- rsync version 3 or later is required,

```bash
/usr/local/bin/rsync --version   # Intel
/opt/homebrew/bin/rsync --version # Apple Silicon
```


## CLI

```
Usage:
  takeout.sh <DOWNLOAD_DIR> <RSYNC_DEST> [options]

Required positional arguments:
  DOWNLOAD_DIR   Directory containing takeout*.tgz / *.tar.gz
  RSYNC_DEST     Destination directory for rsync output

Options:
  -v, --verbose            Show live progress in terminal (single-line updates)
  -h, --help               Show this help

  -n, --dry-run            Rsync dry run
  --phase <name>           extract | prescan | mtime | normalize | sync | all   (default: all)
  --log-dir <path>         Override log directory (default: <DOWNLOAD_DIR>/_logs/<timestamp>)
  --cleanup-extracted      Remove extracted data after successful run
  --keep-archives          Do not move processed archives to <DOWNLOAD_DIR>/_processed
  --photos-root <name>     Override Photos root folder name under Takeout (default: auto: "Google Foto" and "Google Photos")
  --delete                 Force removal of files in destination not in source (including .json files which always are excluded)
  --reset                  Remove extracted data + markers and move archives back from _processed before running

Behavior:
  - Archives are extracted (OVERLAID) into a single EXTRACT_BASE tree so sidecar JSON can land next to media.
  - File sidecar matching (simple deterministic rules):
      1) "<filename><anything>.json"
      2) "<basename_without_ext><anything>.json"
      3) If media is MP4/MOV: try "<basename>.HEIC<anything>.json" (iPhone Live Photos pairing)
  - Folder metadata: <folder>/metadata.json sets folder mtime.
  - Rsync shows progress when --verbose is used.
```
