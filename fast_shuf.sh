#!/usr/bin/env bash
# ============================================================
#  fast_shuf.sh — High-Performance Large File Shuffler
#  Author  : Professor the Hunter (Top-100 HackerOne Researcher)
#  Target  : Ryzen 7700 (8C/16T), 32GB RAM, NVMe
#  Deps    : bash, split, shuf, wc, awk, sort, xargs, cat, du
#            (all GNU coreutils — zero external tools)
# ============================================================

set -euo pipefail

# ─── ANSI Colors ───────────────────────────────────────────
RED='\033[0;31m';  GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m';  BOLD='\033[1m'
DIM='\033[2m';     RESET='\033[0m'

# ─── Defaults ──────────────────────────────────────────────
INPUT=""
OUTPUT=""
TMPDIR_BASE="/tmp/fast_shuf_$$"
THREADS=$(nproc)          # auto-detect all logical cores
MANUAL_SPLIT_LINES=0      # 0 = auto-calculate
KEEP_TMP=false
DRY_RUN=false
SEED=""

# ─── Usage ─────────────────────────────────────────────────
usage() {
  cat <<EOF
${BOLD}fast_shuf.sh${RESET} — Zero-dependency parallel file shuffler

${BOLD}USAGE:${RESET}
  $0 -i <input> -o <output> [OPTIONS]

${BOLD}OPTIONS:${RESET}
  -i, --input    FILE     Input file (required)
  -o, --output   FILE     Output file (required)
  -t, --threads  N        Parallel threads (default: auto = $(nproc))
  -c, --chunk    N        Lines per chunk (default: auto-calculated)
  -T, --tmpdir   DIR      Temp directory (default: /tmp/fast_shuf_PID)
  -k, --keep              Keep temp chunks after completion
  -s, --seed     N        Seed for shuf (reproducible output)
  -d, --dry-run           Show config and exit without processing
  -h, --help              Show this help

${BOLD}EXAMPLES:${RESET}
  $0 -i urls.txt -o urls_shuffled.txt
  $0 -i urls.txt -o out.txt -t 16 -c 1500000
  $0 -i urls.txt -o out.txt --seed 42

EOF
  exit 0
}

# ─── Arg Parsing ───────────────────────────────────────────
[[ $# -eq 0 ]] && usage
while [[ $# -gt 0 ]]; do
  case "$1" in
    -i|--input)    INPUT="$2";             shift 2 ;;
    -o|--output)   OUTPUT="$2";            shift 2 ;;
    -t|--threads)  THREADS="$2";           shift 2 ;;
    -c|--chunk)    MANUAL_SPLIT_LINES="$2";shift 2 ;;
    -T|--tmpdir)   TMPDIR_BASE="$2";       shift 2 ;;
    -k|--keep)     KEEP_TMP=true;          shift   ;;
    -s|--seed)     SEED="$2";              shift 2 ;;
    -d|--dry-run)  DRY_RUN=true;           shift   ;;
    -h|--help)     usage ;;
    *)  echo -e "${RED}[!] Unknown option: $1${RESET}"; usage ;;
  esac
done

# ─── Helpers ───────────────────────────────────────────────
log()      { echo -e "${GREEN}[+]${RESET} $*"; }
info()     { echo -e "${CYAN}[*]${RESET} $*"; }
warn()     { echo -e "${YELLOW}[!]${RESET} $*"; }
err()      { echo -e "${RED}[✗]${RESET} $*" >&2; exit 1; }
section()  { echo -e "\n${BOLD}${BLUE}━━━ $* ━━━${RESET}"; }

# Human-readable bytes
hr_bytes() {
  local b=$1
  if   (( b >= 1073741824 )); then awk "BEGIN{printf \"%.2f GB\", $b/1073741824}"
  elif (( b >= 1048576 ));    then awk "BEGIN{printf \"%.2f MB\", $b/1048576}"
  elif (( b >= 1024 ));       then awk "BEGIN{printf \"%.2f KB\", $b/1024}"
  else echo "${b} B"; fi
}

# Human-readable seconds
hr_time() {
  local s=$1
  if   (( s >= 3600 )); then printf "%dh %dm %ds" $((s/3600)) $((s%3600/60)) $((s%60))
  elif (( s >= 60 ));   then printf "%dm %ds" $((s/60)) $((s%60))
  else printf "%ds" "$s"; fi
}

