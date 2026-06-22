#!/usr/bin/env bash
# user_prompt_submit.sh — UserPromptSubmit hook.
# Forces brain to drain pending report notes + surfaces fresh scoreboard state
# on every user message. Without this, CLAUDE.md §0 step 8 was "voluntary" and
# notes piled up (21 unprocessed as of 2026-04-18).
set -e
cd "$(dirname "$0")/.." 2>/dev/null || true

# Collect pending_report_notes count per challenge + total
TOTAL=0
PER_CH=""
for ch in ch1_uranium ch2_harvest ch3_feirari ch4_superfluid ch5_superfluid_v2; do
    DIR="challenges/$ch/.pending_report_notes"
    if [ -d "$DIR" ]; then
        N=$(find "$DIR" -maxdepth 1 -type f -name "*.note" 2>/dev/null | wc -l | tr -d ' ')
    else
        N=0
    fi
    TOTAL=$((TOTAL + N))
    if [ "$N" -gt 0 ]; then
        PER_CH="$PER_CH $ch=$N"
    fi
done

# Collect .stuck_action markers (forcing creative_escalation per CLAUDE.md §7)
STUCK=""
for f in challenges/*/.stuck_action; do
    [ -f "$f" ] || continue
    ch=$(basename "$(dirname "$f")")
    STUCK="$STUCK $ch"
done

# Collect .hyp_quality_fail_* markers (hypothesis quality validator failures)
HYP_FAIL=""
for f in challenges/*/.hyp_quality_fail_attempt*; do
    [ -f "$f" ] || continue
    ch=$(basename "$(dirname "$f")")
    att=$(basename "$f" | sed 's/^.hyp_quality_fail_attempt//')
    HYP_FAIL="$HYP_FAIL $ch:att$att"
done

# Daemon health
DAEMON_PIDS=$(pgrep -f "poll_scoreboard.py" 2>/dev/null | tr '\n' ' ')
DAEMON_COUNT=$(echo "$DAEMON_PIDS" | wc -w | tr -d ' ')
if [ "$DAEMON_COUNT" = "0" ]; then
    DAEMON_LINE="Scoreboard daemon: DOWN — restart: nohup python3 tools/poll_scoreboard.py > logs/scoreboard_daemon.log 2>&1 & disown"
elif [ "$DAEMON_COUNT" = "1" ]; then
    DAEMON_LINE="Scoreboard daemon: alive (pid $(echo $DAEMON_PIDS | tr -d ' '))"
else
    DAEMON_LINE="Scoreboard daemon: DUPLICATE ($DAEMON_COUNT instances, pids $DAEMON_PIDS) — keep one, kill others"
fi

# Build additionalContext lines only when there's something actionable
LINES=""
if [ "$TOTAL" -gt 0 ]; then
    LINES="$LINES
PENDING REPORT NOTES: $TOTAL total ($PER_CH).
→ Drain via skills/auto_report.skill.md §3 before other strategic action (CLAUDE.md §0 step 8, §8.1). Each note = one report.md entry (5 mandatory fields: Why / How / Result / WhySucceededFailed / ThoughtProcess). Brain-only, NOT Codex."
fi
if [ -n "$STUCK" ]; then
    LINES="$LINES
STUCK ACTION MARKERS:$STUCK → run skills/creative_escalation.skill.md 8-step before delegating on these challenges."
fi
if [ -n "$HYP_FAIL" ]; then
    LINES="$LINES
HYP_QUALITY FAILURES:$HYP_FAIL → read marker files, patch analysis.md or re-delegate with deep_analysis.skill.md adherence."
fi
if [ "$DAEMON_COUNT" != "1" ]; then
    LINES="$LINES
$DAEMON_LINE"
fi

if [ -z "$LINES" ]; then
    # Nothing to flag → empty output = no context injection
    echo '{}'
    exit 0
fi

HEADER="=== Harness Self-Check (UserPromptSubmit) ==="
FULL="$HEADER$LINES"

# JSON-escape + wrap into additionalContext
printf '%s' "$FULL" | jq -Rs '{ "hookSpecificOutput": { "hookEventName": "UserPromptSubmit", "additionalContext": . } }'
