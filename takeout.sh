#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

###############################################################################
# HELP
###############################################################################
show_help() {
  cat <<'EOF'
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
EOF
}

###############################################################################
# TERMINAL PROGRESS (verbose only)
###############################################################################
VERBOSE=0
progress_line() { [ "$VERBOSE" -eq 1 ] && printf "\r\033[K%s" "$*"; }
progress_done_line() { [ "$VERBOSE" -eq 1 ] && printf "\r\033[K%s\n" "$*"; }
say() { echo "$*"; }

###############################################################################
# ARG PARSING (supports -h before positionals)
###############################################################################
PHASE="all"
DRY_RUN=0
CLEANUP_EXTRACTED=0
KEEP_ARCHIVES=0
RESET=0
LOG_DIR=""
PHOTOS_ROOT_OVERRIDE=""

POSITIONALS=()

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) show_help; exit 0 ;;
    -v|--verbose) VERBOSE=1 ;;
    -n|--dry-run) DRY_RUN=1 ;;
    --cleanup-extracted) CLEANUP_EXTRACTED=1 ;;
    --keep-archives) KEEP_ARCHIVES=1 ;;
    --reset) RESET=1 ;;
    --log-dir) shift; [ $# -gt 0 ] || { echo "ERROR: --log-dir requires a value"; exit 1; }; LOG_DIR="$1" ;;
    --phase) shift; [ $# -gt 0 ] || { echo "ERROR: --phase requires a value"; exit 1; }; PHASE="$1" ;;
    --photos-root) shift; [ $# -gt 0 ] || { echo "ERROR: --photos-root requires a value"; exit 1; }; PHOTOS_ROOT_OVERRIDE="$1" ;;
    --) shift; while [ $# -gt 0 ]; do POSITIONALS+=( "$1" ); shift; done; break ;;
    -*) echo "ERROR: Unknown option: $1"; exit 1 ;;
    *) POSITIONALS+=( "$1" ) ;;
  esac
  shift
done

if [ "${#POSITIONALS[@]}" -lt 2 ]; then
  echo "ERROR: Missing required arguments."
  echo
  show_help
  exit 1
fi

DOWNLOAD_DIR="${POSITIONALS[0]}"
RSYNC_DEST="${POSITIONALS[1]}"

###############################################################################
# DEFAULTS / PATHS
###############################################################################
EXTRACT_BASE="${DOWNLOAD_DIR}/_extracted"
PROCESSED_DIR="${DOWNLOAD_DIR}/_processed"
MARKER_DIR="${EXTRACT_BASE}/.markers"

TIMESTAMP="$(date +"%Y%m%d-%H%M%S")"
if [ -z "$LOG_DIR" ]; then
  LOG_DIR="${DOWNLOAD_DIR}/_logs/${TIMESTAMP}"
fi

mkdir -p "$LOG_DIR" "$PROCESSED_DIR" "$RSYNC_DEST"

RUNINFO_LOG="${LOG_DIR}/00_runinfo.log"
PRESCAN_LOG="${LOG_DIR}/00_prescan.log"
EXTRACT_LOG="${LOG_DIR}/01_extract.log"
MTIME_FILE_LOG="${LOG_DIR}/02_mtime_files.log"
MTIME_DIR_LOG="${LOG_DIR}/03_mtime_dirs.log"
RSYNC_LOG="${LOG_DIR}/04_rsync.log"
UNMATCHED_LOG="${LOG_DIR}/90_unmatched.log"
SUMMARY_LOG="${LOG_DIR}/99_summary.log"

: > "$RUNINFO_LOG"
: > "$PRESCAN_LOG"
: > "$EXTRACT_LOG"
: > "$MTIME_FILE_LOG"
: > "$MTIME_DIR_LOG"
: > "$RSYNC_LOG"
: > "$UNMATCHED_LOG"
: > "$SUMMARY_LOG"

###############################################################################
# LOGGING HELPERS
###############################################################################
log() { local file="$1"; shift; echo "$(date '+%F %T') | $*" >> "$file"; }
phase_start() { log "$RUNINFO_LOG" "PHASE START: $1"; }
phase_end()   { log "$RUNINFO_LOG" "PHASE END:   $1"; }

###############################################################################
# REQUIREMENTS
###############################################################################
need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: Missing command: $1"; exit 1; }; }
need_cmd tar
need_cmd rsync
need_cmd python3
need_cmd find
need_cmd wc
need_cmd date
need_cmd rm
need_cmd mkdir

