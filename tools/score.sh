#!/usr/bin/env bash
# score.sh — 5개 챌린지 현재 상태 + 실제 점수 (actual_scores.json 신뢰)
#
# 핵심 원칙 (CLAUDE.md §4.5 + §5):
# - max_pts는 모른다 (멘토만 안다). 추정 X.
# - status.json.score_estimate 는 Codex의 wishful thinking. 표시 X.
# - 실제 점수는 actual_scores.json (사용자가 scoreboard 보고 수동 갱신).
# - 본 도구는 native delta 진행도 + 사용자 입력 실제 점수만 표시.

set -e

cd "$(dirname "$0")/.."
[ -f .env ] && { set -a; source .env; set +a; }

ACTUAL="actual_scores.json"
CHALLENGES=(ch1_uranium ch2_harvest ch3_feirari ch4_superfluid ch5_superfluid_v2)

printf "%-22s %-12s %-16s %-10s %-8s %-10s %s\n" "Challenge" "State" "Native Δ" "Score" "Max" "Potential" "Leader (gap)"
printf "%-22s %-12s %-16s %-10s %-8s %-10s %s\n" "---------------------" "----------" "----------------" "--------" "------" "---------" "------------"

TOTAL_KNOWN=0
TOTAL_MAX=0
TOTAL_POTENTIAL=0
KNOWN_COUNT=0

for ch in "${CHALLENGES[@]}"; do
    SF="challenges/$ch/status.json"
    if [ -f "$SF" ]; then
        STATE=$(jq -r '.state // "?"' "$SF" 2>/dev/null || echo "?")
        DELTA=$(jq -r '.balance_delta_wei // "0"' "$SF" 2>/dev/null || echo "0")
    else
        STATE="not_started"
        DELTA="0"
    fi

    if [ "$DELTA" != "0" ] && [ -n "$DELTA" ]; then
        DELTA_FMT=$(python3 -c "print(f'{int(\"$DELTA\")/1e18:>14.2f}')" 2>/dev/null || echo "$DELTA")
    else
        DELTA_FMT="          0.00"
    fi

    if [ -f "$ACTUAL" ]; then
        SCORE=$(jq -r ".${ch}.score // \"?\"" "$ACTUAL" 2>/dev/null || echo "?")
        MAX=$(jq -r ".${ch}.max_pts // \"?\"" "$ACTUAL" 2>/dev/null || echo "?")
        LEADER=$(jq -r ".${ch}.leader // \"?\"" "$ACTUAL" 2>/dev/null || echo "?")
        LEADER_SCORE=$(jq -r ".${ch}.leader_score // \"?\"" "$ACTUAL" 2>/dev/null || echo "?")
        GAP=$(jq -r ".${ch}.gap_to_leader // \"?\"" "$ACTUAL" 2>/dev/null || echo "?")
    else
        SCORE="?"; MAX="?"; LEADER="?"; LEADER_SCORE="?"; GAP="?"
    fi

    POTENTIAL="?"
    if [ "$SCORE" != "?" ] && [ "$SCORE" != "null" ] && [ "$MAX" != "?" ] && [ "$MAX" != "null" ]; then
        POTENTIAL=$(python3 -c "print(f'{($MAX - $SCORE):>9.2f}')" 2>/dev/null || echo "?")
        TOTAL_KNOWN=$(python3 -c "print($TOTAL_KNOWN + $SCORE)" 2>/dev/null || echo "$TOTAL_KNOWN")
        TOTAL_MAX=$(python3 -c "print($TOTAL_MAX + $MAX)" 2>/dev/null || echo "$TOTAL_MAX")
        TOTAL_POTENTIAL=$(python3 -c "print($TOTAL_POTENTIAL + $MAX - $SCORE)" 2>/dev/null || echo "$TOTAL_POTENTIAL")
        KNOWN_COUNT=$((KNOWN_COUNT + 1))
    fi

    printf "%-22s %-12s %-16s %-10s %-8s %-10s %s (%s, gap %s)\n" "$ch" "$STATE" "$DELTA_FMT" "$SCORE" "$MAX" "$POTENTIAL" "$LEADER" "$LEADER_SCORE" "$GAP"
done

printf "%-22s %-12s %-16s %-10s %-8s %-10s %s\n" "---------------------" "----------" "----------------" "--------" "------" "---------" "------------"
printf "%-22s %-12s %-16s %-10s %-8s %-10s\n" "TOTAL" "" "" "$TOTAL_KNOWN" "$TOTAL_MAX" "$TOTAL_POTENTIAL"
echo
echo "Legend: Score=현재 우리 점수 / Max=챌린지 최대점 / Potential=짤 수 있는 추가점 (Max - Score)"
echo "Formula: score = minmax_scale(log1p(raw), 0.01, 1) × max_pts (CLAUDE.md §5)"
echo "Notes: actual_scores.json 자동 갱신 (poll_scoreboard.py 5분/archive successful 시). status.json.score_estimate 폐기."
echo "Scoreboard: ${SCOREBOARD_URL:-https://upside.chainlight.io/} (iframe → https://REDACTED.example.invalid/scoreboard/)"
