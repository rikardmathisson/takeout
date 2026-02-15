# takeout.sh

Usage:
  takeout.sh <DOWNLOAD_DIR> <RSYNC_DEST> [options]

Required positional arguments:
  DOWNLOAD_DIR   Directory containing takeout*.tgz / *.tar.gz
  RSYNC_DEST     Destination directory for rsync output

Options:
  -v, --verbose            Show live progress in terminal (single-line updates)
  -h, --help               Show this help

  -n, --dry-run            Rsync dry run
  --phase <name>           extract | prescan | mtime | sync | all   (default: all)
  --log-dir <path>         Override log directory (default: <DOWNLOAD_DIR>/_logs/<timestamp>)
  --cleanup-extracted      Remove extracted data after successful run
  --keep-archives          Do not move processed archives to <DOWNLOAD_DIR>/_processed
  --photos-root <name>     Override Photos root folder name under Takeout (default: auto: "Google Foto" and "Google Photos")
  --reset                  Remove extracted data + markers before running (forces re-extract and reprocess)

Behavior:
  - All archives are extracted (OVERLAID) into a single EXTRACT_BASE tree so sidecar JSON can land next to media.
  - Sidecar metadata applied ONLY when JSON safely maps: "<file>.<ext>.json" -> "<file>.<ext>".
  - Folder mtime set when a folder contains "metadata.json" (applies to the folder itself).
