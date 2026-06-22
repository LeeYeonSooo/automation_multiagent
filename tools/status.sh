#!/usr/bin/env bash
# status.sh - PROGRESS.md 자동 갱신 후 출력

set -e

cd "$(dirname "$0")/.."
[ -f .env ] && { set -a; source .env; set +a; }

CHALLENGES=(ch1_uranium ch2_harvest ch3_feirari ch4_superfluid ch5_superfluid_v2)
NAMES=("Uranium" "Harvest" "Fei-Rari" "Superfluid" "Superfluid v2")
ACTUAL="actual_scores.json"

NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
TOTAL_US=0
TOTAL_LEADER=0

# Read actual_scores.json metadata
if [ -f "$ACTUAL" ]; then
    SCORES_LAST_UPDATE=$(jq -r '._last_updated // "-"' "$ACTUAL" 2>/dev/null)
    TOTAL_US=$(jq -r '._total_us // 0' "$ACTUAL" 2>/dev/null)
    TOTAL_LEADER=$(jq -r '._total_leader // 0' "$ACTUAL" 2>/dev/null)
    WE_LEAD=$(jq -r '._we_are_total_leader // false' "$ACTUAL" 2>/dev/null)
    TOTAL_GAP=$(jq -r '._total_gap_to_leader // 0' "$ACTUAL" 2>/dev/null)
else
    SCORES_LAST_UPDATE="(actual_scores.json missing)"
    WE_LEAD="false"
    TOTAL_GAP="?"
fi

# Daemon status
DAEMON_PID=$(pgrep -f "poll_scoreboard.py" | head -1)
if [ -n "$DAEMON_PID" ]; then
    DAEMON_STATUS="ALIVE (PID $DAEMON_PID)"
else
    DAEMON_STATUS="**DOWN — restart needed**"
fi

# Header
{
    echo "# PROGRESS.md"
    echo
    echo "> 자동 갱신 파일. \`tools/status.sh\` 실행 시 갱신. 점수는 \`actual_scores.json\` (5분 자동 fetch) 신뢰."
    echo
    echo "**Last updated**: $NOW"
    echo "**Updated by**: tools/status.sh"
    echo "**Scoreboard daemon**: $DAEMON_STATUS"
    echo "**Scores last fetched**: $SCORES_LAST_UPDATE"
    echo
    echo "---"
    echo
    echo "## 챌린지별 상태 (실제 scoreboard 점수)"
    echo
    echo "| ID | 이름 | State | Score (us) | Leader | Gap | Δ Native | 시도 |"
    echo "|---|---|---|---|---|---|---|---|"
} > /tmp/progress_new.md

for i in "${!CHALLENGES[@]}"; do
    ch="${CHALLENGES[$i]}"
    name="${NAMES[$i]}"
    SF="challenges/$ch/status.json"

    if [ ! -f "$SF" ]; then
        STATE="not_started"
        DELTA="0"
        ATTEMPTS="0"
    else
        STATE=$(jq -r '.state // "?"' "$SF" 2>/dev/null || echo "?")
        DELTA=$(jq -r '.balance_delta_wei // "0"' "$SF" 2>/dev/null || echo "0")
        ATTEMPTS=$(jq -r '.current_attempt // 0' "$SF" 2>/dev/null || echo "0")
    fi

    if [ -f "$ACTUAL" ]; then
        SCORE=$(jq -r ".${ch}.score // \"?\"" "$ACTUAL" 2>/dev/null)
        LEADER_SCORE=$(jq -r ".${ch}.leader_score // \"?\"" "$ACTUAL" 2>/dev/null)
        LEADER=$(jq -r ".${ch}.leader // \"?\"" "$ACTUAL" 2>/dev/null)
        GAP=$(jq -r ".${ch}.gap_to_leader // \"?\"" "$ACTUAL" 2>/dev/null)
    else
        SCORE="?"; LEADER_SCORE="?"; LEADER="?"; GAP="?"
    fi

    DELTA_FMT=$(python3 -c "print(f'{int(\"$DELTA\")/1e18:.4f}')" 2>/dev/null || echo "$DELTA")

    echo "| $((i+1)) | $name | \`$STATE\` | $SCORE | $LEADER ($LEADER_SCORE) | $GAP | $DELTA_FMT | $ATTEMPTS |" >> /tmp/progress_new.md
done

{
    echo
    echo "**Total**: us = **$TOTAL_US** | leader = **$TOTAL_LEADER** | we_lead = **$WE_LEAD** | gap_to_leader = **$TOTAL_GAP**"
    echo
    echo "---"
    echo
    echo "## 우선순위 큐"
    echo
    echo "1. ch1 (Uranium) — 가장 단순. 워밍업."
    echo "2. ch3 (Fei-Rari) — 단일 tx reentrancy."
    echo "3. ch2 (Harvest) — oracle manip + 파라미터 튜닝."
    echo "4. ch4 (Superfluid v1) — ctx forgery."
    echo "5. ch5 (Superfluid v2) — patched, 가장 어려움."
    echo
    echo "---"
    echo
    echo "## 최근 알림"
    echo
    if [ -f logs/notifications.log ]; then
        tail -10 logs/notifications.log | while IFS= read -r line; do
            echo "- $line"
        done
    fi
    echo
    echo "---"
    echo
    echo "## 활성 챌린지 가설"
    echo
    for ch in "${CHALLENGES[@]}"; do
        AF="challenges/$ch/analysis.md"
        SF="challenges/$ch/status.json"
        if [ -f "$SF" ]; then
            HYP=$(jq -r '.active_hypothesis // ""' "$SF" 2>/dev/null)
            if [ -n "$HYP" ] && [ "$HYP" != "null" ]; then
                echo "**$ch**: $HYP"
                echo
            fi
        fi
    done
    echo
    echo "---"
    echo
    echo "## 컨텍스트 압축 시 보존된 정보"
    echo
    if [ -f .compact_state.md ]; then
        cat .compact_state.md
    else
        echo "(없음)"
    fi
} >> /tmp/progress_new.md

mv /tmp/progress_new.md PROGRESS.md
cat PROGRESS.md
