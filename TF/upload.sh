#!/bin/bash
# ============================================================
#  Interactive S3 Batcher — Version 3.0
#  Features: RAR splits, real ETA, compression options,
#  junk filter, dry-run, summary screen, logging, pv upload
# ============================================================

# ── Colors ──────────────────────────────────────────────────
YEL='\033[1;33m'; GRN='\033[0;32m'; NC='\033[0m'
BLU='\033[1;34m'; RED='\033[0;31m'; CYN='\033[0;36m'
BLD='\033[1m'; DIM='\033[2m'

# ── Config ───────────────────────────────────────────────────
SOURCE="/home/ubuntu/downloads"
LOGFILE="$HOME/upload_log.txt"
TEMP_DIR="/home/ubuntu"
MEDIA_EXTS=("mp4" "mkv" "avi" "mov" "mp3" "flac" "aac" "jpg" "jpeg" "png" "webp")
JUNK_EXTS=("nfo" "txt" "srt" "url" "lnk" "db" "ini" "sfv" "jpg.tmp")

# ── Logging ──────────────────────────────────────────────────
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOGFILE"
}

# ── Dependency Check ─────────────────────────────────────────
check_deps() {
    local missing=()
    command -v rar   &>/dev/null || missing+=("rar")
    command -v pv    &>/dev/null || missing+=("pv")
    command -v aws   &>/dev/null || missing+=("awscli")
    if [ ${#missing[@]} -gt 0 ]; then
        echo -e "${YEL}Installing missing dependencies: ${missing[*]}${NC}"
        sudo apt-get install -y "${missing[@]}" -qq
    fi
}

# ── Human Readable Size ──────────────────────────────────────
human_size() {
    local bytes=$1
    if   [ "$bytes" -ge $((1024*1024*1024)) ]; then
        printf "%.2f GB" "$(echo "scale=2; $bytes/1073741824" | bc)"
    elif [ "$bytes" -ge $((1024*1024)) ]; then
        printf "%.2f MB" "$(echo "scale=2; $bytes/1048576" | bc)"
    else
        printf "%.2f KB" "$(echo "scale=2; $bytes/1024" | bc)"
    fi
}

# ── Get Size in Bytes ────────────────────────────────────────
get_size() {
    du -sb "$1" 2>/dev/null | awk '{print $1}'
}

# ── Real Progress Bar with ETA ───────────────────────────────
draw_progress() {
    local label="$1" current=$2 total=$3 start_time=$4
    local w=38
    local pct=0
    [ "$total" -gt 0 ] && pct=$(( current * 100 / total ))
    local fill=$(( pct * w / 100 ))
    local empty=$(( w - fill ))
    local elapsed=$(( $(date +%s) - start_time ))
    local eta_str="--:--"
    local speed_str="--"
    if [ "$elapsed" -gt 0 ] && [ "$current" -gt 0 ]; then
        local speed=$(( current / elapsed ))
        [ "$speed" -gt 0 ] && {
            local remaining=$(( (total - current) / speed ))
            eta_str=$(printf "%02d:%02d" $(( remaining/60 )) $(( remaining%60 )))
        }
        speed_str=$(human_size $speed)/s
    fi
    printf "\r${YEL}%-10s${NC} [" "$label"
    for ((i=0; i<fill;  i++)); do printf "${GRN}█${NC}"; done
    for ((i=0; i<empty; i++)); do printf "${DIM}░${NC}"; done
    printf "] ${BLD}%3d%%${NC}  ${CYN}%-10s${NC}  ETA ${YEL}%s${NC}   " \
           "$pct" "$speed_str" "$eta_str"
}

# ── Watch Zip Progress ───────────────────────────────────────
watch_zip_progress() {
    local outfile="$1" total_bytes=$2 pid=$3 label="$4"
    local start=$(date +%s)
    while kill -0 "$pid" 2>/dev/null; do
        local current=0
        [ -f "$outfile" ] && current=$(stat -c%s "$outfile" 2>/dev/null || echo 0)
        # For RAR splits, sum all parts
        if [[ "$outfile" == *.rar ]]; then
            local base="${outfile%.rar}"
            current=$(du -sb "${base}"*.rar 2>/dev/null | awk '{s+=$1}END{print s+0}')
        fi
        draw_progress "$label" "$current" "$total_bytes" "$start"
        sleep 0.5
    done
    draw_progress "$label" "$total_bytes" "$total_bytes" "$start"
    echo -e "\n${GRN}✓ Done!${NC}"
}

# ── Is Media File (skip compression) ────────────────────────
is_media() {
    local ext="${1##*.}"
    ext="${ext,,}"
    for m in "${MEDIA_EXTS[@]}"; do [ "$ext" = "$m" ] && return 0; done
    return 1
}

# ── Is Junk File ─────────────────────────────────────────────
is_junk() {
    local ext="${1##*.}"
    ext="${ext,,}"
    for j in "${JUNK_EXTS[@]}"; do [ "$ext" = "$j" ] && return 0; done
    return 1
}

# ════════════════════════════════════════════════════════════
#  MAIN
# ════════════════════════════════════════════════════════════
clear
echo -e "${BLD}${GRN}"
echo "  ╔══════════════════════════════════════════╗"
echo "  ║     Interactive S3 Batcher  v3.0         ║"
echo "  ╚══════════════════════════════════════════╝${NC}"
echo ""

log "=== Session started ==="
check_deps

# ── Bucket Detection ─────────────────────────────────────────
BUCKET=$(aws s3 ls | awk '{print $3}' | grep "mybuckets123tarunv6" | head -n 1)
if [ -z "$BUCKET" ]; then
    echo -e "${RED}No matching bucket found. Enter bucket name manually:${NC}"
    read -rp "Bucket: " BUCKET
fi
echo -e "${BLU}Bucket : ${BLD}$BUCKET${NC}"

# ── S3 Prefix ────────────────────────────────────────────────
read -rp "$(echo -e ${YEL})S3 folder/prefix (leave blank for root): $(echo -e ${NC})" S3_PREFIX
S3_PREFIX="${S3_PREFIX%/}"
[ -n "$S3_PREFIX" ] && S3_PREFIX="$S3_PREFIX/"

# ── Disk Space ───────────────────────────────────────────────
AVAILABLE_KB=$(df /home/ubuntu | tail -1 | awk '{print $4}')
AVAILABLE_BYTES=$(( AVAILABLE_KB * 1024 ))
echo -e "${BLU}Available disk: $(human_size $AVAILABLE_BYTES)${NC}\n"

# ── Dry Run? ─────────────────────────────────────────────────
DRY_RUN=false
read -rp "$(echo -e ${YEL})Dry run? (shows plan, no actual zipping/uploading) [y/N]: $(echo -e ${NC})" DR
[[ "$DR" =~ ^[Yy]$ ]] && DRY_RUN=true && echo -e "${CYN}[DRY RUN MODE]${NC}"

# ── Global Password ──────────────────────────────────────────
echo ""
read -rsp "$(echo -e ${YEL})Default archive password (Enter to skip): $(echo -e ${NC})" GLOBAL_PASS
echo ""

# ── Junk Filter ──────────────────────────────────────────────
FILTER_JUNK=true
read -rp "$(echo -e ${YEL})Auto-skip junk files (.nfo .srt .txt etc)? [Y/n]: $(echo -e ${NC})" FJ
[[ "$FJ" =~ ^[Nn]$ ]] && FILTER_JUNK=false

# ── Min File Size Filter ─────────────────────────────────────
read -rp "$(echo -e ${YEL})Skip files smaller than (MB, 0 = no limit): $(echo -e ${NC})" MIN_MB
MIN_BYTES=$(( ${MIN_MB:-0} * 1024 * 1024 ))

# ── Delete Originals? ────────────────────────────────────────
DELETE_ORIGINALS=false
read -rp "$(echo -e ${YEL})Delete original files after successful upload? [y/N]: $(echo -e ${NC})" DO
[[ "$DO" =~ ^[Yy]$ ]] && DELETE_ORIGINALS=true

# ── Source Dir ───────────────────────────────────────────────
cd "$SOURCE" 2>/dev/null || { echo -e "${RED}Cannot access $SOURCE${NC}"; exit 1; }

# ── Scan Files ───────────────────────────────────────────────
echo -e "\n${GRN}--- Files in $SOURCE ---${NC}"
VALID_FILES=()
for ITEM in *; do
    [ -e "$ITEM" ] || continue
    # Junk filter
    if $FILTER_JUNK && is_junk "$ITEM"; then
        echo -e "  ${DIM}⊗ Junk skipped: $ITEM${NC}"
        continue
    fi
    # Size filter
    FSIZE=$(get_size "$SOURCE/$ITEM")
    if [ "${MIN_BYTES}" -gt 0 ] && [ "${FSIZE:-0}" -lt "$MIN_BYTES" ]; then
        echo -e "  ${DIM}⊗ Too small skipped: $ITEM ($(human_size ${FSIZE:-0}))${NC}"
        continue
    fi
    VALID_FILES+=("$ITEM")
done

if [ ${#VALID_FILES[@]} -eq 0 ]; then
    echo -e "${YEL}No files to process after filtering.${NC}"
    exit 1
fi

# ── Batch Setup ──────────────────────────────────────────────
echo ""
read -rp "$(echo -e ${YEL})How many archives to create? $(echo -e ${NC})" ZIP_COUNT

declare -A ZIP_NAMES
declare -A ZIP_FORMAT      # zip or rar
declare -A ZIP_SPLIT       # split size in MB, 0 = no split
declare -A ZIP_LEVEL       # compression level 0-9
declare -A ZIP_PASS        # per-archive password
declare -A FILE_ASSIGNMENTS

for i in $(seq 1 "$ZIP_COUNT"); do
    echo -e "\n${CYN}── Archive #$i ──────────────────────────${NC}"
    read -rp "  Name: " NAME
    ZIP_NAMES[$i]="$NAME"

    # Format
    echo -e "  Format:  ${YEL}1) ZIP   2) RAR${NC}"
    read -rp "  Choice [1/2, default 1]: " FMT
    [[ "$FMT" == "2" ]] && ZIP_FORMAT[$i]="rar" || ZIP_FORMAT[$i]="zip"

    # Split
    read -rp "  Split into parts? Enter size in MB (0 = no split): " SPLIT_MB
    ZIP_SPLIT[$i]="${SPLIT_MB:-0}"

    # Compression level
    echo -e "  Compression: ${YEL}0=store(fastest) → 9=max(smallest)${NC}"
    read -rp "  Level [0-9, default 5]: " LVL
    ZIP_LEVEL[$i]="${LVL:-5}"

    # Per-archive password
    read -rsp "  Password (Enter = use default '$GLOBAL_PASS'): " APASS
    echo ""
    [ -z "$APASS" ] && APASS="$GLOBAL_PASS"
    ZIP_PASS[$i]="$APASS"

    FILE_ASSIGNMENTS[$i]=""
done

# ── Assign Files ─────────────────────────────────────────────
echo -e "\n${YEL}--- Assign Files to Archives ---${NC}"
for ITEM in "${VALID_FILES[@]}"; do
    FSIZE=$(get_size "$SOURCE/$ITEM")
    echo -e "\n  ${BLD}${YEL}$ITEM${NC}  ${DIM}($(human_size ${FSIZE:-0}))${NC}"
    for i in $(seq 1 "$ZIP_COUNT"); do
        echo -e "  $i) ${ZIP_NAMES[$i]}  [${ZIP_FORMAT[$i]}]"
    done
    read -rp "  Assign to (1-$ZIP_COUNT) or 's' to skip: " CHOICE
    if [[ "$CHOICE" =~ ^[0-9]+$ ]] && [ "$CHOICE" -le "$ZIP_COUNT" ]; then
        FILE_ASSIGNMENTS[$CHOICE]+="$ITEM"$'\n'
        echo -e "  ${GRN}✓ → ${ZIP_NAMES[$CHOICE]}${NC}"
    else
        echo -e "  ${DIM}⊗ Skipped${NC}"
    fi
done

# ── Calculate Total Size ─────────────────────────────────────
TOTAL_SIZE=0
for i in $(seq 1 "$ZIP_COUNT"); do
    while IFS= read -r ITEM; do
        [ -z "$ITEM" ] && continue
        [ -e "$SOURCE/$ITEM" ] || continue
        SZ=$(get_size "$SOURCE/$ITEM")
        TOTAL_SIZE=$(( TOTAL_SIZE + ${SZ:-0} ))
    done <<< "${FILE_ASSIGNMENTS[$i]}"
done

# ── Summary Screen ───────────────────────────────────────────
echo -e "\n${BLD}${GRN}════════ SUMMARY ════════${NC}"
echo -e "  Bucket      : ${BLD}s3://$BUCKET/$S3_PREFIX${NC}"
echo -e "  Total size  : ${BLD}$(human_size $TOTAL_SIZE)${NC}"
echo -e "  Disk free   : ${BLD}$(human_size $AVAILABLE_BYTES)${NC}"
echo -e "  Dry run     : ${BLD}$DRY_RUN${NC}"
echo -e "  Del originals: ${BLD}$DELETE_ORIGINALS${NC}"
echo ""
for i in $(seq 1 "$ZIP_COUNT"); do
    [ -z "${FILE_ASSIGNMENTS[$i]}" ] && continue
    COUNT=$(echo "${FILE_ASSIGNMENTS[$i]}" | grep -c '\S')
    echo -e "  Archive #$i  : ${BLD}${ZIP_NAMES[$i]}.${ZIP_FORMAT[$i]}${NC}  |  $COUNT file(s)  |  level ${ZIP_LEVEL[$i]}  |  split ${ZIP_SPLIT[$i]}MB  |  pass $([ -n "${ZIP_PASS[$i]}" ] && echo '***' || echo 'none')"
done

if (( TOTAL_SIZE > AVAILABLE_BYTES )); then
    echo -e "\n${RED}✗ Not enough disk space! Aborting.${NC}"
    log "ABORT: Not enough disk space. Required $(human_size $TOTAL_SIZE), available $(human_size $AVAILABLE_BYTES)"
    exit 1
fi

echo ""
read -rp "$(echo -e ${YEL})Proceed? [Y/n]: $(echo -e ${NC})" CONFIRM
[[ "$CONFIRM" =~ ^[Nn]$ ]] && echo -e "${YEL}Aborted.${NC}" && exit 0

# ── Process Each Archive ─────────────────────────────────────
echo -e "\n${GRN}--- Processing ---${NC}"
log "Processing $ZIP_COUNT archive(s)"

for i in $(seq 1 "$ZIP_COUNT"); do
    NAME="${ZIP_NAMES[$i]}"
    FMT="${ZIP_FORMAT[$i]}"
    SPLIT="${ZIP_SPLIT[$i]}"
    LVL="${ZIP_LEVEL[$i]}"
    PASS="${ZIP_PASS[$i]}"

    [ -z "${FILE_ASSIGNMENTS[$i]}" ] && continue

    echo -e "\n${BLU}${BLD}▶ Archive: $NAME.$FMT${NC}"
    log "Starting archive: $NAME.$FMT"

    # Build file list
    FILE_LIST=()
    ARCHIVE_SIZE=0
    while IFS= read -r ITEM; do
        [ -z "$ITEM" ] && continue
        FILE_LIST+=("$ITEM")
        SZ=$(get_size "$SOURCE/$ITEM")
        ARCHIVE_SIZE=$(( ARCHIVE_SIZE + ${SZ:-0} ))
    done <<< "${FILE_ASSIGNMENTS[$i]}"

    OUTFILE="$TEMP_DIR/$NAME.$FMT"

    if $DRY_RUN; then
        echo -e "  ${CYN}[DRY RUN] Would archive: ${FILE_LIST[*]}${NC}"
        echo -e "  ${CYN}[DRY RUN] Output: $OUTFILE  ($(human_size $ARCHIVE_SIZE))${NC}"
        $DELETE_ORIGINALS && echo -e "  ${CYN}[DRY RUN] Would delete originals after upload${NC}"
        log "DRY RUN: $NAME.$FMT — ${FILE_LIST[*]}"
        continue
    fi

    cd "$SOURCE" || exit

    # ── Check if media only (store mode) ─────────────────────
    ALL_MEDIA=true
    for F in "${FILE_LIST[@]}"; do
        is_media "$F" || { ALL_MEDIA=false; break; }
    done
    if $ALL_MEDIA && [ "$LVL" -gt 0 ]; then
        echo -e "  ${DIM}All files are media — switching to store mode (level 0)${NC}"
        LVL=0
    fi

    # ── ZIP ───────────────────────────────────────────────────
    if [ "$FMT" = "zip" ]; then
        if [ "${SPLIT:-0}" -gt 0 ]; then
            # zip doesn't do clean splits — use zip then zsplit trick
            # Actually we use zip normally, then split with proper ext
            ZIP_ARGS=("-r" "-$LVL")
            [ -n "$PASS" ] && ZIP_ARGS+=("-P" "$PASS")
            echo "${FILE_LIST[@]}" | tr ' ' '\n' | \
                zip "${ZIP_ARGS[@]}" "$OUTFILE" "${FILE_LIST[@]}" > /dev/null 2>&1 &
            ZIP_PID=$!
            watch_zip_progress "$OUTFILE" "$ARCHIVE_SIZE" "$ZIP_PID" "Zipping"
            wait "$ZIP_PID"
            # Split into parts with .zip extension
            SPLIT_BYTES=$(( SPLIT * 1024 * 1024 ))
            split -b "$SPLIT_BYTES" -d --additional-suffix=".zip" "$OUTFILE" "$TEMP_DIR/${NAME}.part"
            rm -f "$OUTFILE"
            OUTFILE="$TEMP_DIR/${NAME}.part*.zip"
        else
            ZIP_ARGS=("-r" "-$LVL")
            [ -n "$PASS" ] && ZIP_ARGS+=("-P" "$PASS")
            zip "${ZIP_ARGS[@]}" "$OUTFILE" "${FILE_LIST[@]}" > /dev/null 2>&1 &
            ZIP_PID=$!
            watch_zip_progress "$OUTFILE" "$ARCHIVE_SIZE" "$ZIP_PID" "Zipping"
            wait "$ZIP_PID"
        fi

    # ── RAR ───────────────────────────────────────────────────
    else
        RAR_ARGS=("a" "-r" "-m$LVL" "-ep1")
        [ "${SPLIT:-0}" -gt 0 ] && RAR_ARGS+=("-v${SPLIT}m")
        [ -n "$PASS" ] && RAR_ARGS+=("-p$PASS")
        RAR_ARGS+=("$OUTFILE" "${FILE_LIST[@]}")
        rar "${RAR_ARGS[@]}" > /dev/null 2>&1 &
        RAR_PID=$!
        watch_zip_progress "$OUTFILE" "$ARCHIVE_SIZE" "$RAR_PID" "Compressing"
        wait "$RAR_PID"
    fi

    # ── Upload ────────────────────────────────────────────────
    shopt -s nullglob
    UPLOAD_FILES=( "$TEMP_DIR/${NAME}"*.zip "$TEMP_DIR/${NAME}"*.rar )
    shopt -u nullglob

    for UF in "${UPLOAD_FILES[@]}"; do
        [ -f "$UF" ] || continue
        UF_SIZE=$(stat -c%s "$UF")
        UF_BASE=$(basename "$UF")
        echo -e "\n${YEL}Uploading: $UF_BASE ($(human_size $UF_SIZE))${NC}"
        log "Uploading $UF_BASE to s3://$BUCKET/$S3_PREFIX$UF_BASE"

        START_UP=$(date +%s)
        (
            pv -pterb -s "$UF_SIZE" "$UF" | \
            aws s3 cp - "s3://$BUCKET/$S3_PREFIX$UF_BASE" \
                --region ap-south-2 \
                --expected-size "$UF_SIZE" \
                --no-progress 2>/dev/null
        )
        UP_EXIT=$?

        if [ $UP_EXIT -eq 0 ]; then
            # Verify via head-object
            aws s3api head-object --bucket "$BUCKET" \
                --key "${S3_PREFIX}${UF_BASE}" &>/dev/null
            if [ $? -eq 0 ]; then
                echo -e "${GRN}✓ Verified in S3: $UF_BASE${NC}"
                log "SUCCESS: $UF_BASE uploaded and verified"
                rm -f "$UF"
            else
                echo -e "${RED}✗ Upload succeeded but S3 verification failed: $UF_BASE${NC}"
                log "WARN: $UF_BASE upload ok but head-object failed"
            fi
        else
            echo -e "${RED}✗ Upload failed: $UF_BASE${NC}"
            log "FAIL: $UF_BASE upload failed"
        fi
    done

    # ── Delete Originals ──────────────────────────────────────
    if $DELETE_ORIGINALS; then
        for F in "${FILE_LIST[@]}"; do
            if [ -e "$SOURCE/$F" ]; then
                rm -rf "$SOURCE/$F"
                echo -e "  ${DIM}Deleted original: $F${NC}"
                log "Deleted original: $F"
            fi
        done
    fi
done

echo -e "\n${BLD}${GRN}════════ All Batches Complete ════════${NC}"
echo -e "${BLU}Log saved to: $LOGFILE${NC}"
log "===== Session completed ====="