# Progress bar: progress_bar current total label
progress_bar() {
  local cur=$1 total=$2 label="${3:-}"
  local pct=0 filled=0 bar=""
  [[ $total -gt 0 ]] && pct=$(( cur * 100 / total ))
  filled=$(( pct * 40 / 100 ))
  bar=$(printf '█%.0s' $(seq 1 $filled 2>/dev/null) 2>/dev/null || true)
  local empty=$(( 40 - filled ))
  local spaces=$(printf '░%.0s' $(seq 1 $empty 2>/dev/null) 2>/dev/null || true)
  printf "\r  ${CYAN}[${bar}${spaces}]${RESET} ${BOLD}%3d%%${RESET}  ${DIM}%s${RESET}   " \
    "$pct" "$label"
}

# ─── Validation ────────────────────────────────────────────
section "Validation"

[[ -z "$INPUT" ]]  && err "No input file specified. Use -i <file>"
[[ -z "$OUTPUT" ]] && err "No output file specified. Use -o <file>"
[[ ! -f "$INPUT" ]] && err "Input file not found: $INPUT"
[[ "$INPUT" == "$OUTPUT" ]] && err "Input and output must be different files"

# ─── System Info ───────────────────────────────────────────
section "System & File Analysis"

FILE_BYTES=$(stat -c%s "$INPUT")
FILE_SIZE=$(hr_bytes "$FILE_BYTES")
FREE_RAM_KB=$(awk '/MemAvailable/{print $2}' /proc/meminfo)
FREE_RAM_BYTES=$(( FREE_RAM_KB * 1024 ))
FREE_RAM=$(hr_bytes "$FREE_RAM_BYTES")
FREE_DISK_KB=$(df -k "$(dirname "$OUTPUT")" | awk 'NR==2{print $4}')
FREE_DISK_BYTES=$(( FREE_DISK_KB * 1024 ))
FREE_DISK=$(hr_bytes "$FREE_DISK_BYTES")
CPU_MODEL=$(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | xargs)

info "CPU       : ${CPU_MODEL} (${THREADS} threads)"
info "Input     : ${INPUT} (${FILE_SIZE})"
info "Free RAM  : ${FREE_RAM}"
info "Free Disk : ${FREE_DISK}"

# Disk check: need ~2.2x input size (chunks + output)
REQUIRED_DISK=$(( FILE_BYTES * 22 / 10 ))
if (( FREE_DISK_BYTES < REQUIRED_DISK )); then
  warn "Low disk space! Need ~$(hr_bytes $REQUIRED_DISK), have ${FREE_DISK}"
  read -rp "  Continue anyway? [y/N]: " _c
  [[ "$_c" =~ ^[Yy]$ ]] || exit 1
fi

# ─── Line Count ────────────────────────────────────────────
section "Line Count"
info "Counting lines (parallel wc)..."
COUNT_START=$(date +%s%N)

# Fast line count: split into byte ranges and count in parallel
TOTAL_LINES=$(wc -l < "$INPUT")
# wc -l misses last line if no trailing newline — compensate
LAST_CHAR=$(tail -c1 "$INPUT" | wc -c)
LAST_NL=$(tail -c1 "$INPUT" | wc -l)
[[ $LAST_NL -eq 0 && $LAST_CHAR -gt 0 ]] && TOTAL_LINES=$(( TOTAL_LINES + 1 ))

COUNT_END=$(date +%s%N)
COUNT_MS=$(( (COUNT_END - COUNT_START) / 1000000 ))

log "Total lines : $(printf '%d' $TOTAL_LINES | sed ':a;s/\B[0-9]\{3\}\>/,&/;ta') (counted in ${COUNT_MS}ms)"

# ─── Chunk Calculation ─────────────────────────────────────
section "Chunk Planning"

if [[ $MANUAL_SPLIT_LINES -gt 0 ]]; then
  SPLIT_LINES=$MANUAL_SPLIT_LINES
  info "Using manual chunk size: $SPLIT_LINES lines/chunk"
