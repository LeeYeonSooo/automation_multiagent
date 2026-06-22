#!/usr/bin/env bash
# on_session_start.sh - SessionStart hook. 환경 자가진단 후 결과를 컨텍스트에 추가.
set -e
cd "$(dirname "$0")/.." 2>/dev/null || true

# additionalContext 형식으로 출력
{
    echo "=== Session Start Self-Check ==="
    echo "Date: $(date)"
    echo "Working dir: $(pwd)"
    echo
    if [ -f .env ]; then
        echo ".env: present"
        grep -c "^[A-Z_]\+=" .env 2>/dev/null | xargs printf "  %s lines\n"
    else
        echo ".env: MISSING — run ./bootstrap.sh"
    fi
    
    for cmd in forge cast codex jq tmux; do
        if command -v "$cmd" >/dev/null 2>&1; then
            echo "$cmd: ✓"
        else
            echo "$cmd: ✗ NOT INSTALLED"
        fi
    done
    
    echo
    echo "=== Current scoreboard ==="
    if [ -x ./tools/score.sh ]; then
        ./tools/score.sh 2>/dev/null | head -20
    fi

    echo
    echo "=== Pending report notes (CLAUDE.md §0 step 8) ==="
    NOTE_TOTAL=0
    for ch in ch1_uranium ch2_harvest ch3_feirari ch4_superfluid ch5_superfluid_v2; do
        DIR="challenges/$ch/.pending_report_notes"
        if [ -d "$DIR" ]; then
            N=$(find "$DIR" -maxdepth 1 -type f -name "*.note" 2>/dev/null | wc -l | tr -d ' ')
        else
            N=0
        fi
        if [ "$N" -gt 0 ]; then
            echo "  $ch: $N unprocessed"
            NOTE_TOTAL=$((NOTE_TOTAL + N))
        fi
    done
    if [ "$NOTE_TOTAL" -eq 0 ]; then
        echo "  (none — report queue drained)"
    else
        echo "  → Total $NOTE_TOTAL notes. Drain via skills/auto_report.skill.md §3-§3.6 (triage: Meaningful/Minor/Skip) before strategic action."
    fi
} | jq -Rs '{ "hookSpecificOutput": { "hookEventName": "SessionStart", "additionalContext": . } }'
