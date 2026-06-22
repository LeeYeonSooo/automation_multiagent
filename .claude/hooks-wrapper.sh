#!/usr/bin/env bash
# hooks-wrapper.sh - settings.json에서 hooks/*.sh 호출
# 사용: hooks-wrapper.sh <hook_name>

set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$1"

case "$HOOK" in
    pre_tool_use|post_tool_use|on_session_start|on_compact)
        exec "$ROOT/hooks/${HOOK}.sh"
        ;;
    *)
        echo "unknown hook: $HOOK" >&2
        exit 1
        ;;
esac