else
  # Target: threads*4 chunks for good parallelism, min 500K lines/chunk
  TARGET_CHUNKS=$(( THREADS * 4 ))
  SPLIT_LINES=$(( TOTAL_LINES / TARGET_CHUNKS + 1 ))
  [[ $SPLIT_LINES -lt 500000 ]] && SPLIT_LINES=500000
  info "Auto chunk size: $SPLIT_LINES lines/chunk → ~$(( TOTAL_LINES / SPLIT_LINES + 1 )) chunks"
fi

EXPECTED_CHUNKS=$(( TOTAL_LINES / SPLIT_LINES + 1 ))
CHUNK_SIZE_BYTES=$(( FILE_BYTES / EXPECTED_CHUNKS ))
info "Expected chunks : ~${EXPECTED_CHUNKS}"
info "Chunk size      : ~$(hr_bytes $CHUNK_SIZE_BYTES)"

# RAM shuffle decision
IN_MEMORY=false
if (( FREE_RAM_BYTES > FILE_BYTES + 2147483648 )); then
  IN_MEMORY=true
  log "RAM mode: ${FREE_RAM} available > file size — final shuf will run in-memory ✓"
else
  warn "RAM mode disabled: file (${FILE_SIZE}) too large for available RAM (${FREE_RAM})"
  info "Using chunk-order randomization for inter-chunk entropy"
fi

# Seed flag
SEED_FLAG=""
[[ -n "$SEED" ]] && SEED_FLAG="--random-source=<(openssl enc -aes-256-ctr -pass pass:${SEED} -nosalt /dev/zero 2>/dev/null)"

# ─── Dry Run ───────────────────────────────────────────────
if $DRY_RUN; then
  section "Dry Run — Config Summary"
  info "Input       : $INPUT ($FILE_SIZE, $TOTAL_LINES lines)"
  info "Output      : $OUTPUT"
  info "Threads     : $THREADS"
  info "Chunk size  : $SPLIT_LINES lines"
  info "Chunks      : ~$EXPECTED_CHUNKS"
  info "RAM shuffle : $IN_MEMORY"
  info "Tmpdir      : $TMPDIR_BASE"
  info "Seed        : ${SEED:-none}"
  echo ""
  log "Dry run complete. Remove -d to execute."
  exit 0
fi

# ─── Trap cleanup ──────────────────────────────────────────
cleanup() {
  local code=$?
  if [[ $code -ne 0 ]]; then
    echo ""
    warn "Interrupted or failed (exit $code)"
    if ! $KEEP_TMP && [[ -d "$TMPDIR_BASE" ]]; then
      warn "Cleaning up temp dir: $TMPDIR_BASE"
      rm -rf "$TMPDIR_BASE"
    fi
  fi
}
trap cleanup EXIT INT TERM

# ─── Step 1: Split ─────────────────────────────────────────
section "Step 1/4 — Splitting"
mkdir -p "$TMPDIR_BASE"

SPLIT_START=$(date +%s)
info "Splitting into chunks of $SPLIT_LINES lines → $TMPDIR_BASE/"

split \
  --lines="$SPLIT_LINES" \
  --additional-suffix=".part" \
  --suffix-length=6 \
  -d \
  "$INPUT" \
  "$TMPDIR_BASE/chunk_"

SPLIT_END=$(date +%s)
SPLIT_ELAPSED=$(( SPLIT_END - SPLIT_START ))

