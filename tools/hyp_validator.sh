#!/usr/bin/env bash
# hyp_validator.sh — enforce skills/hypothesis_quality.skill.md §1-§2 on a
# challenge's analysis.md after a poc/debug task completes.
#
# Usage:
#   ./tools/hyp_validator.sh <challenge> <attempt_N>
#
# Exit codes:
#   0 — all mandatory sections present, each hypothesis has 5 subfields
#   1 — structural failure (missing section or malformed hypothesis block)
#   2 — invocation error
#
# This runs automatically after poc/debug task. Failing tasks are flagged in
# a .hyp_quality_fail marker that brain must address before proceeding.

set -e

cd "$(dirname "$0")/.."

if [ "$#" -lt 2 ]; then
    echo "Usage: $0 <challenge> <attempt_N>" >&2
    echo "  challenge: ch1_uranium | ch2_harvest | ch3_feirari | ch4_superfluid | ch5_superfluid_v2" >&2
    exit 2
fi

CH="$1"
N="$2"
ANALYSIS="challenges/$CH/analysis.md"

if [ ! -f "$ANALYSIS" ]; then
    echo "HYP_QUALITY: fail: analysis.md not found at $ANALYSIS" >&2
    exit 1
fi

FAILURES=""
add_fail() { FAILURES="${FAILURES}
  - $1"; }

extract_section() {
    local title="$1"
    awk -v title="$title" '
        $0 == title { in_sec = 1; next }
        /^## / && in_sec { exit }
        in_sec { print }
    ' "$ANALYSIS"
}

extract_hyp_block() {
    local title="$1"
    awk -v title="$title" '
        index($0, title) == 1 { in_sec = 1; next }
        /^### Hyp[A-Z] / && in_sec { exit }
        /^## / && in_sec { exit }
        in_sec { print }
    ' "$ANALYSIS"
}

# Mandatory sections (see skills/hypothesis_quality.skill.md §1)
for sec in "Code Observations (Attempt $N)" "Hypothesis Tree (Attempt $N)" "Self-Critique (Attempt $N)" "Analog Cross-Reference (Attempt $N)"; do
    if ! grep -qF "$sec" "$ANALYSIS"; then
        add_fail "missing section: ## $sec"
    fi
done

# Code Observations length check (>=500 words)
OBS_SEC=$(extract_section "## Code Observations (Attempt $N)")
if [ -n "$OBS_SEC" ]; then
    WORD_COUNT=$(echo "$OBS_SEC" | wc -w | tr -d ' ')
    if [ "$WORD_COUNT" -lt 500 ]; then
        add_fail "Code Observations (Attempt $N) only $WORD_COUNT words; required ≥500"
    fi
fi

# Hypothesis Tree: at least 3 Hyp<Letter> blocks
HYP_SEC=$(extract_section "## Hypothesis Tree (Attempt $N)")
HYP_COUNT=$(echo "$HYP_SEC" | grep -cE "^### Hyp[A-Z] ")
if [ "$HYP_COUNT" -lt 3 ]; then
    add_fail "Hypothesis Tree has only $HYP_COUNT ### Hyp<Letter> blocks; required ≥3"
fi

# Each Hyp block has 5 subfields
HYP_LETTERS=$(echo "$HYP_SEC" | grep -oE "^### Hyp[A-Z] " | awk '{print $2}')
for H in $HYP_LETTERS; do
    HYP_BLOCK=$(extract_hyp_block "### $H ")
    for field in "Why (prior evidence)" "Expected outcome on success" "Expected revert pattern on failure" "Single-line test plan" "Three-axis tag"; do
        if ! echo "$HYP_BLOCK" | grep -qF "$field"; then
            add_fail "$H missing subfield: $field"
        fi
    done
    # Three-axis tag must have 3 axes + score
    for axis in "code-level" "logic-level" "known-pattern"; do
        if ! echo "$HYP_BLOCK" | grep -qE "^\s*-\s*$axis:"; then
            add_fail "$H three-axis tag missing axis: $axis"
        fi
    done
done

# Conditional: if sources/<ch>/ contains both verified and unverified impl, Bytecode Diff mandatory
if find "sources/$CH" -maxdepth 1 -mindepth 1 -name '*unverified*' | grep -q . && \
   find "sources/$CH" -maxdepth 1 -mindepth 1 -name '*public*' | grep -q .; then
    if ! grep -qF "Bytecode Diff (Attempt $N)" "$ANALYSIS"; then
        add_fail "sources/$CH/ has verified+unverified impl → Bytecode Diff (Attempt $N) section required"
    fi
fi

# Conditional: ch4/ch5 require Cross-Challenge Check
case "$CH" in
    ch4_superfluid|ch5_superfluid_v2)
        if ! grep -qF "Cross-Challenge Check (Attempt $N)" "$ANALYSIS"; then
            add_fail "$CH requires Cross-Challenge Check (Attempt $N) section (per cross_challenge.skill.md)"
        fi
        ;;
esac

if [ -n "$FAILURES" ]; then
    MARKER="challenges/$CH/.hyp_quality_fail_attempt${N}"
    {
        echo "HYP_QUALITY_FAIL: $CH Attempt $N"
        echo "Validator timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "Failures:$FAILURES"
        echo ""
        echo "Action required: brain reviews and either (a) re-delegates with prompt fix, or (b) manually patches analysis.md to add missing sections."
        echo "See: skills/hypothesis_quality.skill.md §3 for severity response."
    } > "$MARKER"
    echo "HYP_QUALITY: fail" >&2
    echo "$FAILURES" >&2
    echo "" >&2
    echo "Marker written: $MARKER" >&2
    exit 1
fi

echo "HYP_QUALITY: pass — $CH Attempt $N"
exit 0
