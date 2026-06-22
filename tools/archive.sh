#!/usr/bin/env bash
# archive.sh — Classify and archive exploit files (v2 - with postflight validation)
#
# Usage:
#   ./tools/archive.sh <challenge> <src_path> <bucket> [desc]
#
# buckets:
#   successful  — broadcast succeeded + native balance verified increased
#   in_progress — forge test passed + net-positive projected
#   failed      — revert / net loss / DEAD_END

set -e
cd "$(dirname "$0")/.."

if [ "$#" -lt 3 ]; then
    echo "Usage: $0 <challenge> <src_path> <bucket> [desc]" >&2
    exit 1
fi

CH="$1"; SRC="$2"; BUCKET="$3"; DESC="${4:-attempt}"

# Validate
case "$CH" in
    ch1_uranium|ch2_harvest|ch3_feirari|ch4_superfluid|ch5_superfluid_v2) ;;
    *) echo "ERROR: unknown challenge: $CH" >&2; exit 1 ;;
esac
case "$BUCKET" in
    successful|in_progress|failed) ;;
    *) echo "ERROR: unknown bucket: $BUCKET" >&2; exit 1 ;;
esac
[ ! -f "$SRC" ] && echo "ERROR: file not found: $SRC" >&2 && exit 1

# === POSTFLIGHT VALIDATION (v2 addition) ===
# If archiving as "successful", verify against latest postflight.json
if [ "$BUCKET" = "successful" ]; then
    LATEST_POSTFLIGHT=$(ls -t challenges/$CH/runs/*_postflight.json 2>/dev/null | head -1)
    if [ -n "$LATEST_POSTFLIGHT" ] && [ -f "$LATEST_POSTFLIGHT" ]; then
        ACTUAL_DELTA=$(jq -r '.actual_delta_wei // "0"' "$LATEST_POSTFLIGHT" 2>/dev/null || echo "0")
        # Check if delta is negative or zero (strip quotes, compare as number)
        DELTA_NUM=$(echo "$ACTUAL_DELTA" | tr -d '"')
        if python3 -c "import sys; sys.exit(0 if int('${DELTA_NUM}') <= 0 else 1)" 2>/dev/null; then
            echo "WARNING: postflight shows actual_delta_wei=$DELTA_NUM (non-positive)!" >&2
            echo "  Auto-correcting bucket from 'successful' to 'failed'." >&2
            echo "  Postflight: $LATEST_POSTFLIGHT" >&2
            BUCKET="failed"
            DESC="${DESC}_autocorrected_netloss"
        fi
    fi
fi

# Build destination
DEST_DIR="challenges/$CH/exploits/$BUCKET"
mkdir -p "$DEST_DIR"

BASE=$(basename "$SRC")
STEM="${BASE%.*}"
EXT="${BASE##*.}"

EXISTING_N=$(ls -1 "$DEST_DIR" 2>/dev/null | grep -cE "^${STEM}_v[0-9]+_.*\.${EXT}$" || true)
NEXT_N=$((EXISTING_N + 1))

SAFE_DESC=$(echo "$DESC" | tr '[:upper:] ' '[:lower:]_' | tr -cd '[:alnum:]_')
[ -z "$SAFE_DESC" ] && SAFE_DESC="attempt"

DEST_NAME="${STEM}_v${NEXT_N}_${SAFE_DESC}.${EXT}"
DEST="$DEST_DIR/$DEST_NAME"

cp "$SRC" "$DEST"

# Audit log
LOG_FILE="challenges/$CH/exploits/ARCHIVE_LOG.md"
if [ ! -f "$LOG_FILE" ]; then
    cat > "$LOG_FILE" <<EOF
# Exploit Archive Log — $CH

| Time (UTC) | Bucket | Source | Destination | Description |
|---|---|---|---|---|
EOF
fi

TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
printf "| %s | %s | \`%s\` | \`%s\` | %s |\n" \
    "$TS" "$BUCKET" "$SRC" "$DEST" "$DESC" >> "$LOG_FILE"

echo "ARCHIVED: $SRC -> $DEST (bucket: $BUCKET)"

# Notify on successful
if [ "$BUCKET" = "successful" ] && [ -x ./tools/notify.sh ]; then
    ./tools/notify.sh "$CH: exploit archived to successful/ ($DEST_NAME)" 2>/dev/null || true
fi

# Notify on repeated failures (3+)
if [ "$BUCKET" = "failed" ]; then
    FAIL_COUNT=$(ls -1 "challenges/$CH/exploits/failed/" 2>/dev/null | wc -l | tr -d ' ')
    if [ "$FAIL_COUNT" -ge 3 ] && [ -x ./tools/notify.sh ]; then
        ./tools/notify.sh "$CH: $FAIL_COUNT failed attempts — consider hypothesis change" 2>/dev/null || true
    fi
fi

# Auto-scoreboard refresh on success
if [ "$BUCKET" = "successful" ] && [ -f ./tools/poll_scoreboard.py ]; then
    nohup python3 ./tools/poll_scoreboard.py --once > /dev/null 2>&1 &
    disown 2>/dev/null || true
fi

# Pending report note
if [ "${AUTO_REPORT:-1}" = "1" ]; then
    PENDING_DIR="challenges/$CH/.pending_report_notes"
    mkdir -p "$PENDING_DIR"
    NOTE_FILE="$PENDING_DIR/$(date -u +%Y%m%dT%H%M%SZ)_${BUCKET}_${SAFE_DESC}.note"
    {
        echo "# pending report note"
        echo "ts: $TS"
        echo "challenge: $CH"
        echo "bucket: $BUCKET"
        echo "desc: $SAFE_DESC"
        echo "src_original: $SRC"
        echo "archived: $DEST"
        echo ""
        echo "latest_runs:"
        ls -1t "challenges/$CH/runs/" 2>/dev/null | head -3 | sed 's|^|  - challenges/'"$CH"'/runs/|'
        echo "status_snapshot:"
        cat "challenges/$CH/status.json" 2>/dev/null | sed 's|^|  |'
    } > "$NOTE_FILE"
    echo "PENDING_REPORT_NOTE: $NOTE_FILE"
fi
