#!/usr/bin/env bash
# reset.sh - 챌린지 RPC reset
#
# 공지에는 reset 엔드포인트가 RPC와 같은 URL로 주어짐 (POST 추정).
# 실제 호출 패턴은 시도해봐야 함. 보통 chainlight reset은 동일 URL POST 또는 별도 path.
#
# 이 스크립트는 두 가지 패턴을 시도:
#   1. POST <RPC_URL>           (body: {"method":"anvil_reset"})
#   2. GET <RPC_URL>/reset      (path 추가)
#
# 사용:
#   ./tools/reset.sh ch1
#   ./tools/reset.sh all   # 위험. 컨펌 필요

set -e

cd "$(dirname "$0")/.."
[ -f .env ] && { set -a; source .env; set +a; }

TARGET="${1:-}"
if [ -z "$TARGET" ]; then
    cat <<EOF
Usage: $0 ch1|ch2|ch3|ch4|ch5|all
EOF
    exit 1
fi

reset_one() {
    local ch="$1"
    local rpc
    case "$ch" in
        ch1|ch1_uranium)        rpc="$RPC_CH1_URANIUM" ;;
        ch2|ch2_harvest)        rpc="$RPC_CH2_HARVEST" ;;
        ch3|ch3_feirari)        rpc="$RPC_CH3_FEIRARI" ;;
        ch4|ch4_superfluid)     rpc="$RPC_CH4_SUPERFLUID" ;;
        ch5|ch5_superfluid_v2)  rpc="$RPC_CH5_SUPERFLUID_V2" ;;
        *) echo "unknown: $ch" >&2; return 1 ;;
    esac
    
    if [ -z "$rpc" ]; then
        echo "$ch: RPC not configured" >&2
        return 1
    fi
    
    echo "==> Resetting $ch ..."

    # 패턴 0 (mentor-confirmed, CLAUDE.md §4.6):
    #   GET https://REDACTED.example.invalid/rwN/reset/<token>
    # RPC URL 형식:
    #   https://REDACTED.example.invalid/rw<N>/rpc/<token>
    #   https://REDACTED.example.invalid/rw<N>/<token>
    # → rw<N>/.../<token> 경로를 rw<N>/reset/<token> 으로 정규화
    local reset_url0
    reset_url0=$(echo "$rpc" | sed -E 's|(/rw[0-9]+)/(rpc/)?([^/?]+)$|\1/reset/\3|')
    if [ "$reset_url0" != "$rpc" ]; then
        local http_code0
        local body_file="/tmp/reset_resp.$$"
        http_code0=$(curl -s -o "$body_file" -w "%{http_code}" -X GET "$reset_url0" 2>/dev/null || echo "000")
        local body0
        body0=$(head -c 200 "$body_file" 2>/dev/null || echo "")
        rm -f "$body_file"
        local url_tail
        url_tail=$(echo "$reset_url0" | sed -E 's|^https?://[^/]+||')
        echo "  [pattern 0: GET reset path] url_tail=$url_tail"
        echo "    http=$http_code0  body_head='$body0'"
        case "$http_code0" in
            2*|3*)
                echo "  OK (mentor GET reset): $ch reset"
                return 0
                ;;
        esac
        echo "  (pattern 0 non-2xx — falling through to fallbacks)"
    fi

    # 패턴 1: anvil_reset RPC 메서드 (anvil/hardhat node 일 경우)
    local resp1
    resp1=$(curl -s -X POST -H "Content-Type: application/json" \
        --data '{"jsonrpc":"2.0","method":"anvil_reset","params":[],"id":1}' \
        "$rpc" 2>&1)

    if echo "$resp1" | grep -q '"result"'; then
        echo "  OK (anvil_reset method): $resp1"
        return 0
    fi

    # 패턴 2: RPC URL의 /rpc/ 부분을 /reset/ 으로 치환 (legacy fallback)
    local reset_url
    reset_url=$(echo "$rpc" | sed 's|/rpc/|/reset/|')
    if [ "$reset_url" != "$rpc" ]; then
        local http_code3
        local body_file3="/tmp/reset_resp.$$"
        http_code3=$(curl -s -o "$body_file3" -w "%{http_code}" -X POST "$reset_url" 2>/dev/null || echo "000")
        local body3
        body3=$(head -c 200 "$body_file3" 2>/dev/null || echo "")
        rm -f "$body_file3"
        echo "  [pattern 2: POST with /rpc/→/reset/] http=$http_code3 body_head='$body3'"
        case "$http_code3" in
            2*|3*)
                echo "  OK (legacy /rpc/→/reset/): $ch reset"
                return 0
                ;;
        esac
        echo "  (pattern 2 non-2xx — reset not confirmed)"
    fi

    echo "  Could not determine reset method. Manual reset required at scoreboard UI."
    echo "  Tried: GET /reset/ path, anvil_reset RPC, URL substitution"
    echo "  Last response: $resp1"
    return 1
}

if [ "$TARGET" = "all" ]; then
    echo "이것은 5개 챌린지를 모두 리셋한다. 진짜로?  (yes/no)"
    read -r CONFIRM
    if [ "$CONFIRM" != "yes" ]; then
        echo "취소"
        exit 0
    fi
    for ch in ch1_uranium ch2_harvest ch3_feirari ch4_superfluid ch5_superfluid_v2; do
        reset_one "$ch" || true
    done
else
    reset_one "$TARGET"
fi

# 알림
./tools/notify.sh "Reset triggered: $TARGET" --warn 2>/dev/null || true