###############################################################################
# RESET (must happen before creating EXTRACT_BASE/MARKER_DIR)
###############################################################################
if [ "$RESET" -eq 1 ]; then
  # In verbose mode, show a short line
  progress_line "[reset] removing extracted data..."
  # Remove the whole extract base if present (includes markers)
  rm -rf "$EXTRACT_BASE" 2>/dev/null || true
  progress_done_line "[reset] done"
fi

# Ensure extraction directories exist after reset
mkdir -p "$EXTRACT_BASE" "$MARKER_DIR"

###############################################################################
# RUNINFO
###############################################################################
log "$RUNINFO_LOG" "Run started"
log "$RUNINFO_LOG" "DOWNLOAD_DIR=$DOWNLOAD_DIR"
log "$RUNINFO_LOG" "RSYNC_DEST=$RSYNC_DEST"
log "$RUNINFO_LOG" "EXTRACT_BASE=$EXTRACT_BASE"
log "$RUNINFO_LOG" "PROCESSED_DIR=$PROCESSED_DIR"
log "$RUNINFO_LOG" "MARKER_DIR=$MARKER_DIR"
log "$RUNINFO_LOG" "LOG_DIR=$LOG_DIR"
log "$RUNINFO_LOG" "PHASE=$PHASE"
log "$RUNINFO_LOG" "VERBOSE=$VERBOSE"
log "$RUNINFO_LOG" "DRY_RUN=$DRY_RUN"
log "$RUNINFO_LOG" "CLEANUP_EXTRACTED=$CLEANUP_EXTRACTED"
log "$RUNINFO_LOG" "KEEP_ARCHIVES=$KEEP_ARCHIVES"
log "$RUNINFO_LOG" "RESET=$RESET"
log "$RUNINFO_LOG" "PHOTOS_ROOT_OVERRIDE=${PHOTOS_ROOT_OVERRIDE:-<auto>}"

###############################################################################
# GLOBAL COUNTS (filled by prescan)
###############################################################################
ARCHIVE_COUNT=0
SIDECAR_JSON_COUNT=0
DIR_METADATA_COUNT=0
SYNC_SOURCE_COUNT=0
MEDIA_FILE_COUNT=0

###############################################################################
# STEP: EXTRACT (OVERLAY into EXTRACT_BASE)
###############################################################################
do_extract() {
  phase_start "extract"
  progress_line "[extract] scanning archives..."

  shopt -s nullglob
  local archives=(
    "${DOWNLOAD_DIR}"/takeout*.tgz
    "${DOWNLOAD_DIR}"/Takeout*.tgz
    "${DOWNLOAD_DIR}"/takeout*.tar.gz
    "${DOWNLOAD_DIR}"/Takeout*.tar.gz
  )
  shopt -u nullglob

  local total="${#archives[@]}"
  ARCHIVE_COUNT="$total"
  log "$EXTRACT_LOG" "ARCHIVES_FOUND=$total"
  log "$EXTRACT_LOG" "MODE=OVERLAY_INTO_EXTRACT_BASE"

  if [ "$total" -eq 0 ]; then
    progress_done_line "[extract] no archives found"
    phase_end "extract"
    return 0
  fi

  local i=0
  for archive in "${archives[@]}"; do
    i=$((i+1))
    local pct=$(( i * 100 / total ))
    local base marker

    base="$(basename "$archive")"
    marker="${MARKER_DIR}/${base}.ok"

    progress_line "[extract] ${i}/${total} (${pct}%) ${base}"
    log "$EXTRACT_LOG" "[${i}/${total}] (${pct}%) archive=$archive"

    if [ -f "$marker" ]; then
      log "$EXTRACT_LOG" "  SKIP already extracted marker=$marker"
      continue
    fi

    if tar -xzf "$archive" -C "$EXTRACT_BASE" >> "$EXTRACT_LOG" 2>&1; then
      touch "$marker"
      log "$EXTRACT_LOG" "  OK extracted into EXTRACT_BASE=$EXTRACT_BASE"
    else
      log "$EXTRACT_LOG" "  ERROR extracting archive=$archive"
      progress_done_line "[extract] ERROR (see log)"
      exit 1
    fi
  done

  progress_done_line "[extract] done (${total} archives)"
  phase_end "extract"
}

