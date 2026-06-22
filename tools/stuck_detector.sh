#!/usr/bin/env bash
# stuck_detector.sh — detect when a challenge has stalled and force brain to
# run creative_escalation.skill.md 8-step protocol.
#
# Runs alongside poll_scoreboard.py (or invoked periodically via cron).
# Unlike poll_scoreboard which only notifies ("stuck on ch5"), this script
# creates a FORCING .stuck_action marker that brain must address before any
# other work per CLAUDE.md §0 step 9.
#
# Usage:
#   ./tools/stuck_detector.sh                # check all 5 challenges
#   ./tools/stuck_detector.sh ch5_superfluid_v2  # specific challenge

set -e

cd "$(dirname "$0")/.."
[ -f .env ] && { set -a; source .env; set +a; }

CHALLENGES=(ch1_uranium ch2_harvest ch3_feirari ch4_superfluid ch5_superfluid_v2)
STUCK_THRESHOLD_MIN=${STUCK_THRESHOLD_MIN:-60}  # default 60 minutes
NOW_EPOCH=$(date +%s)

check_one() {
    local ch="$1"
    local sf="challenges/$ch/status.json"
    [ -f "$sf" ] || return 0

    # Score-stuck: actual_scores.json didn't change this challenge's score in STUCK_THRESHOLD_MIN
    # We rely on status.json.last_update + score gap
    local last_update=$(jq -r '.last_update // ""' "$sf" 2>/dev/null)
    [ -n "$last_update" ] || return 0

    # Parse ISO8601 UTC to epoch (portable)
    local last_epoch=$(python3 -c "from datetime import datetime; print(int(datetime.fromisoformat('$last_update'.replace('Z','+00:00')).timestamp()))" 2>/dev/null || echo "$NOW_EPOCH")
    local age_min=$(( (NOW_EPOCH - last_epoch) / 60 ))

    local state=$(jq -r '.state // "?"' "$sf" 2>/dev/null)
    # Skip if already exploited (unless in a "more-to-drain" scenario — brain decides)
    if [ "$state" = "exploited" ]; then
        return 0
    fi
    # Skip if already abandoned
    if [ "$state" = "abandoned" ]; then
        return 0
    fi

    # Retrieve score + gap from actual_scores.json
    local score="?"
    local gap="?"
    local leader_score="?"
    local max_pts="?"
    if [ -f actual_scores.json ]; then
        score=$(jq -r ".${ch}.score // \"?\"" actual_scores.json 2>/dev/null)
        gap=$(jq -r ".${ch}.gap_to_leader // \"?\"" actual_scores.json 2>/dev/null)
        leader_score=$(jq -r ".${ch}.leader_score // \"?\"" actual_scores.json 2>/dev/null)
        max_pts=$(jq -r ".${ch}.max_pts // \"?\"" actual_scores.json 2>/dev/null)
    fi

    # Stuck condition: age >= threshold AND score not at cap (max_pts)
    local is_stuck=0
    if [ "$age_min" -ge "$STUCK_THRESHOLD_MIN" ]; then
        if [ "$score" != "$max_pts" ]; then
            is_stuck=1
        fi
    fi

    # Count recent attempts without progress
    local attempts=$(jq -r '.current_attempt // 0' "$sf" 2>/dev/null)
    local dead_end_count=$(jq -r '.dead_ends // [] | length' "$sf" 2>/dev/null)

    # Also stuck if dead_ends has grown by ≥3 without balance progress
    if [ "$dead_end_count" -ge 3 ] && [ "$age_min" -ge "$STUCK_THRESHOLD_MIN" ]; then
        is_stuck=1
    fi

    if [ "$is_stuck" -eq 1 ]; then
        local marker="challenges/$ch/.stuck_action"
        {
            echo "# STUCK_ACTION: $ch"
            echo "Detected: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
            echo ""
            echo "## Stall signals"
            echo "- last_update age: ${age_min} min (threshold ${STUCK_THRESHOLD_MIN} min)"
            echo "- current state: $state"
            echo "- current_attempt: $attempts"
            echo "- dead_ends accumulated: $dead_end_count"
            echo "- score: $score / $max_pts (gap to leader $leader_score = $gap)"
            echo ""
            echo "## Required action (Brain, per CLAUDE.md §0 step 9)"
            echo ""
            echo "RUN creative_escalation.skill.md 8-step protocol IN PERSON (not just read it):"
            echo "1. Constraint Reframing — re-read scoring model + max_pts. What's the minimum raw delta we need for next-tier score?"
            echo "2. Cross-Challenge Synthesis — read ALL 5 challenges' analysis.md Dead Ends. Do any patterns repeat?"
            echo "3. Multi-Hypothesis Branching — force yourself to write 3 NEW hypotheses you haven't tried."
            echo "4. Combine Attack Vectors — can two ${ch} vulnerabilities chain?"
            echo "5. Victim Enumeration Deepening — for Superfluid, re-scan SuperApps with later blocks for IndexUpdated activity."
            echo "6. Iteration Curve Re-fit — if challenge is iterable (ch2), refit gradient."
            echo "7. Asset Path Optimization — review ERC20→native conversion paths."
            echo "8. Read the Source Twice — open sources/$ch/*/src/ and re-read critical files from scratch, looking for what you missed first time."
            echo ""
            echo "## Output this action requires"
            echo "- analysis.md: new \"## Creative Escalation (run at $(date -u +%Y-%m-%dT%H:%M:%SZ))\" section with findings from each of the 8 steps"
            echo "- At least 1 new hypothesis delegated via ./tools/delegate.sh <ch> poc \"<hypothesis>\""
            echo "- This marker file (.stuck_action) deleted only after new attempt is delegated"
            echo ""
            echo "## Cross-references"
            echo "- skills/creative_escalation.skill.md (the 8 steps)"
            echo "- skills/deep_analysis.skill.md §8-§10 (self-critique, analog reasoning, cross-challenge)"
            echo "- knowledge/mentor_hints.md §6 (ch5 specific hints)"
            echo "- knowledge/external_refs.md §5 (ch5 external resources)"
            echo "- challenges/$ch/analysis.md (current state)"
            echo "- challenges/$ch/exploits/ARCHIVE_LOG.md (attempt history)"
        } > "$marker"

        if [ -x ./tools/notify.sh ]; then
            ./tools/notify.sh "STUCK: $ch ${age_min}min idle, ${dead_end_count} dead_ends, score=$score/$max_pts. Marker: $marker" --warn 2>/dev/null || true
        fi

        echo "STUCK: $ch (age=${age_min}min, attempts=$attempts, dead_ends=$dead_end_count, score=$score/$max_pts)"
        return 1
    fi

    return 0
}

if [ $# -eq 1 ]; then
    check_one "$1"
    exit $?
fi

# Check all
ANY_STUCK=0
for ch in "${CHALLENGES[@]}"; do
    check_one "$ch" || ANY_STUCK=1
done

if [ "$ANY_STUCK" -eq 0 ]; then
    echo "stuck_detector: no challenges stuck"
fi
exit 0
