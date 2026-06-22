#!/usr/bin/env bash
# post_tool_use.sh - PostToolUse hook. Bash 결과 로깅
set -e
INPUT=$(cat)
TOOL=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)
CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)

[ "$TOOL" != "Bash" ] && exit 0
[ -z "$CMD" ] && exit 0

# forge test/script 결과는 자동으로 runs/ 폴더에 보존되도록 (이미 delegate가 tee 하지만 직접 호출도 캐치)
cd "$(dirname "$0")/.." 2>/dev/null || true

# delegate.sh 호출 후 자동으로 status.sh 갱신
if echo "$CMD" | grep -q 'delegate.sh'; then
    ./tools/status.sh > /dev/null 2>&1 || true
fi

exit 0
