#!/usr/bin/env bash
# trace.sh - 최근 N분의 모든 이벤트 시간순 출력
set -e
cd "$(dirname "$0")/.."

MIN="${1:-30}"
SEC=$((MIN * 60))
NOW=$(date +%s)
SINCE=$((NOW - SEC))

echo "=== Events in last ${MIN}min ==="
echo
echo "-- delegate calls --"
for f in logs/delegate_*.log.prompt; do
    [ -f "$f" ] || continue
    ts=$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null)
    if [ "$ts" -ge "$SINCE" ]; then
        when=$(date -r "$ts" "+%H:%M:%S" 2>/dev/null || date -d "@$ts" "+%H:%M:%S" 2>/dev/null)
        echo "[$when] $(basename "$f")"
    fi
done

echo
echo "-- recent notifications (last $MIN min) --"
if [ -f logs/notifications.log ]; then
    tail -50 logs/notifications.log
fi

echo
echo "-- status.json updates --"
for f in challenges/*/status.json; do
    [ -f "$f" ] || continue
    ts=$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null)
    if [ "$ts" -ge "$SINCE" ]; then
        when=$(date -r "$ts" "+%H:%M:%S" 2>/dev/null || date -d "@$ts" "+%H:%M:%S" 2>/dev/null)
        ch=$(basename $(dirname "$f"))
        state=$(jq -r '.state' "$f" 2>/dev/null)
        echo "[$when] $ch -> $state"
    fi
done
