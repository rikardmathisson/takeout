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
  --reset                  Remove extracted data + markers and move archives back from _processed before running

Behavior:
  - Archives are extracted (OVERLAID) into a single EXTRACT_BASE tree so sidecar JSON can land next to media.
  - File sidecar matching (simple deterministic rules):
      1) "<filename><anything>.json"
      2) "<basename_without_ext><anything>.json"
      3) If media is MP4/MOV: try "<basename>.HEIC<anything>.json" (iPhone Live Photos pairing)
  - Folder metadata: <folder>/metadata.json sets folder mtime.
  - Rsync shows progress when --verbose is used.
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
# ARG PARSING
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
# RESET
###############################################################################
if [ "$RESET" -eq 1 ]; then
  progress_line "[reset] removing extracted data and restoring archives..."

  rm -rf "$EXTRACT_BASE" 2>/dev/null || true

  if [ -d "$PROCESSED_DIR" ]; then
    shopt -s nullglob
    for a in "$PROCESSED_DIR"/takeout*.tgz "$PROCESSED_DIR"/Takeout*.tgz "$PROCESSED_DIR"/takeout*.tar.gz "$PROCESSED_DIR"/Takeout*.tar.gz; do
      mv -f "$a" "$DOWNLOAD_DIR"/ 2>/dev/null || true
    done
    shopt -u nullglob
  fi

  progress_done_line "[reset] done"
fi

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
# GLOBAL COUNTS
###############################################################################
ARCHIVE_COUNT=0
DIR_METADATA_COUNT=0
SYNC_SOURCE_COUNT=0
MEDIA_FILE_COUNT=0

###############################################################################
# STEP: EXTRACT (OVERLAY) + immediate move to _processed
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
      if [ "$KEEP_ARCHIVES" -eq 0 ]; then
        mv -f "$archive" "$PROCESSED_DIR"/ 2>/dev/null || true
        log "$EXTRACT_LOG" "  MOVED (skip) to processed: $PROCESSED_DIR/$base"
      fi
      continue
    fi

    if tar -xzf "$archive" -C "$EXTRACT_BASE" >> "$EXTRACT_LOG" 2>&1; then
      touch "$marker"
      log "$EXTRACT_LOG" "  OK extracted into EXTRACT_BASE=$EXTRACT_BASE"

      if [ "$KEEP_ARCHIVES" -eq 0 ]; then
        mv -f "$archive" "$PROCESSED_DIR"/ 2>/dev/null || true
        log "$EXTRACT_LOG" "  MOVED to processed: $PROCESSED_DIR/$base"
      fi
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
  log "$PRESCAN_LOG" "DIR_METADATA_COUNT=$DIR_METADATA_COUNT"
  log "$PRESCAN_LOG" "SYNC_SOURCE_COUNT=$SYNC_SOURCE_COUNT"
  log "$PRESCAN_LOG" "MEDIA_FILE_COUNT=$MEDIA_FILE_COUNT"

  progress_done_line "[prescan] archives=$ARCHIVE_COUNT dir_meta=$DIR_METADATA_COUNT media=$MEDIA_FILE_COUNT sync_roots=$SYNC_SOURCE_COUNT"
  phase_end "prescan"
}

###############################################################################
# STEP: MTIME FILES (simple deterministic sidecar rules)
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
  TOTAL_MEDIA_FILES="$MEDIA_FILE_COUNT" \
  VERBOSE="$VERBOSE" \
  python3 - <<'PY'
import os, json, sys, time

extract_base = os.environ["EXTRACT_BASE"]
log_file = os.environ["MTIME_FILE_LOG"]
unmatched = os.environ["UNMATCHED_LOG"]
total_media = int(os.environ.get("TOTAL_MEDIA_FILES","0") or "0")
verbose = os.environ.get("VERBOSE","0") == "1"

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

