#!/usr/bin/env bash
# pre_tool_use.sh - Claude Code PreToolUse hook (v2 - improved patterns)
# stdin: {"tool_name": "...", "tool_input": {"command": "..."}}

set -e
INPUT=$(cat)
CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
TOOL=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)

# Only filter Bash commands
if [ "$TOOL" != "Bash" ]; then
    echo '{"hookSpecificOutput":{"permissionDecision":"allow"}}'
    exit 0
fi

deny() {
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$1"
    exit 0
}
ask() {
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"%s"}}\n' "$1"
    exit 0
}

# 1. .env content exposure (handles: cat .env, cat ./.env, cat < .env, less .env, etc.)
if echo "$CMD" | grep -qE '(cat|less|more|head|tail|bat)\s+(\./)?\.env(\s|$|;|&|\|)'; then
    deny "do not read .env contents directly. use: grep -c PRIVATE_KEY .env"
fi

# 2. Private key echo (hex pattern)
if echo "$CMD" | grep -qE '(echo|printf)\s+.*0x[a-fA-F0-9]{60,}'; then
    deny "do not echo private key to stdout."
fi

# 3. Dangerous rm (root, home, broad paths)
if echo "$CMD" | grep -qE 'rm\s+(-[a-zA-Z]*r[a-zA-Z]*f|(-[a-zA-Z]*f[a-zA-Z]*r))\s+(/($|\s)|/[a-z]+($|\s)|\$HOME|~(/|$))'; then
    deny "dangerous rm path. operate only inside work dir."
fi

# 4. git push
if echo "$CMD" | grep -qE '\bgit\s+push\b'; then
    deny "git push not allowed without explicit user confirmation."
fi

# 5. forge --broadcast: check for confirmation
if echo "$CMD" | grep -qE 'forge\s+script.*--broadcast|--broadcast.*forge\s+script'; then
    cd "$(dirname "$0")/.." 2>/dev/null || true
    if ls shared/inbox/approved_*.txt 2>/dev/null | head -1 >/dev/null; then
        echo '{"hookSpecificOutput":{"permissionDecision":"allow"}}'
        exit 0
    fi
    ask "broadcast detected. did you call ./tools/confirm.sh first?"
fi

echo '{"hookSpecificOutput":{"permissionDecision":"allow"}}'
