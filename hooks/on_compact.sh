#!/usr/bin/env bash
# on_compact.sh - PreCompact hook. 압축 직전 PROGRESS.md 갱신 + 핵심 상태 보존
set -e
cd "$(dirname "$0")/.." 2>/dev/null || true

# 현재 상태 스냅샷
{
    echo "## 압축 시점 스냅샷 ($(date))"
    echo
    if [ -x ./tools/score.sh ]; then
        ./tools/score.sh 2>/dev/null
    fi
    echo
    echo "### 활성 챌린지 가설"
    for f in challenges/*/status.json; do
        [ -f "$f" ] || continue
        ch=$(basename $(dirname "$f"))
        state=$(jq -r '.state' "$f" 2>/dev/null)
        hyp=$(jq -r '.active_hypothesis // ""' "$f" 2>/dev/null)
        if [ "$state" != "not_started" ] && [ "$state" != "exploited" ]; then
            echo "- **$ch** ($state): $hyp"
        fi
    done
    echo
    echo "### 다음 액션 후보"
    echo "(Claude는 PROGRESS.md 우선순위 큐 + 위 가설 참조해 결정)"
} > .compact_state.md

# PROGRESS.md 갱신
./tools/status.sh > /dev/null 2>&1 || true

# allow continue
echo '{}'
