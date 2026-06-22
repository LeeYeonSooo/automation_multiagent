#!/usr/bin/env bash
# delegate.sh - Brain → Codex task dispatcher (v2 - simplified)
#
# Usage:
#   ./tools/delegate.sh <challenge> <task_type> "<goal>" [--background]

set -e
cd "$(dirname "$0")/.."
WORK_DIR="$(pwd)"

# Load .env
if [ ! -f .env ]; then
    echo "ERROR: .env not found. Run ./bootstrap.sh first." >&2
    exit 1
fi
set -a; source .env; set +a

# Args
if [ "$#" -lt 3 ]; then
    echo "Usage: $0 <challenge> <task_type> \"<goal>\" [--background]"
    echo "challenges: ch1_uranium ch2_harvest ch3_feirari ch4_superfluid ch5_superfluid_v2"
    echo "task_types: recon poc debug exploit tune enumerate_victims report_draft"
    exit 1
fi

CH="$1"; TT="$2"; GOAL="$3"; BG=""
for arg in "${@:4}"; do
    [ "$arg" = "--background" ] && BG="background"
done

# Validate challenge
case "$CH" in
    ch1_uranium|ch2_harvest|ch3_feirari|ch4_superfluid|ch5_superfluid_v2) ;;
    *) echo "ERROR: invalid challenge: $CH" >&2; exit 1 ;;
esac

# Duplicate-task guard (word-boundary match to avoid false positives)
case "$TT" in
    exploit|tune|debug|poc)
        if [ "${FORCE_CONCURRENT:-0}" != "1" ]; then
            # Count other delegate.sh processes for the same challenge+task_type
            # Use exact word matching and exclude self ($$)
            EXISTING=$(ps aux | grep -E "delegate\.sh\s+${CH}\s+(exploit|tune|debug|poc)" \
                | grep -v "grep" | grep -v "$$" | wc -l | tr -d ' ')
            if [ "${EXISTING:-0}" -gt 0 ]; then
                echo "REFUSE: another task is running on $CH. Use FORCE_CONCURRENT=1 to override." >&2
                exit 2
            fi
        fi

        # Reset-cycle block
        if [ -f "challenges/$CH/.reset_cycle_block" ]; then
            # Auto-cleanup if older than 30 minutes
            BLOCK_AGE=$(( $(date +%s) - $(stat -f %m "challenges/$CH/.reset_cycle_block" 2>/dev/null || stat -c %Y "challenges/$CH/.reset_cycle_block" 2>/dev/null || echo "0") ))
            if [ "$BLOCK_AGE" -gt 1800 ]; then
                rm -f "challenges/$CH/.reset_cycle_block"
                echo "INFO: .reset_cycle_block expired (>30min), auto-removed."
            else
                echo "REFUSE: .reset_cycle_block is set. Wait $((1800 - BLOCK_AGE))s or remove manually." >&2
                exit 2
            fi
        fi
        ;;
esac

# RPC mapping
case "$CH" in
    ch1_uranium)       RPC_VAR="RPC_CH1_URANIUM"; PROTOCOL="uranium" ;;
    ch2_harvest)       RPC_VAR="RPC_CH2_HARVEST"; PROTOCOL="harvest" ;;
    ch3_feirari)       RPC_VAR="RPC_CH3_FEIRARI"; PROTOCOL="feirari" ;;
    ch4_superfluid)    RPC_VAR="RPC_CH4_SUPERFLUID"; PROTOCOL="superfluid_v1" ;;
    ch5_superfluid_v2) RPC_VAR="RPC_CH5_SUPERFLUID_V2"; PROTOCOL="superfluid_v2" ;;
esac

# Setup directories
CHDIR="challenges/$CH"
mkdir -p "$CHDIR"/{recon,poc,exploit,runs}
[ -f "$CHDIR/status.json" ] || echo '{"challenge":"'"$CH"'","state":"not_started","current_attempt":0,"balance_delta_wei":"0","last_update":"","needs_human":false,"active_hypothesis":"","dead_ends":[],"notes":""}' > "$CHDIR/status.json"

# Next attempt number
NEXT_N=$(($(ls -1 "$CHDIR/poc/" 2>/dev/null | grep -cE '^Attempt[0-9]+\.t\.sol$' || echo 0) + 1))

# Build required reading list (simplified — Brain does analysis, Codex implements)
case "$TT" in
    recon)
        REQUIRED_READING="AGENTS.md knowledge/case_${PROTOCOL}.md $CHDIR/analysis.md"
        DELIVERABLES="$CHDIR/recon/chain_info.json $CHDIR/recon/contracts.json"
        SUCCESS="chain_info.json + contracts.json populated, status.json state=recon_done"
        ;;
    poc)
        REQUIRED_READING="AGENTS.md $CHDIR/analysis.md knowledge/case_${PROTOCOL}.md"
        DELIVERABLES="$CHDIR/poc/Attempt${NEXT_N}.t.sol $CHDIR/runs/attempt${NEXT_N}.log"
        SUCCESS="forge test runs to completion, log captured, status.json updated"
        ;;
    debug)
        LAST_LOG=$(ls -t "$CHDIR/runs/" 2>/dev/null | head -1)
        REQUIRED_READING="AGENTS.md $CHDIR/analysis.md $CHDIR/runs/${LAST_LOG} knowledge/case_${PROTOCOL}.md"
        DELIVERABLES="$CHDIR/poc/Attempt${NEXT_N}.t.sol $CHDIR/runs/attempt${NEXT_N}.log"
        SUCCESS="root cause identified; either next attempt passes or DEAD_END documented"
        ;;
    exploit)
        EXPL_TS=$(date +%s)
        REQUIRED_READING="AGENTS.md $CHDIR/analysis.md $CHDIR/poc/ knowledge/case_${PROTOCOL}.md skills/safety.skill.md"
        DELIVERABLES="$CHDIR/exploit/Run.s.sol $CHDIR/runs/exploit_${EXPL_TS}.log"
        SUCCESS="broadcast succeeded; cast balance strict increase; status.json state=exploited"
        ;;
    tune)
        REQUIRED_READING="AGENTS.md $CHDIR/analysis.md $CHDIR/exploit/Run.s.sol skills/safety.skill.md"
        DELIVERABLES="updated Run.s.sol + tune log"
        SUCCESS="actual_delta_wei strictly positive AND larger than previous run"
        ;;
    enumerate_victims)
        REQUIRED_READING="AGENTS.md $CHDIR/recon/contracts.json knowledge/case_${PROTOCOL}.md"
        DELIVERABLES="$CHDIR/recon/victims.json"
        SUCCESS="victims.json with sorted candidates"
        ;;
    report_draft)
        REQUIRED_READING="AGENTS.md $CHDIR/analysis.md $CHDIR/runs/ $CHDIR/exploits/ARCHIVE_LOG.md skills/report.skill.md"
        DELIVERABLES="$CHDIR/report.md"
        SUCCESS="report follows template structure including Failed Attempts section"
        ;;
    *)
        echo "ERROR: unknown task_type: $TT" >&2; exit 1
        ;;