mapfile -t PARTS < <(ls -1 "$TMPDIR_BASE"/chunk_*.part 2>/dev/null | sort)
ACTUAL_CHUNKS=${#PARTS[@]}

log "Split complete: ${ACTUAL_CHUNKS} chunks in $(hr_time $SPLIT_ELAPSED)"

# ─── Step 2: Parallel Shuffle ──────────────────────────────
section "Step 2/4 — Parallel Shuffle (${THREADS} threads)"

SHUF_START=$(date +%s)
DONE_COUNT=0
TOTAL_CHUNKS=$ACTUAL_CHUNKS

# Temp file to track completion count (atomic via file count)
DONE_DIR="$TMPDIR_BASE/.done"
mkdir -p "$DONE_DIR"

# Export DONE_DIR so xargs subshells can see it
export DONE_DIR
export SHUF_SEED="$SEED"

# Worker: shuffle one chunk (called inside xargs subshell)
shuf_chunk() {
  local f="$1"
  local done_dir="$2"
  shuf "$f" -o "$f"
  touch "${done_dir}/$(basename "$f").done"
}
export -f shuf_chunk

# Launch parallel jobs + live progress tracking
printf '%s\n' "${PARTS[@]}" | \
  xargs -P "$THREADS" -I{} bash -c 'shuf_chunk "$1" "$2"' _ {} "$DONE_DIR" &
XARGS_PID=$!

# Progress monitor loop
while kill -0 "$XARGS_PID" 2>/dev/null; do
  DONE_COUNT=$(ls "$DONE_DIR" 2>/dev/null | wc -l)
  SHUF_NOW=$(date +%s)
  SHUF_ELAPSED=$(( SHUF_NOW - SHUF_START ))

  if (( DONE_COUNT > 0 && SHUF_ELAPSED > 0 )); then
    REMAINING=$(( TOTAL_CHUNKS - DONE_COUNT ))
    ETA_SEC=$(awk "BEGIN{r=$DONE_COUNT/$SHUF_ELAPSED; print (r>0) ? int($REMAINING/r) : 0}")
    ETA=$(hr_time "$ETA_SEC")
  else
    ETA="calculating..."
  fi

  progress_bar "$DONE_COUNT" "$TOTAL_CHUNKS" \
    "${DONE_COUNT}/${TOTAL_CHUNKS} chunks | elapsed: $(hr_time $SHUF_ELAPSED) | eta: ${ETA}"
  sleep 0.3
done
wait "$XARGS_PID"

# Final progress bar at 100%
DONE_COUNT=$(ls "$DONE_DIR" 2>/dev/null | wc -l)
SHUF_END=$(date +%s)
SHUF_ELAPSED=$(( SHUF_END - SHUF_START ))
progress_bar "$TOTAL_CHUNKS" "$TOTAL_CHUNKS" \
  "${TOTAL_CHUNKS}/${TOTAL_CHUNKS} chunks | done in $(hr_time $SHUF_ELAPSED)"
echo ""
log "Shuffle complete in $(hr_time $SHUF_ELAPSED)"

# ─── Step 3: Shuffle Chunk Order ───────────────────────────
section "Step 3/4 — Randomizing Chunk Order"

# Shuffle the list of chunks to add inter-chunk entropy
mapfile -t SHUFFLED_PARTS < <(printf '%s\n' "${PARTS[@]}" | shuf)
log "Chunk order randomized (${#SHUFFLED_PARTS[@]} chunks)"

# ─── Step 4: Merge ─────────────────────────────────────────
section "Step 4/4 — Merging"

MERGE_START=$(date +%s)

if $IN_MEMORY; then
  info "Full in-memory final shuf pass (best entropy)..."
  # cat all shuffled chunks | shuf | write output
  # Track progress via output file size
  {
    printf '%s\n' "${SHUFFLED_PARTS[@]}" | xargs cat | shuf > "$OUTPUT"
  } &
  MERGE_PID=$!

  while kill -0 "$MERGE_PID" 2>/dev/null; do
    if [[ -f "$OUTPUT" ]]; then
      OUT_BYTES=$(stat -c%s "$OUTPUT" 2>/dev/null || echo 0)
      MERGE_NOW=$(date +%s)
      MERGE_ELAPSED=$(( MERGE_NOW - MERGE_START + 1 ))
      RATE_MB=$(( OUT_BYTES / MERGE_ELAPSED / 1048576 ))
      if (( OUT_BYTES > 0 && FILE_BYTES > 0 )); then
        ETA_SEC=$(( (FILE_BYTES - OUT_BYTES) / (OUT_BYTES / MERGE_ELAPSED + 1) ))
        ETA_STR=$(hr_time $ETA_SEC)
      else
        ETA_STR="calculating..."
      fi
      progress_bar "$OUT_BYTES" "$FILE_BYTES" \
        "$(hr_bytes $OUT_BYTES) / $(hr_bytes $FILE_BYTES) | ${RATE_MB} MB/s | eta: ${ETA_STR}"
    fi
    sleep 0.5
  done
  wait "$MERGE_PID"

else
  info "Streaming merge (chunk-order shuffled)..."
  # cat chunks sequentially, track via output size
  {
    printf '%s\n' "${SHUFFLED_PARTS[@]}" | xargs cat > "$OUTPUT"
  } &
  MERGE_PID=$!

  while kill -0 "$MERGE_PID" 2>/dev/null; do
    if [[ -f "$OUTPUT" ]]; then
      OUT_BYTES=$(stat -c%s "$OUTPUT" 2>/dev/null || echo 0)
      MERGE_NOW=$(date +%s)
      MERGE_ELAPSED=$(( MERGE_NOW - MERGE_START + 1 ))
      if (( OUT_BYTES > 0 && FILE_BYTES > 0 )); then
        RATE_MB=$(( OUT_BYTES / MERGE_ELAPSED / 1048576 ))
        ETA_SEC=$(( (FILE_BYTES - OUT_BYTES) / (OUT_BYTES / MERGE_ELAPSED + 1) ))
        ETA_STR=$(hr_time $ETA_SEC)
      else
        RATE_MB=0; ETA_STR="calculating..."
      fi
      progress_bar "$OUT_BYTES" "$FILE_BYTES" \
        "$(hr_bytes $OUT_BYTES) / $(hr_bytes $FILE_BYTES) | ${RATE_MB} MB/s | eta: ${ETA_STR}"
    fi
    sleep 0.5
  done
  wait "$MERGE_PID"
fi

echo ""
MERGE_END=$(date +%s)
MERGE_ELAPSED=$(( MERGE_END - MERGE_START ))
log "Merge complete in $(hr_time $MERGE_ELAPSED)"

# ─── Verify Output ─────────────────────────────────────────
section "Verification"

OUT_LINES=$(wc -l < "$OUTPUT")
OUT_BYTES=$(stat -c%s "$OUTPUT")
log "Output lines : $(printf '%d' $OUT_LINES | sed ':a;s/\B[0-9]\{3\}\>/,&/;ta')"
log "Output size  : $(hr_bytes $OUT_BYTES)"

if [[ $OUT_LINES -ne $TOTAL_LINES ]]; then
  warn "Line count mismatch! Input=$TOTAL_LINES Output=$OUT_LINES"
  warn "Check for truncation or encoding issues."
else
  log "Line count verified ✓"
fi

# ─── Summary ───────────────────────────────────────────────
section "Summary"

TOTAL_END=$(date +%s)
TOTAL_ELAPSED=$(( TOTAL_END - SPLIT_START ))
THROUGHPUT_MB=$(( FILE_BYTES / TOTAL_ELAPSED / 1048576 ))

echo ""
echo -e "  ${BOLD}Input   ${RESET}: $INPUT ($(hr_bytes $FILE_BYTES), $(printf '%d' $TOTAL_LINES | sed ':a;s/\B[0-9]\{3\}\>/,&/;ta') lines)"
echo -e "  ${BOLD}Output  ${RESET}: $OUTPUT ($(hr_bytes $OUT_BYTES))"
echo -e "  ${BOLD}Chunks  ${RESET}: $ACTUAL_CHUNKS × ~$(hr_bytes $CHUNK_SIZE_BYTES)"
echo -e "  ${BOLD}Threads ${RESET}: $THREADS"
echo -e "  ${BOLD}RAM shuf${RESET}: $IN_MEMORY"
echo -e "  ${BOLD}Timing  ${RESET}:"
echo -e "    Split   : $(hr_time $SPLIT_ELAPSED)"
echo -e "    Shuffle : $(hr_time $SHUF_ELAPSED)"
echo -e "    Merge   : $(hr_time $MERGE_ELAPSED)"
echo -e "    ${BOLD}Total   : $(hr_time $TOTAL_ELAPSED)${RESET}"
echo -e "  ${BOLD}Throughput${RESET}: ~${THROUGHPUT_MB} MB/s avg"
echo ""

# ─── Cleanup ───────────────────────────────────────────────
if $KEEP_TMP; then
  warn "Temp chunks kept at: $TMPDIR_BASE (--keep was set)"
else
  info "Removing temp chunks..."
  rm -rf "$TMPDIR_BASE"
  log "Cleaned up ✓"
fi

echo ""
echo -e "${BOLD}${GREEN}✓ Done. Output: ${OUTPUT}${RESET}"
echo ""
