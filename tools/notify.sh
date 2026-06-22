#!/usr/bin/env bash
# notify.sh - Discord webhook + macOS 데스크탑 알림
#
# 사용:
#   ./tools/notify.sh "ch1 exploited! +850pts"
#   ./tools/notify.sh "stuck on ch4" --warn
#   ./tools/notify.sh "human confirm needed" --critical

set -e

cd "$(dirname "$0")/.."
[ -f .env ] && { set -a; source .env; set +a; }

MSG="${1:-}"
LEVEL="${2:-info}"

if [ -z "$MSG" ]; then
    echo "Usage: $0 \"message\" [--warn|--critical]" >&2
    exit 1
fi

case "$LEVEL" in
    --warn)     EMOJI="⚠️";  COLOR=16753920 ;;  # orange
    --critical) EMOJI="🚨"; COLOR=15158332 ;;   # red
    *)          EMOJI="ℹ️";   COLOR=3447003 ;;   # blue
esac

TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Discord embed
PAYLOAD=$(cat <<EOF
{
  "username": "Upside Harness",
  "embeds": [{
    "title": "$EMOJI Upside C",
    "description": "$MSG",
    "color": $COLOR,
    "timestamp": "$TIMESTAMP",
    "footer": { "text": "Assignment C harness" }
  }]
}
EOF
)

if [ -n "${DISCORD_WEBHOOK_URL:-}" ]; then
    curl -s -X POST -H "Content-Type: application/json" \
        -d "$PAYLOAD" "$DISCORD_WEBHOOK_URL" > /dev/null || \
        echo "WARN: Discord webhook failed" >&2
fi

# macOS 데스크탑 알림 (옵션)
if command -v osascript >/dev/null 2>&1; then
    osascript -e "display notification \"$MSG\" with title \"Upside C\" sound name \"Glass\"" 2>/dev/null || true
fi

# 로컬 로그
mkdir -p logs
echo "[$TIMESTAMP] [$LEVEL] $MSG" >> logs/notifications.log

echo "OK"