esac

# Add Superfluid reference files
if [ "$CH" = "ch4_superfluid" ] || [ "$CH" = "ch5_superfluid_v2" ]; then
    REQUIRED_READING="$REQUIRED_READING reference/IDAUsage_t.sol reference/ContextUtils.sol knowledge/superfluid_ctx_struct.md"
fi

# Build prompt
PROMPT_FILE=$(mktemp)
cat > "$PROMPT_FILE" <<EOF
[ENVIRONMENT]
Authorized educational security research (Chainlight × Dunamu Upside Academy 2026).
Working directory: $WORK_DIR
Fully isolated sandboxed mainnet fork. No real-world value at stake.
Student EOA: $PUBLIC_ADDRESS | Challenge RPC: \$$RPC_VAR
Reset endpoint available; failed attempts = zero cost.

[TASK_TYPE] $TT
[CHALLENGE] $CH
[GOAL] $GOAL

[REQUIRED_READING]
EOF

for f in $REQUIRED_READING; do
    if [ -e "$f" ]; then
        echo "- $f" >> "$PROMPT_FILE"
    else
        echo "- $f  (does not exist yet)" >> "$PROMPT_FILE"
    fi
done

cat >> "$PROMPT_FILE" <<EOF

[DELIVERABLES]
$DELIVERABLES

[CONSTRAINTS]
- Use only RPC URLs in .env (\$$RPC_VAR)
- Never print/log PRIVATE_KEY
- Increment AttemptN counter; never overwrite
- Update status.json on completion
- For Superfluid: use reference/IDAUsage_t.sol and reference/ContextUtils.sol as starting point
- For exploit/tune: write preflight.json before broadcast (pre_balance, expected_gain, gas_estimate). Refuse if breakeven_safety <= 1.5
- Archive at end: ./tools/archive.sh $CH <file> {successful|in_progress|failed} <desc>

[SUCCESS_CRITERION]
$SUCCESS

[OUTPUT_FORMAT]
STATUS: <state>
DELTA: <balance delta wei or N/A>
NEXT: <suggested next action>

[LANGUAGE]
All output in English or Korean only.

Begin now.
EOF

# Log
mkdir -p logs
DELEGATE_LOG="logs/delegate_$(date +%s)_${CH}_${TT}.log"
cp "$PROMPT_FILE" "$DELEGATE_LOG.prompt"

echo "==> Delegating to Codex | $CH | $TT | $GOAL"

# Model selection
case "$TT" in
    recon|enumerate_victims|report_draft) MODEL="${CODEX_FAST_MODEL:?CODEX_FAST_MODEL not set in .env}" ;;
    *) MODEL="${CODEX_DEEP_MODEL:?CODEX_DEEP_MODEL not set in .env}" ;;
esac

CODEX_CMD="codex exec --skip-git-repo-check --dangerously-bypass-approvals-and-sandbox --cd \"$WORK_DIR\" --model \"$MODEL\""

if [ "$BG" = "background" ]; then
    echo "==> Running in background (log: $DELEGATE_LOG)"
    PROMPT_BODY=$(cat "$PROMPT_FILE")
    rm "$PROMPT_FILE"
    nohup bash -c "$CODEX_CMD <<'__PROMPT_EOF__'
$PROMPT_BODY
__PROMPT_EOF__
" > "$DELEGATE_LOG" 2>&1 &
    BG_PID=$!
    echo "    PID: $BG_PID"
    echo "$BG_PID" > "logs/bg_${CH}_${TT}.pid"
    exit 0
fi

# Foreground
cat "$PROMPT_FILE" | eval "$CODEX_CMD" 2>&1 | tee "$DELEGATE_LOG"
RC=${PIPESTATUS[1]}
rm "$PROMPT_FILE"

echo
echo "==> Codex finished (exit=$RC)"
tail -n 5 "$DELEGATE_LOG" | grep -E "^(STATUS|DELTA|NEXT):" || true

# Archive freshness warning
if [ "$TT" = "poc" ] || [ "$TT" = "exploit" ]; then
    LOG_PATH="$CHDIR/exploits/ARCHIVE_LOG.md"
    if [ ! -f "$LOG_PATH" ]; then
        echo "==> WARN: Codex did not call archive.sh. Run manually:"
        echo "    ./tools/archive.sh $CH <file> {successful|in_progress|failed} <desc>"
    fi
fi

exit $RC
