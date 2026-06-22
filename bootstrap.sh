#!/usr/bin/env bash
# bootstrap.sh - 첫 실행 인터랙티브 셋업
set -e
cd "$(dirname "$0")"
ROOT="$(pwd)"

echo "=========================================="
echo "  Upside Real World Assignment C"
echo "  Multi-agent Harness Bootstrap"
echo "=========================================="
echo "Working dir: $ROOT"
echo

# 1. .env 셋업
echo "[1/7] .env 셋업..."
if [ -f .env ]; then
    echo "  .env 이미 존재. 덮어쓸까? (y/n)"
    read -r ans
    if [ "$ans" = "y" ]; then
        cp .env.template .env
        echo "  .env 갱신됨"
    fi
else
    cp .env.template .env
    echo "  .env 생성됨"
fi

# 2. 권한
echo
echo "[2/7] 실행 권한 부여..."
chmod +x bootstrap.sh tools/*.sh tools/*.py hooks/*.sh orchestrator/*.sh 2>/dev/null || true
echo "  done"

# 3. 의존성
echo
echo "[3/7] 의존성 확인..."
if ! command -v tmux >/dev/null 2>&1; then
    echo "  ⚠️  tmux 미설치. 'brew install tmux' 권장"
    echo "  지금 설치할까? (y/n)"
    read -r ans
    [ "$ans" = "y" ] && brew install tmux
fi
for cmd in forge cast anvil codex claude jq curl python3; do
    if command -v "$cmd" >/dev/null 2>&1; then
        echo "  $cmd: ✓"
    else
        echo "  $cmd: ✗ NOT INSTALLED"
    fi
done

# 4. 디렉토리
echo
echo "[4/7] 디렉토리 검증..."
for ch in ch1_uranium ch2_harvest ch3_feirari ch4_superfluid ch5_superfluid_v2; do
    mkdir -p "challenges/$ch"/{recon/abis,poc,exploit,runs}
done
mkdir -p shared/inbox logs
echo "  done"

# 5. status.json + analysis.md 초기화
echo
echo "[5/7] 챌린지 파일 초기화..."
for ch in ch1_uranium ch2_harvest ch3_feirari ch4_superfluid ch5_superfluid_v2; do
    SF="challenges/$ch/status.json"
    if [ ! -f "$SF" ]; then
        cat > "$SF" <<EOF
{
  "challenge": "$ch",
  "state": "not_started",
  "current_attempt": 0,
  "balance_delta_wei": "0",
  "score_estimate": 0,
  "last_update": "",
  "needs_human": false,
  "active_hypothesis": "",
  "dead_ends": [],
  "notes": ""
}
EOF
    fi
    AF="challenges/$ch/analysis.md"
    if [ ! -f "$AF" ]; then
        cat > "$AF" <<EOF
# $ch — Analysis

## Hypothesis (current)
(미정 — Claude가 채울 것)

## Target contracts
| Role | Address | Note |
|---|---|---|

## Attack chain
(미정)

## References
- knowledge/case_*.md
- skills/exploit_*.skill.md

## Dead ends

## BONUS observations
EOF
    fi
done
echo "  done"

# 6. RPC ping
echo
echo "[6/7] RPC 연결 테스트..."
set -a; source .env; set +a
for var in RPC_CH1_URANIUM RPC_CH2_HARVEST RPC_CH3_FEIRARI RPC_CH4_SUPERFLUID RPC_CH5_SUPERFLUID_V2; do
    rpc="${!var:-}"
    if [ -z "$rpc" ]; then
        printf "  %-30s ✗ not set\n" "$var"
        continue
    fi
    resp=$(curl -s -m 10 -X POST -H "Content-Type: application/json" \
        --data '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}' \
        "$rpc" 2>&1 || echo "FAIL")
    if echo "$resp" | grep -q '"result"'; then
        chain_id_hex=$(echo "$resp" | jq -r '.result' 2>/dev/null)
        chain_id=$(printf "%d" "$chain_id_hex" 2>/dev/null || echo "?")
        printf "  %-30s ✓ chain_id=%s\n" "$var" "$chain_id"
    else
        printf "  %-30s ✗ %s\n" "$var" "$(echo "$resp" | head -c 80)"
    fi
done

# 7. Discord
echo
echo "[7/7] Discord webhook 테스트..."
if [ -n "${DISCORD_WEBHOOK_URL:-}" ]; then
    ./tools/notify.sh "Bootstrap complete on $(hostname)" 2>/dev/null && echo "  ✓ Discord 메시지 전송됨"
fi

echo
echo "=========================================="
echo "  Bootstrap 완료!"
echo "=========================================="
echo
echo "다음 단계:"
echo "  1. ./tools/health_check.sh"
echo "  2. ./orchestrator/tmux_layout.sh"
echo "  3. tmux 안 pane 0에서 'claude' 자동 실행됨"
echo "  4. 첫 prompt:"
echo "     @CLAUDE.md @PROGRESS.md ch1_uranium 부터 시작"
echo
echo "재진입: tmux a -t upside"
