#!/bin/bash
# ============================================================
#  Interactive S3 Batcher — Version 4.0 (AI Powered)
#  Features: RAR splits, real ETA, compression options,
#  junk filter, dry-run, summary screen, logging, pv upload,
#  + SMART SEQUENTIAL PART MODE (space-compensating bin packing)
#  + NLP ACTOR GROUPING (Zero-touch automated spaCy NER + Genderize)
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
    command -v rar    &>/dev/null || missing+=("rar")
    command -v pv     &>/dev/null || missing+=("pv")
    command -v aws    &>/dev/null || missing+=("awscli")
    command -v curl   &>/dev/null || missing+=("curl")
    command -v python3 &>/dev/null || missing+=("python3")

    if [ ${#missing[@]} -gt 0 ]; then
        echo -e "${YEL}Installing missing system dependencies: ${missing[*]}${NC}"
        sudo apt-get install -y "${missing[@]}" -qq
    fi

    if ! python3 -c "import spacy" &>/dev/null; then
        echo -e "${RED}✗ Missing Python library: spaCy${NC}"
        echo -e "This script uses AI for name detection. Please install it:"
        echo -e "  pip3 install spacy"
        echo -e "  python3 -m spacy download en_core_web_sm"
        exit 1
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

# ── Get Free Disk Space (bytes) ───────────────────────────────
get_free_bytes() {
    local kb
    kb=$(df "$TEMP_DIR" | tail -1 | awk '{print $4}')
    echo $(( kb * 1024 ))
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

# ── Upload Single File (returns 0 on verified success) ───────
upload_file() {
    local UF="$1" UF_BASE UF_SIZE
    [ -f "$UF" ] || return 1
    UF_SIZE=$(stat -c%s "$UF")
    UF_BASE=$(basename "$UF")
    echo -e "\n${YEL}Uploading: $UF_BASE ($(human_size $UF_SIZE))${NC}"
    log "Uploading $UF_BASE to s3://$BUCKET/$S3_PREFIX$UF_BASE"

    (
        pv -pterb -s "$UF_SIZE" "$UF" | \
        aws s3 cp - "s3://$BUCKET/$S3_PREFIX$UF_BASE" \
            --region ap-south-2 \
            --expected-size "$UF_SIZE" \
            --no-progress 2>/dev/null
    )
    local UP_EXIT=$?

    if [ $UP_EXIT -eq 0 ]; then
        aws s3api head-object --bucket "$BUCKET" \
            --key "${S3_PREFIX}${UF_BASE}" &>/dev/null
        if [ $? -eq 0 ]; then
            echo -e "${GRN}✓ Verified in S3: $UF_BASE${NC}"
            log "SUCCESS: $UF_BASE uploaded and verified"
            return 0
        else
            echo -e "${RED}✗ Upload succeeded but S3 verification failed: $UF_BASE${NC}"
            return 1
        fi
    else
        echo -e "${RED}✗ Upload failed: $UF_BASE${NC}"
        return 1
    fi
}

# ── Bin-Pack Files Into Sequential Parts ──────────────────────
bin_pack_files() {
    local part_limit_bytes=$1; shift
    local -a files=("$@")
    BIN_PARTS=()
    local current_part="" current_size=0

    for F in "${files[@]}"; do
        local SZ
        SZ=$(get_size "$SOURCE/$F")
        SZ=${SZ:-0}

        if [ "$SZ" -gt "$part_limit_bytes" ]; then
            if [ -n "$current_part" ]; then
                BIN_PARTS+=("$current_part")
                current_part=""; current_size=0
            fi
            BIN_PARTS+=("$F"$'\n')
            continue
        fi

        if [ $(( current_size + SZ )) -gt "$part_limit_bytes" ] && [ -n "$current_part" ]; then
            BIN_PARTS+=("$current_part")
            current_part=""; current_size=0
        fi

        current_part+="$F"$'\n'
        current_size=$(( current_size + SZ ))
    done

    [ -n "$current_part" ] && BIN_PARTS+=("$current_part")
}

# ── Process Archive in SMART SEQUENTIAL PART MODE ─────────────
process_smart_sequential() {
    local NAME="$1" FMT="$2" LVL="$3" PASS="$4"
    shift 4
    local -a FILE_LIST=("$@")

    local free_bytes
    free_bytes=$(get_free_bytes)
    local part_limit_bytes=$(( free_bytes * 95 / 100 ))

    if [ "$part_limit_bytes" -le 0 ]; then
        echo -e "${RED}✗ Not enough free space to build even one part for $NAME.${NC}"
        return 1
    fi

    bin_pack_files "$part_limit_bytes" "${FILE_LIST[@]}"
    local NUM_PARTS=${#BIN_PARTS[@]}

    if [ "$NUM_PARTS" -eq 0 ]; then
        echo -e "${YEL}Nothing to do for $NAME.${NC}"
        return 0
    fi

    echo -e "  ${CYN}[SMART MODE] $NAME will be split into $NUM_PARTS part(s) (~$(human_size $part_limit_bytes) max/part)${NC}"
    log "SMART MODE: $NAME -> $NUM_PARTS part(s)"

    local PART_NUM=1
    for PART_FILES in "${BIN_PARTS[@]}"; do
        local -a CUR_FILES=()
        local PART_SIZE=0
        while IFS= read -r ITEM; do
            [ -z "$ITEM" ] && continue
            CUR_FILES+=("$ITEM")
            SZ=$(get_size "$SOURCE/$ITEM")
            PART_SIZE=$(( PART_SIZE + ${SZ:-0} ))
        done <<< "$PART_FILES"

        local PART_NAME="${NAME}.part${PART_NUM}"
        local OUTFILE="$TEMP_DIR/${PART_NAME}.${FMT}"

        echo -e "\n${BLU}${BLD}▶ $PART_NAME.$FMT${NC}  (${#CUR_FILES[@]} file(s), $(human_size $PART_SIZE))"

        local PART_LVL="$LVL"
        local ALL_MEDIA=true
        for F in "${CUR_FILES[@]}"; do
            is_media "$F" || { ALL_MEDIA=false; break; }
        done
        if $ALL_MEDIA && [ "$PART_LVL" -gt 0 ]; then
            PART_LVL=0
        fi

        cd "$SOURCE" || return 1

        if [ "$FMT" = "zip" ]; then
            local ZIP_ARGS=("-r" "-$PART_LVL")
            [ -n "$PASS" ] && ZIP_ARGS+=("-P" "$PASS")
            zip "${ZIP_ARGS[@]}" "$OUTFILE" "${CUR_FILES[@]}" > /dev/null 2>&1 &
            local PID=$!
            watch_zip_progress "$OUTFILE" "$PART_SIZE" "$PID" "Zipping"
            wait "$PID"
        else
            local RAR_ARGS=("a" "-r" "-m$PART_LVL" "-ep1")
            [ -n "$PASS" ] && RAR_ARGS+=("-p$PASS")
            RAR_ARGS+=("$OUTFILE" "${CUR_FILES[@]}")
            rar "${RAR_ARGS[@]}" > /dev/null 2>&1 &
            local PID=$!
            watch_zip_progress "$OUTFILE" "$PART_SIZE" "$PID" "Compressing"
            wait "$PID"
        fi

        if [ -f "$OUTFILE" ]; then
            if upload_file "$OUTFILE"; then
                rm -f "$OUTFILE"
                for F in "${CUR_FILES[@]}"; do
                    if [ -e "$SOURCE/$F" ]; then
                        rm -rf "$SOURCE/$F"
                        echo -e "  ${DIM}Freed space, deleted original: $F${NC}"
                    fi
                done
            else
                echo -e "${RED}✗ Aborting $NAME — part upload failed.${NC}"
                return 1
            fi
        else
            return 1
        fi

        PART_NUM=$(( PART_NUM + 1 ))
    done

    echo -e "${GRN}✓ Smart mode complete for $NAME${NC}"
    return 0
}

# ════════════════════════════════════════════════════════════
#  ACTOR GROUPING FUNCTIONS (NLP AUTOMATED)
# ════════════════════════════════════════════════════════════
sanitize_name() {
    echo "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/_/g' | sed 's/__*/_/g' | sed 's/^_//;s/_$//'
}

run_actor_grouping() {
    echo -e "\n${CYN}${BLD}── AI Actor Grouping Mode (spaCy NLP) ──────────${NC}"
    log "Actor grouping: scanning ${#VALID_FILES[@]} files with NLP"

    declare -A ACTOR_FILES
    declare -A ACTOR_DISPLAY
    declare -A ACTOR_GENDER
    declare -A GENDER_CACHE

    echo -e "  ${DIM}Analyzing filenames with Natural Language Processing...${NC}"

    # Feed all filenames into a single Python NLP process
    local nlp_output
    nlp_output=$(printf "%s\n" "${VALID_FILES[@]}" | python3 -c "
import sys, warnings
warnings.filterwarnings('ignore')
try:
    import spacy
    nlp = spacy.load('en_core_web_sm')
    for line in sys.stdin:
        filename = line.strip()
        if not filename: continue
        # Format string to help NLP identify names
        base = filename.rsplit('.', 1)[0]
        clean_name = base.replace('_', ' ').replace('-', ' ').replace('.', ' ').title()

        doc = nlp(clean_name)
        for ent in doc.ents:
            if ent.label_ == 'PERSON':
                print(f\"{filename}|{ent.text}\")
except Exception:
    pass
" 2>/dev/null)

    if [ -z "$nlp_output" ]; then
        echo -e "${YEL}  No actor names detected. Skipping grouping.${NC}"
        return 1
    fi

    # Parse NLP output and fetch genders via API
    while IFS='|' read -r ITEM CANDIDATE; do
        [ -z "$CANDIDATE" ] && continue
        local KEY
        KEY=$(sanitize_name "$CANDIDATE")
        [ -z "$KEY" ] && continue

        if [ -z "${ACTOR_DISPLAY[$KEY]+x}" ]; then
            ACTOR_DISPLAY[$KEY]="$CANDIDATE"
            ACTOR_FILES[$KEY]=""

            # Dynamically fetch gender
            local FIRST_WORD
            FIRST_WORD=$(echo "$CANDIDATE" | awk '{print $1}' | tr '[:upper:]' '[:lower:]')

            if [ -n "${GENDER_CACHE[$FIRST_WORD]}" ]; then
                ACTOR_GENDER[$KEY]="${GENDER_CACHE[$FIRST_WORD]}"
            else
                local gender_res
                gender_res=$(curl -s --max-time 3 "https://api.genderize.io/?name=${FIRST_WORD}" | grep -o '"gender":"[^"]*"' | cut -d'"' -f4)
                if [ "$gender_res" = "female" ]; then
                    ACTOR_GENDER[$KEY]="F"; GENDER_CACHE[$FIRST_WORD]="F"
                elif [ "$gender_res" = "male" ]; then
                    ACTOR_GENDER[$KEY]="M"; GENDER_CACHE[$FIRST_WORD]="M"
                else
                    ACTOR_GENDER[$KEY]="?"; GENDER_CACHE[$FIRST_WORD]="?"
                fi
            fi
        fi
        ACTOR_FILES[$KEY]+="$ITEM"$'\n'
    done <<< "$nlp_output"

    # Deduplicate file lists
    declare -A ACTOR_FILES_DEDUP
    for KEY in "${!ACTOR_FILES[@]}"; do
        ACTOR_FILES_DEDUP[$KEY]=$(echo "${ACTOR_FILES[$KEY]}" | sort -u | grep -v '^$')
    done

    # Collect unmatched files
    local UNMATCHED_FILES=""
    for ITEM in "${VALID_FILES[@]}"; do
        local matched=false
        for KEY in "${!ACTOR_FILES_DEDUP[@]}"; do
            if echo "${ACTOR_FILES_DEDUP[$KEY]}" | grep -qxF "$ITEM"; then
                matched=true
                break
            fi
        done
        $matched || UNMATCHED_FILES+="$ITEM"$'\n'
    done

    # Show detected groups
    echo -e "\n${YEL}  Detected actor groups:${NC}"
    echo -e "  ${DIM}──────────────────────────────────────────────${NC}"

    local -a SORTED_KEYS=()
    for KEY in "${!ACTOR_GENDER[@]}"; do [ "${ACTOR_GENDER[$KEY]}" = "F" ] && SORTED_KEYS+=("F:$KEY"); done
    for KEY in "${!ACTOR_GENDER[@]}"; do [ "${ACTOR_GENDER[$KEY]}" = "M" ] && SORTED_KEYS+=("M:$KEY"); done
    for KEY in "${!ACTOR_GENDER[@]}"; do [ "${ACTOR_GENDER[$KEY]}" = "?" ] && SORTED_KEYS+=("?:$KEY"); done

    local -a DISPLAY_ORDER=()
    for ENTRY in "${SORTED_KEYS[@]}"; do
        local KEY="${ENTRY#*:}"
        local GENDER="${ACTOR_GENDER[$KEY]}"
        local CNT
        CNT=$(echo "${ACTOR_FILES_DEDUP[$KEY]}" | grep -c '\S' || true)
        local TAG="[?]"; local COLOR="$DIM"
        [ "$GENDER" = "F" ] && TAG="[F]" && COLOR="\033[0;35m"
        [ "$GENDER" = "M" ] && TAG="[M]" && COLOR="\033[0;34m"

        printf "  ${COLOR}${TAG}${NC}  %-22s  %s file(s)\n" "${ACTOR_DISPLAY[$KEY]}" "$CNT"
        DISPLAY_ORDER+=("$KEY")
    done

    local UNMATCHED_CNT=0
    if [ -n "$UNMATCHED_FILES" ]; then
        UNMATCHED_CNT=$(echo "$UNMATCHED_FILES" | grep -c '\S' || true)
        printf "  ${DIM}[?]  %-22s  %s file(s)${NC}\n" "Unmatched" "$UNMATCHED_CNT"
    fi
    echo -e "  ${DIM}──────────────────────────────────────────────${NC}"

    # Auto-assign archive names
    echo -e "\n${YEL}  Auto-assigning archive names based on NLP...${NC}"
    declare -A ACTOR_ALIAS
    for KEY in "${DISPLAY_ORDER[@]}"; do
        local DEFAULT_NAME
        DEFAULT_NAME=$(echo "${ACTOR_DISPLAY[$KEY]}" | tr ' ' '_')
        DEFAULT_NAME=$(echo "$DEFAULT_NAME" | sed 's/[^a-zA-Z0-9_]/_/g' | sed 's/__*/_/g' | sed 's/^_//;s/_$//')
        ACTOR_ALIAS[$KEY]="$DEFAULT_NAME"
        echo -e "  ${GRN}✓ Assumed alias:${NC} $DEFAULT_NAME"
    done

    local UNMATCHED_ALIAS="misc"
    if [ "$UNMATCHED_CNT" -gt 0 ]; then
        echo -e "  ${DIM}✓ Assumed alias: $UNMATCHED_ALIAS (for unmatched files)${NC}"
    fi

    # Handle shared files
    local HAS_SHARED=false
    for ITEM in "${VALID_FILES[@]}"; do
        local hit=0
        for KEY in "${DISPLAY_ORDER[@]}"; do
            echo "${ACTOR_FILES_DEDUP[$KEY]}" | grep -qxF "$ITEM" && hit=$(( hit + 1 ))
        done
        [ "$hit" -gt 1 ] && HAS_SHARED=true && break
    done
    [ "$HAS_SHARED" = true ] && echo -e "  ${DIM}ℹ Collab files detected. Auto-duplicating into respective archives.${NC}"

    # Populate standard globals
    ZIP_COUNT=0
    unset ZIP_NAMES ZIP_FORMAT ZIP_SPLIT ZIP_LEVEL ZIP_PASS ZIP_MODE FILE_ASSIGNMENTS
    declare -gA ZIP_NAMES ZIP_FORMAT ZIP_SPLIT ZIP_LEVEL ZIP_PASS ZIP_MODE FILE_ASSIGNMENTS

    local IDX=0
    for KEY in "${DISPLAY_ORDER[@]}"; do
        IDX=$(( IDX + 1 ))
        ZIP_NAMES[$IDX]="${ACTOR_ALIAS[$KEY]}"
        ZIP_FORMAT[$IDX]="rar"
        ZIP_SPLIT[$IDX]="0"
        ZIP_LEVEL[$IDX]="0"
        ZIP_PASS[$IDX]="$GLOBAL_PASS"
        ZIP_MODE[$IDX]="normal"
        FILE_ASSIGNMENTS[$IDX]="${ACTOR_FILES_DEDUP[$KEY]}"
    done
    if [ -n "$UNMATCHED_FILES" ] && [ "$UNMATCHED_CNT" -gt 0 ]; then
        IDX=$(( IDX + 1 ))
        ZIP_NAMES[$IDX]="$UNMATCHED_ALIAS"
        ZIP_FORMAT[$IDX]="rar"
        ZIP_SPLIT[$IDX]="0"
        ZIP_LEVEL[$IDX]="0"
        ZIP_PASS[$IDX]="$GLOBAL_PASS"
        ZIP_MODE[$IDX]="normal"
        FILE_ASSIGNMENTS[$IDX]="$UNMATCHED_FILES"
    fi

    ZIP_COUNT=$IDX
    log "Actor grouping complete: $ZIP_COUNT archives configured"
    return 0
}

# ════════════════════════════════════════════════════════════
#  MAIN
# ════════════════════════════════════════════════════════════
clear
echo -e "${BLD}${GRN}"
echo "  ╔══════════════════════════════════════════╗"
echo "  ║      Interactive S3 Batcher  v4.0        ║"
echo "  ╚══════════════════════════════════════════╝${NC}"
echo ""

log "=== Session started ==="
check_deps

BUCKET="mybuckets123tarunv6"
echo -e "${BLU}Bucket : ${BLD}$BUCKET${NC}"

read -rp "$(echo -e ${YEL})S3 folder/prefix (leave blank for root): $(echo -e ${NC})" S3_PREFIX
S3_PREFIX="${S3_PREFIX%/}"
[ -n "$S3_PREFIX" ] && S3_PREFIX="$S3_PREFIX/"

AVAILABLE_KB=$(df /home/ubuntu | tail -1 | awk '{print $4}')
AVAILABLE_BYTES=$(( AVAILABLE_KB * 1024 ))
echo -e "${BLU}Available disk: $(human_size $AVAILABLE_BYTES)${NC}\n"

DRY_RUN=false
read -rp "$(echo -e ${YEL})Dry run? (shows plan, no actual zipping/uploading) [y/N]: $(echo -e ${NC})" DR
[[ "$DR" =~ ^[Yy]$ ]] && DRY_RUN=true && echo -e "${CYN}[DRY RUN MODE]${NC}"

echo ""
read -rsp "$(echo -e ${YEL})Default archive password (Enter to skip): $(echo -e ${NC})" GLOBAL_PASS
echo ""

FILTER_JUNK=true
read -rp "$(echo -e ${YEL})Auto-skip junk files (.nfo .srt .txt etc)? [Y/n]: $(echo -e ${NC})" FJ
[[ "$FJ" =~ ^[Nn]$ ]] && FILTER_JUNK=false

read -rp "$(echo -e ${YEL})Skip files smaller than (MB, 0 = no limit): $(echo -e ${NC})" MIN_MB
MIN_BYTES=$(( ${MIN_MB:-0} * 1024 * 1024 ))

DELETE_ORIGINALS=false
read -rp "$(echo -e ${YEL})Delete original files after successful upload? [y/N]: $(echo -e ${NC})" DO
[[ "$DO" =~ ^[Yy]$ ]] && DELETE_ORIGINALS=true

cd "$SOURCE" 2>/dev/null || { echo -e "${RED}Cannot access $SOURCE${NC}"; exit 1; }

echo -e "\n${GRN}--- Files in $SOURCE ---${NC}"
VALID_FILES=()
for ITEM in *; do
    [ -e "$ITEM" ] || continue
    if $FILTER_JUNK && is_junk "$ITEM"; then
        echo -e "  ${DIM}⊗ Junk skipped: $ITEM${NC}"
        continue
    fi
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

declare -A ZIP_NAMES ZIP_FORMAT ZIP_SPLIT ZIP_LEVEL ZIP_PASS ZIP_MODE FILE_ASSIGNMENTS

ACTOR_GROUPING_USED=false
echo ""
read -rp "$(echo -e ${YEL})Group files by AI actor detection? [y/N]: $(echo -e ${NC})" AG
if [[ "$AG" =~ ^[Yy]$ ]]; then
    if run_actor_grouping; then
        ACTOR_GROUPING_USED=true
    else
        echo -e "${YEL}Falling back to manual archive setup.${NC}"
    fi
fi

if ! $ACTOR_GROUPING_USED; then
    echo ""
    read -rp "$(echo -e ${YEL})How many archives to create? $(echo -e ${NC})" ZIP_COUNT

    for i in $(seq 1 "$ZIP_COUNT"); do
        echo -e "\n${CYN}── Archive #$i ──────────────────────────${NC}"
        read -rp "  Name: " NAME
        ZIP_NAMES[$i]="$NAME"

        echo -e "  Format:  ${YEL}1) ZIP   2) RAR${NC}"
        read -rp "  Choice [1/2, default 2]: " FMT
        [[ "$FMT" == "1" ]] && ZIP_FORMAT[$i]="zip" || ZIP_FORMAT[$i]="rar"

        read -rp "  Split into parts? Enter size in MB (0 = no split): " SPLIT_MB
        ZIP_SPLIT[$i]="${SPLIT_MB:-0}"

        echo -e "  Compression: ${YEL}0=store(fastest) → 9=max(smallest)${NC}"
        read -rp "  Level [0-9, default 0]: " LVL
        ZIP_LEVEL[$i]="${LVL:-0}"

        read -rsp "  Password (Enter = use default '$GLOBAL_PASS'): " APASS
        echo ""
        [ -z "$APASS" ] && APASS="$GLOBAL_PASS"
        ZIP_PASS[$i]="$APASS"

        ZIP_MODE[$i]="normal"
        FILE_ASSIGNMENTS[$i]=""
    done

    echo -e "\n${YEL}--- Assign Files to Archives ---${NC}"
    BULK_ADD=false
    if [ "$ZIP_COUNT" -eq 1 ]; then
        read -rp "$(echo -e ${YEL})Add all files to this archive? [Y/n]: $(echo -e ${NC})" BULK
        [[ ! "$BULK" =~ ^[Nn]$ ]] && BULK_ADD=true
    fi

    if $BULK_ADD; then
        for ITEM in "${VALID_FILES[@]}"; do FILE_ASSIGNMENTS[1]+="$ITEM"$'\n'; done
        echo -e "  ${GRN}✓ All files assigned to ${ZIP_NAMES[1]}${NC}"
    else
        for ITEM in "${VALID_FILES[@]}"; do
            FSIZE=$(get_size "$SOURCE/$ITEM")
            echo -e "\n  ${BLD}${YEL}$ITEM${NC}  ${DIM}($(human_size ${FSIZE:-0}))${NC}"
            for i in $(seq 1 "$ZIP_COUNT"); do echo -e "  $i) ${ZIP_NAMES[$i]}  [${ZIP_FORMAT[$i]}]"; done
            read -rp "  Assign to (1-$ZIP_COUNT) or 's' to skip: " CHOICE
            if [[ "$CHOICE" =~ ^[0-9]+$ ]] && [ "$CHOICE" -le "$ZIP_COUNT" ]; then
                FILE_ASSIGNMENTS[$CHOICE]+="$ITEM"$'\n'
                echo -e "  ${GRN}✓ → ${ZIP_NAMES[$CHOICE]}${NC}"
            else
                echo -e "  ${DIM}⊗ Skipped${NC}"
            fi
        done
    fi
fi

TOTAL_SIZE=0
for i in $(seq 1 "$ZIP_COUNT"); do
    while IFS= read -r ITEM; do
        [ -z "$ITEM" ] && continue
        [ -e "$SOURCE/$ITEM" ] || continue
        SZ=$(get_size "$SOURCE/$ITEM")
        TOTAL_SIZE=$(( TOTAL_SIZE + ${SZ:-0} ))
    done <<< "${FILE_ASSIGNMENTS[$i]}"
done

echo -e "\n${YEL}--- Feasibility Check ---${NC}"
for i in $(seq 1 "$ZIP_COUNT"); do
    [ -z "${FILE_ASSIGNMENTS[$i]}" ] && continue

    ARCHIVE_SIZE=0
    while IFS= read -r ITEM; do
        [ -z "$ITEM" ] && continue
        [ -e "$SOURCE/$ITEM" ] || continue
        SZ=$(get_size "$SOURCE/$ITEM")
        ARCHIVE_SIZE=$(( ARCHIVE_SIZE + ${SZ:-0} ))
    done <<< "${FILE_ASSIGNMENTS[$i]}"

    NEEDED=$(( ARCHIVE_SIZE * 2 ))

    if (( NEEDED > AVAILABLE_BYTES )); then
        echo -e "  ${RED}⚠ Archive '${ZIP_NAMES[$i]}' (${ZIP_FORMAT[$i]}) needs roughly $(human_size $NEEDED) space but only $(human_size $AVAILABLE_BYTES) is available.${NC}"
        read -rp "  $(echo -e ${YEL})Use SMART SEQUENTIAL PART MODE? [Y/n]: $(echo -e ${NC})" SMART_CHOICE
        if [[ ! "$SMART_CHOICE" =~ ^[Nn]$ ]]; then
            ZIP_MODE[$i]="smart"
            echo -e "  ${GRN}✓ '${ZIP_NAMES[$i]}' will use smart sequential mode.${NC}"
        fi
    fi
done

echo -e "\n${BLD}${GRN}════════ SUMMARY ════════${NC}"
echo -e "  Bucket      : ${BLD}s3://$BUCKET/$S3_PREFIX${NC}"
echo -e "  Total size  : ${BLD}$(human_size $TOTAL_SIZE)${NC}"
echo -e "  Disk free   : ${BLD}$(human_size $AVAILABLE_BYTES)${NC}"
echo -e "  Dry run     : ${BLD}$DRY_RUN${NC}"
echo -e "  Del original: ${BLD}$DELETE_ORIGINALS${NC}"
echo -e "  AI Grouping : ${BLD}$ACTOR_GROUPING_USED${NC}"
echo ""
for i in $(seq 1 "$ZIP_COUNT"); do
    [ -z "${FILE_ASSIGNMENTS[$i]}" ] && continue
    COUNT=$(echo "${FILE_ASSIGNMENTS[$i]}" | grep -c '\S')
    echo -e "  Archive #$i  : ${BLD}${ZIP_NAMES[$i]}.${ZIP_FORMAT[$i]}${NC}  |  $COUNT file(s)  |  mode ${BLD}${ZIP_MODE[$i]}${NC}"
done

ANY_SMART=false
for i in $(seq 1 "$ZIP_COUNT"); do [ "${ZIP_MODE[$i]}" = "smart" ] && ANY_SMART=true; done

if (( TOTAL_SIZE > AVAILABLE_BYTES )) && ! $ANY_SMART; then
    echo -e "\n${RED}✗ Not enough disk space! Aborting.${NC}"
    exit 1
fi

echo ""
read -rp "$(echo -e ${YEL})Proceed? [Y/n]: $(echo -e ${NC})" CONFIRM
[[ "$CONFIRM" =~ ^[Nn]$ ]] && echo -e "${YEL}Aborted.${NC}" && exit 0

echo -e "\n${GRN}--- Processing ---${NC}"
log "Processing $ZIP_COUNT archive(s)"

for i in $(seq 1 "$ZIP_COUNT"); do
    NAME="${ZIP_NAMES[$i]}"
    FMT="${ZIP_FORMAT[$i]}"
    SPLIT="${ZIP_SPLIT[$i]}"
    LVL="${ZIP_LEVEL[$i]}"
    PASS="${ZIP_PASS[$i]}"
    MODE="${ZIP_MODE[$i]}"

    [ -z "${FILE_ASSIGNMENTS[$i]}" ] && continue

    echo -e "\n${BLU}${BLD}▶ Archive: $NAME.$FMT${NC}"

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
        echo -e "  ${CYN}[DRY RUN] Output: $OUTFILE  ($(human_size $ARCHIVE_SIZE))${NC}"
        continue
    fi

    cd "$SOURCE" || exit

    if [ "$MODE" = "smart" ]; then
        process_smart_sequential "$NAME" "$FMT" "$LVL" "$PASS" "${FILE_LIST[@]}"
        continue
    fi

    ALL_MEDIA=true
    for F in "${FILE_LIST[@]}"; do is_media "$F" || { ALL_MEDIA=false; break; }; done
    [ "$ALL_MEDIA" = true ] && [ "$LVL" -gt 0 ] && LVL=0

    if [ "$FMT" = "zip" ]; then
        if [ "${SPLIT:-0}" -gt 0 ]; then
            ZIP_ARGS=("-r" "-$LVL")
            [ -n "$PASS" ] && ZIP_ARGS+=("-P" "$PASS")
            echo "${FILE_LIST[@]}" | tr ' ' '\n' | zip "${ZIP_ARGS[@]}" "$OUTFILE" "${FILE_LIST[@]}" > /dev/null 2>&1 &
            ZIP_PID=$!
            watch_zip_progress "$OUTFILE" "$ARCHIVE_SIZE" "$ZIP_PID" "Zipping"
            wait "$ZIP_PID"
            SPLIT_BYTES=$(( SPLIT * 1024 * 1024 ))
            split -b "$SPLIT_BYTES" -d --additional-suffix=".zip" "$OUTFILE" "$TEMP_DIR/${NAME}.part"
            rm -f "$OUTFILE"
        else
            ZIP_ARGS=("-r" "-$LVL")
            [ -n "$PASS" ] && ZIP_ARGS+=("-P" "$PASS")
            zip "${ZIP_ARGS[@]}" "$OUTFILE" "${FILE_LIST[@]}" > /dev/null 2>&1 &
            ZIP_PID=$!
            watch_zip_progress "$OUTFILE" "$ARCHIVE_SIZE" "$ZIP_PID" "Zipping"
            wait "$ZIP_PID"
        fi
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

    shopt -s nullglob
    UPLOAD_FILES=( "$TEMP_DIR/${NAME}"*.zip "$TEMP_DIR/${NAME}"*.rar )
    shopt -u nullglob

    for UF in "${UPLOAD_FILES[@]}"; do
        [ -f "$UF" ] || continue
        if upload_file "$UF"; then rm -f "$UF"; fi
    done

    if $DELETE_ORIGINALS; then
        for F in "${FILE_LIST[@]}"; do
            if [ -e "$SOURCE/$F" ]; then
                rm -rf "$SOURCE/$F"
                echo -e "  ${DIM}Deleted original: $F${NC}"
            fi
        done
    fi
done

echo -e "\n${BLD}${GRN}════════ All Batches Complete ════════${NC}"
log "===== Session completed ======"