def pick_timestamp(meta: dict):
    # Accept common Takeout timestamp keys
    for key in ("photoTakenTime", "creationTime", "date"):
        obj = meta.get(key)
        if isinstance(obj, dict):
            ts = obj.get("timestamp")
            if ts is None:
                continue
            try:
                return int(ts)
            except Exception:
                pass
    return None

def first_json_with_prefix(dirname: str, prefix: str):
    try:
        for cand in os.listdir(dirname):
            if cand.startswith(prefix) and cand.lower().endswith(".json"):
                return os.path.join(dirname, cand)
    except Exception:
        return None
    return None

processed = 0
updated = 0
no_sidecar = 0
bad_json = 0
no_timestamp = 0
utime_failed = 0

step = max(500, total_media // 100) if total_media > 0 else 2000

for root, _, files in os.walk(extract_base, topdown=False):
    for fn in files:
        lfn = fn.lower()
        if not lfn.endswith(MEDIA_SUFFIXES):
            continue

        processed += 1
        media_path = os.path.join(root, fn)

        dirname = os.path.dirname(media_path)
        filename = os.path.basename(media_path)                 # includes extension
        base_no_ext, ext = os.path.splitext(filename)
        ext_lower = ext.lower()

        json_path = None

        # 1) "<filename><anything>.json"
        json_path = first_json_with_prefix(dirname, filename)

        # 2) "<basename_without_ext><anything>.json"
        if not json_path:
            json_path = first_json_with_prefix(dirname, base_no_ext)

        # 2b) Duplicate strategy (2020+):
        # "EFFECTS(1).jpg" may have JSON like "EFFECTS.jpg.supplemental-metadata(1).json"
        if not json_path:
            # Detect "(number)" suffix in base filename
            import re
            m = re.match(r"^(.*)\((\d+)\)$", base_no_ext)
            if m:
                original_base = m.group(1)
                # Try prefix "<original_base><ext>" e.g. "EFFECTS.jpg"
                json_path = first_json_with_prefix(dirname, original_base + ext)

        # 3) MP4/MOV -> try HEIC
        if not json_path and ext_lower in (".mp4", ".mov"):
            json_path = first_json_with_prefix(dirname, base_no_ext + ".HEIC")
            if not json_path:
                json_path = first_json_with_prefix(dirname, base_no_ext + ".heic")

        if not json_path:
            no_sidecar += 1
            unmatch(f"NO_SIDECAR media={media_path}")
        else:
            try:
                with open(json_path,"r",encoding="utf-8") as f:
                    meta = json.load(f)
            except Exception:
                bad_json += 1
                unmatch(f"BAD_JSON json={json_path} media={media_path}")
                meta = None

            if meta is not None:
                ts = pick_timestamp(meta)
                if not ts:
                    no_timestamp += 1
                    unmatch(f"NO_TIMESTAMP json={json_path} media={media_path}")
                else:
                    try:
                        os.utime(media_path, (ts, ts))
                        updated += 1
                    except Exception:
                        utime_failed += 1
                        unmatch(f"UTIME_FAILED media={media_path} ts={ts}")

        if processed % step == 0:
            if total_media > 0:
                pct = int(processed * 100 / total_media)
                if pct > 100: pct = 100
                progress_line(f"[mtime-files] {processed}/{total_media} ({pct}%) updated={updated} no_sidecar={no_sidecar}")
            else:
                progress_line(f"[mtime-files] processed={processed} updated={updated} no_sidecar={no_sidecar}")

progress_done(f"[mtime-files] done processed={processed} updated={updated} no_sidecar={no_sidecar}")

log(f"MEDIA_PROCESSED={processed}")
log(f"UPDATED_MEDIA_FILES={updated}")
log(f"MEDIA_NO_SIDECAR={no_sidecar}")
log(f"BAD_JSON={bad_json}")
log(f"NO_TIMESTAMP={no_timestamp}")
log(f"UTIME_FAILED={utime_failed}")
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

def pick_timestamp(meta: dict):
    # Accept common Takeout timestamp keys
    for key in ("photoTakenTime", "creationTime", "date"):
        obj = meta.get(key)
        if isinstance(obj, dict):
            ts = obj.get("timestamp")
            if ts is None:
                continue
            try:
                return int(ts)
            except Exception:
                pass
    return None

processed = 0
updated = 0
bad_json = 0
no_ts = 0
utime_failed = 0

step = max(50, total // 100) if total > 0 else 200

for root, _, files in os.walk(extract_base, topdown=False):
    if "metadata.json" not in files:
        continue

    processed += 1
    json_path = os.path.join(root, "metadata.json")

    try:
        with open(json_path,"r",encoding="utf-8") as f:
            meta = json.load(f)
    except Exception:
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
            except Exception:
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
# STEP: SYNC (rsync progress + terminal output in verbose)
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

    RSYNC_OPTS=(-a -v --exclude='*.json' --delete-delay)

    if [ "$VERBOSE" -eq 1 ]; then
      # Run rsync, log everything, but only show compact "to-check" progress in terminal.
      rsync_tmp="${LOG_DIR}/.rsync_live_${n}.log"
      : > "$rsync_tmp"

      RSYNC_OPTS+=(--progress)
      if [ "$DRY_RUN" -eq 1 ]; then
        RSYNC_OPTS+=(--dry-run)
      fi

      # Run rsync in background, tee output to both a temp live file and the main log
      (
        script -q /dev/null rsync "${RSYNC_OPTS[@]}" "${src}/" "${RSYNC_DEST}/" 2>&1 \
          | tee -a "$rsync_tmp" >> "$RSYNC_LOG"
      ) &
      rsync_pid=$!

      # While rsync runs: show only the latest "(xfer#, to-check=.../...)" line
      last=""
      while kill -0 "$rsync_pid" 2>/dev/null; do
        # Read a small rolling window and pick the last progress-like line from it
        window="$(tail -n 200 "$rsync_tmp" 2>/dev/null | tr '\r' '\n')"

        line="$(printf "%s\n" "$window" \
          | grep -E '(to-(check|chk)|ir-chk)=[0-9]+/[0-9]+' \
          | tail -n 1 || true)"

        # prog="$(printf "%s" "$line" | sed -n 's/.*\(ir-chk\|to-chk\|to-check\)=\([0-9]\+\/[0-9]\+\).*/\2/p')"
        prog="$(
          printf "%s" "$line" \
          | grep -Eo '(ir-chk|to-chk|to-check)=[0-9]+/[0-9]+' \
          | tail -n 1 \
          | cut -d= -f2 \
          || true
        )"
        
        if [ -n "$prog" ]; then
          cur="${prog%/*}"
          tot="${prog#*/}"

          if [ "$tot" -gt 0 ] 2>/dev/null; then
            pct2=$(( (tot - cur) * 100 / tot ))
            progress_line "[sync] ${n}/${total_sources} (${pct2}%) running..."
          else
            progress_line "[sync] ${n}/${total_sources} running..."
          fi
        else
          progress_line "[sync] ${n}/${total_sources} running..."
        fi

        sleep 1
      done

      wait "$rsync_pid"
      progress_done_line "[sync] ${n}/${total_sources} (${pct}%) done"
    else
      rsync "${RSYNC_OPTS[@]}" "${src}/" "${RSYNC_DEST}/" >> "$RSYNC_LOG" 2>&1
    fi
  done <<< "$sources"

  progress_done_line "[sync] done (${total_sources} sources)"
  phase_end "sync"
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

###############################################################################
# CLEANUP
###############################################################################
if [ "$CLEANUP_EXTRACTED" -eq 1 ]; then
  log "$RUNINFO_LOG" "Cleanup: removing EXTRACT_BASE=$EXTRACT_BASE"
  rm -rf "$EXTRACT_BASE"
fi

log "$SUMMARY_LOG" "FINISHED at $(date)"
log "$SUMMARY_LOG" "LOG_DIR=$LOG_DIR"

say "Logs: $LOG_DIR"
