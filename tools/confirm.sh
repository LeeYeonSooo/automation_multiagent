#!/usr/bin/env bash
# confirm.sh - 사람 컨펌 대기. timeout 후 자동 진행
set -e
cd "$(dirname "$0")/.."
[ -f .env ] && { set -a; source .env; set +a; }

CH="${1:-}"
DESC="${2:-(no description)}"
TIMEOUT="${EXPLOIT_CONFIRM_TIMEOUT:-10}"

if [ -z "$CH" ]; then
    echo "Usage: $0 <challenge> \"<description>\"" >&2
    exit 2
fi

INBOX="shared/inbox"
mkdir -p "$INBOX"
CONFIRM_FILE="$INBOX/confirm_${CH}.txt"
APPROVED_FILE="$INBOX/approved_${CH}.txt"
rm -f "$APPROVED_FILE"

cat > "$CONFIRM_FILE" <<INNER
=========================================
EXPLOIT CONFIRMATION REQUESTED
=========================================
Challenge: $CH
Description: $DESC
Auto-proceed in: ${TIMEOUT}s

To approve manually:
  echo "OK" > $APPROVED_FILE

To refuse:
  echo "REFUSED: <reason>" > $APPROVED_FILE
=========================================
INNER

cat "$CONFIRM_FILE"
./tools/notify.sh "Confirm needed: $CH — $DESC (auto in ${TIMEOUT}s)" --warn 2>/dev/null || true

ELAPSED=0
while [ "$ELAPSED" -lt "$TIMEOUT" ]; do
    if [ -f "$APPROVED_FILE" ]; then
        RESPONSE=$(cat "$APPROVED_FILE")
        if echo "$RESPONSE" | grep -qi "REFUSE"; then
            echo "==> REFUSED: $RESPONSE"
            ./tools/notify.sh "Exploit REFUSED for $CH: $RESPONSE" --critical 2>/dev/null || true
            exit 1
        else
            echo "==> APPROVED: $RESPONSE"
            exit 0
        fi
    fi
    sleep 1
    ELAPSED=$((ELAPSED + 1))
done

echo "==> Timeout. Auto-proceeding."
echo "AUTO_APPROVED" > "$APPROVED_FILE"
exit 0