###############################################################################
# STEP: PRESCAN
###############################################################################
do_prescan() {
  phase_start "prescan"
  progress_line "[prescan] scanning extracted tree..."

  SIDECAR_JSON_COUNT="$(
    find "$EXTRACT_BASE" -type f \( \
      -iname "*.jpg.json" -o -iname "*.jpeg.json" -o -iname "*.png.json" -o \
      -iname "*.gif.json" -o -iname "*.heic.json" -o -iname "*.mp4.json" -o \
      -iname "*.mov.json" -o -iname "*.m4v.json" -o -iname "*.avi.json" -o \
      -iname "*.webp.json" -o -iname "*.tif.json" -o -iname "*.tiff.json" \
    \) -print 2>/dev/null | wc -l | tr -d ' '
  )"

  DIR_METADATA_COUNT="$(
    find "$EXTRACT_BASE" -type f -name "metadata.json" -print 2>/dev/null | wc -l | tr -d ' '
  )"

  if [ -n "$PHOTOS_ROOT_OVERRIDE" ]; then
    SYNC_SOURCE_COUNT="$(
      find "$EXTRACT_BASE" -type d -path "*/Takeout/${PHOTOS_ROOT_OVERRIDE}" -print 2>/dev/null | wc -l | tr -d ' '
    )"
  else
    SYNC_SOURCE_COUNT="$(
      find "$EXTRACT_BASE" -type d \( \
        -path "*/Takeout/Google Foto" -o \
        -path "*/Takeout/Google Photos" \
      \) -print 2>/dev/null | wc -l | tr -d ' '
    )"
  fi

  MEDIA_FILE_COUNT="$(
    find "$EXTRACT_BASE" -type f \( \
      -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.png" -o -iname "*.gif" -o -iname "*.heic" -o \
      -iname "*.mp4" -o -iname "*.mov" -o -iname "*.m4v" -o -iname "*.avi" -o -iname "*.webp" -o \
      -iname "*.tif" -o -iname "*.tiff" \
    \) -print 2>/dev/null | wc -l | tr -d ' '
  )"

  log "$PRESCAN_LOG" "ARCHIVE_COUNT=$ARCHIVE_COUNT"
  log "$PRESCAN_LOG" "SIDECAR_JSON_COUNT=$SIDECAR_JSON_COUNT"
  log "$PRESCAN_LOG" "DIR_METADATA_COUNT=$DIR_METADATA_COUNT"
  log "$PRESCAN_LOG" "SYNC_SOURCE_COUNT=$SYNC_SOURCE_COUNT"
  log "$PRESCAN_LOG" "MEDIA_FILE_COUNT=$MEDIA_FILE_COUNT"

  {
    echo "PRESCAN:"
    echo "  ARCHIVE_COUNT=$ARCHIVE_COUNT"
    echo "  SIDECAR_JSON_COUNT=$SIDECAR_JSON_COUNT"
    echo "  DIR_METADATA_COUNT=$DIR_METADATA_COUNT"
    echo "  SYNC_SOURCE_COUNT=$SYNC_SOURCE_COUNT"
    echo "  MEDIA_FILE_COUNT=$MEDIA_FILE_COUNT"
  } >> "$SUMMARY_LOG"

  progress_done_line "[prescan] archives=$ARCHIVE_COUNT sidecar_json=$SIDECAR_JSON_COUNT dir_meta=$DIR_METADATA_COUNT media=$MEDIA_FILE_COUNT sync_roots=$SYNC_SOURCE_COUNT"
  phase_end "prescan"
}

###############################################################################
# STEP: MTIME FILES (+ report media without sidecar)
###############################################################################
do_mtime_files() {
  phase_start "mtime-files"

  if [ "$MEDIA_FILE_COUNT" -eq 0 ]; then
    log "$MTIME_FILE_LOG" "INFO: No media files found under EXTRACT_BASE."
    progress_done_line "[mtime-files] skipped (no media files)"
    phase_end "mtime-files"
    return 0
  fi

  EXTRACT_BASE="$EXTRACT_BASE" \
  MTIME_FILE_LOG="$MTIME_FILE_LOG" \
  UNMATCHED_LOG="$UNMATCHED_LOG" \
  TOTAL_SIDECAR_JSON="$SIDECAR_JSON_COUNT" \
  TOTAL_MEDIA_FILES="$MEDIA_FILE_COUNT" \
  VERBOSE="$VERBOSE" \
  python3 - <<'PY'
import os, json, sys, time

extract_base = os.environ["EXTRACT_BASE"]
log_file = os.environ["MTIME_FILE_LOG"]
unmatched = os.environ["UNMATCHED_LOG"]
total_sidecar = int(os.environ.get("TOTAL_SIDECAR_JSON","0") or "0")
total_media = int(os.environ.get("TOTAL_MEDIA_FILES","0") or "0")
verbose = os.environ.get("VERBOSE","0") == "1"

SAFE_SUFFIXES = (
    ".jpg.json",".jpeg.json",".png.json",".gif.json",".heic.json",
    ".mp4.json",".mov.json",".m4v.json",".avi.json",".webp.json",
    ".tif.json",".tiff.json"
)
MEDIA_SUFFIXES = (
    ".jpg",".jpeg",".png",".gif",".heic",
    ".mp4",".mov",".m4v",".avi",".webp",
    ".tif",".tiff"
)

def log(msg):
    with open(log_file,"a") as f:
        f.write(f"{time.strftime('%F %T')} | {msg}\n")

def unmatch(msg):
    with open(unmatched,"a") as f:
        f.write(f"{time.strftime('%F %T')} | {msg}\n")

def progress_line(msg):
    if not verbose:
        return
    sys.stdout.write("\r\033[K" + msg)
    sys.stdout.flush()

def progress_done(msg):
    if not verbose:
        return
    sys.stdout.write("\r\033[K" + msg + "\n")
    sys.stdout.flush()

def pick_timestamp(meta):
    for key in ("photoTakenTime","creationTime"):
        obj = meta.get(key)
        if isinstance(obj,dict):
            ts = obj.get("timestamp")
            if ts:
                try:
                    return int(ts)
                except:
                    pass
    return None

# A) Update mtimes for files based on safe sidecar JSON
if total_sidecar == 0:
    log("INFO: No sidecar JSON files found (safe patterns). File mtimes will not be updated from sidecars.")
else:
    log(f"INFO: Sidecar JSON expected (from prescan) = {total_sidecar}")

processed_json = 0
updated = 0
missing_media_for_json = 0
bad_json = 0
no_timestamp = 0
utime_failed = 0

if total_sidecar > 0:
    step_json = max(100, total_sidecar // 100)
else:
    step_json = 1000

for root, _, files in os.walk(extract_base):
    for fn in files:
        lfn = fn.lower()
        if not lfn.endswith(SAFE_SUFFIXES):
            continue

        processed_json += 1
        json_path = os.path.join(root, fn)
        media_path = json_path[:-5]

        if not os.path.exists(media_path):
            missing_media_for_json += 1
            unmatch(f"MISSING_MEDIA_FOR_JSON json={json_path} expected_media={media_path}")
        else:
            try:
                with open(json_path,"r",encoding="utf-8") as f:
                    meta = json.load(f)
            except:
                bad_json += 1
                unmatch(f"BAD_JSON json={json_path}")
                meta = None

            if meta is not None:
                ts = pick_timestamp(meta)
                if not ts:
                    no_timestamp += 1
                    unmatch(f"NO_TIMESTAMP json={json_path}")
                else:
                    try:
                        os.utime(media_path, (ts, ts))
                        updated += 1
                    except:
                        utime_failed += 1
                        unmatch(f"UTIME_FAILED media={media_path} ts={ts}")

        if processed_json % step_json == 0:
            if total_sidecar > 0:
                pct = int(processed_json * 100 / total_sidecar)
                if pct > 100: pct = 100
                progress_line(f"[mtime-files:sidecars] {processed_json}/{total_sidecar} ({pct}%) updated={updated}")
            else:
                progress_line(f"[mtime-files:sidecars] processed={processed_json} updated={updated}")

if total_sidecar > 0:
    progress_done(f"[mtime-files:sidecars] done updated={updated} (see logs)")

log(f"SIDECAR_JSON_PROCESSED={processed_json}")
log(f"UPDATED_FILES_FROM_SIDECAR={updated}")
log(f"MISSING_MEDIA_FOR_JSON={missing_media_for_json}")
log(f"BAD_JSON={bad_json}")
log(f"NO_TIMESTAMP={no_timestamp}")
log(f"UTIME_FAILED={utime_failed}")

# B) Report media files that have NO sidecar JSON (expected: <media>.<ext>.json)
media_seen = 0
media_no_sidecar = 0

if total_media > 0:
    step_media = max(500, total_media // 100)
else:
    step_media = 2000

for root, _, files in os.walk(extract_base):
    for fn in files:
        lfn = fn.lower()
        if not lfn.endswith(MEDIA_SUFFIXES):
            continue

        media_seen += 1
        media_path = os.path.join(root, fn)
        sidecar_path = media_path + ".json"

        if not os.path.exists(sidecar_path):
            media_no_sidecar += 1
            unmatch(f"NO_SIDECAR media={media_path} expected_sidecar={sidecar_path}")

        if media_seen % step_media == 0:
            if total_media > 0:
                pct = int(media_seen * 100 / total_media)
                if pct > 100: pct = 100
                progress_line(f"[mtime-files:nosidecar] {media_seen}/{total_media} ({pct}%) no_sidecar={media_no_sidecar}")
            else:
                progress_line(f"[mtime-files:nosidecar] scanned={media_seen} no_sidecar={media_no_sidecar}")

progress_done(f"[mtime-files:nosidecar] done scanned={media_seen} no_sidecar={media_no_sidecar}")

log(f"MEDIA_FILES_SCANNED={media_seen}")
log(f"MEDIA_FILES_NO_SIDECAR={media_no_sidecar}")
PY

  phase_end "mtime-files"
}

###############################################################################
# STEP: MTIME DIRS (metadata.json applies to folder mtime)
###############################################################################
do_mtime_dirs() {
  phase_start "mtime-dirs"

  if [ "$DIR_METADATA_COUNT" -eq 0 ]; then
    log "$MTIME_DIR_LOG" "INFO: No metadata.json found. Directory mtimes will not be updated."
    progress_done_line "[mtime-dirs] skipped (0 metadata.json)"
    phase_end "mtime-dirs"
    return 0
  fi

  EXTRACT_BASE="$EXTRACT_BASE" \
  MTIME_DIR_LOG="$MTIME_DIR_LOG" \
  UNMATCHED_LOG="$UNMATCHED_LOG" \
  TOTAL_DIR_METADATA="$DIR_METADATA_COUNT" \
  VERBOSE="$VERBOSE" \
  python3 - <<'PY'
import os, json, sys, time

extract_base = os.environ["EXTRACT_BASE"]
log_file = os.environ["MTIME_DIR_LOG"]
unmatched = os.environ["UNMATCHED_LOG"]
total = int(os.environ.get("TOTAL_DIR_METADATA","0") or "0")
verbose = os.environ.get("VERBOSE","0") == "1"

def log(msg):
    with open(log_file,"a") as f:
        f.write(f"{time.strftime('%F %T')} | {msg}\n")

def unmatch(msg):
    with open(unmatched,"a") as f:
        f.write(f"{time.strftime('%F %T')} | {msg}\n")

def progress_line(msg):
    if not verbose:
        return
    sys.stdout.write("\r\033[K" + msg)
    sys.stdout.flush()

def progress_done(msg):
    if not verbose:
        return
    sys.stdout.write("\r\033[K" + msg + "\n")
    sys.stdout.flush()

def pick_timestamp(meta):
    for key in ("photoTakenTime","creationTime"):
        obj = meta.get(key)
        if isinstance(obj,dict):
            ts = obj.get("timestamp")
            if ts:
                try:
                    return int(ts)
                except:
                    pass
    return None

processed = 0
updated = 0
bad_json = 0
no_ts = 0
utime_failed = 0

if total > 0:
    step = max(50, total // 100)
else:
    step = 200

for root, _, files in os.walk(extract_base):
    if "metadata.json" not in files:
        continue

    processed += 1
    json_path = os.path.join(root, "metadata.json")

    try:
        with open(json_path,"r",encoding="utf-8") as f:
            meta = json.load(f)
    except:
        bad_json += 1
        unmatch(f"BAD_DIR_JSON json={json_path}")
        meta = None

    if meta is not None:
        ts = pick_timestamp(meta)
        if not ts:
            no_ts += 1
            unmatch(f"NO_DIR_TIMESTAMP json={json_path}")
        else:
            try:
                os.utime(root, (ts, ts))
                updated += 1
            except:
                utime_failed += 1
                unmatch(f"DIR_UTIME_FAILED dir={root} ts={ts}")

    if processed % step == 0:
        if total > 0:
            pct = int(processed * 100 / total)
            if pct > 100: pct = 100
            progress_line(f"[mtime-dirs] {processed}/{total} ({pct}%) updated={updated}")
        else:
            progress_line(f"[mtime-dirs] processed={processed} updated={updated}")

progress_done(f"[mtime-dirs] done processed={processed} updated={updated}")

log(f"DIR_METADATA_PROCESSED={processed}")
log(f"UPDATED_DIRS={updated}")
log(f"BAD_DIR_JSON={bad_json}")
log(f"NO_DIR_TIMESTAMP={no_ts}")
log(f"DIR_UTIME_FAILED={utime_failed}")
PY

  phase_end "mtime-dirs"
}

###############################################################################
# STEP: SYNC
###############################################################################
do_sync() {
  phase_start "sync"
  progress_line "[sync] locating sources..."

  local sources=""
  if [ -n "$PHOTOS_ROOT_OVERRIDE" ]; then
    sources="$(find "$EXTRACT_BASE" -type d -path "*/Takeout/${PHOTOS_ROOT_OVERRIDE}" -print 2>/dev/null)"
  else
    sources="$(find "$EXTRACT_BASE" -type d \( \
      -path "*/Takeout/Google Foto" -o \
      -path "*/Takeout/Google Photos" \
    \) -print 2>/dev/null)"
  fi

  if [ -z "$sources" ]; then
    log "$RSYNC_LOG" "ERROR: No sync sources found under EXTRACT_BASE=$EXTRACT_BASE"
    progress_done_line "[sync] ERROR: no sources (see logs)"
    phase_end "sync"
    exit 1
  fi

  local total_sources
  total_sources="$(printf "%s\n" "$sources" | wc -l | tr -d ' ')"
  SYNC_SOURCE_COUNT="$total_sources"

  log "$RSYNC_LOG" "SOURCES_FOUND=$total_sources"
  log "$RSYNC_LOG" "DEST=$RSYNC_DEST"
  log "$RSYNC_LOG" "DRY_RUN=$DRY_RUN"

  local n=0
  while IFS= read -r src; do
    [ -z "$src" ] && continue
    n=$((n+1))
    local pct=$(( n * 100 / total_sources ))
    progress_line "[sync] ${n}/${total_sources} (${pct}%) $(basename "$src")"

    log "$RSYNC_LOG" "[${n}/${total_sources}] (${pct}%) source=$src"

    if [ "$DRY_RUN" -eq 1 ]; then
      rsync -av --dry-run "${src}/" "${RSYNC_DEST}/" >> "$RSYNC_LOG" 2>&1
    else
      rsync -av "${src}/" "${RSYNC_DEST}/" >> "$RSYNC_LOG" 2>&1
    fi
  done <<< "$sources"

  progress_done_line "[sync] done (${total_sources} sources)"
  phase_end "sync"
}

###############################################################################
# ARCHIVE HANDLING
###############################################################################
move_archives() {
  if [ "$KEEP_ARCHIVES" -eq 1 ]; then
    log "$RUNINFO_LOG" "KEEP_ARCHIVES=1 -> not moving archives"
    return 0
  fi

  shopt -s nullglob
  for a in "${DOWNLOAD_DIR}"/takeout*.tgz "${DOWNLOAD_DIR}"/Takeout*.tgz "${DOWNLOAD_DIR}"/takeout*.tar.gz "${DOWNLOAD_DIR}"/Takeout*.tar.gz; do
    mv -f "$a" "$PROCESSED_DIR"/ 2>/dev/null || true
  done
  shopt -u nullglob
}

###############################################################################
# MAIN DISPATCH
###############################################################################
case "$PHASE" in
  extract) do_extract ;;
  prescan) do_prescan ;;
  mtime) do_prescan; do_mtime_files; do_mtime_dirs ;;
  sync) do_prescan; do_sync ;;
  all) do_extract; do_prescan; do_mtime_files; do_mtime_dirs; do_sync ;;
  *)
    echo "ERROR: Invalid --phase value: $PHASE"
    echo "Allowed: extract | prescan | mtime | sync | all"
    exit 1
    ;;
esac

move_archives

if [ "$CLEANUP_EXTRACTED" -eq 1 ]; then
  log "$RUNINFO_LOG" "Cleanup: removing EXTRACT_BASE=$EXTRACT_BASE"
  rm -rf "$EXTRACT_BASE"
fi

log "$SUMMARY_LOG" "FINISHED at $(date)"
log "$SUMMARY_LOG" "LOG_DIR=$LOG_DIR"

say "Logs: $LOG_DIR"
