#!/usr/bin/env bash
# health_check.sh - 환경 및 RPC 상태 확인
set -e

cd "$(dirname "$0")/.."
[ -f .env ] && { set -a; source .env; set +a; }

echo "=== Tooling ==="
for cmd in forge cast anvil codex claude jq curl python3 tmux; do
    if command -v "$cmd" >/dev/null 2>&1; then
        VER=$("$cmd" --version 2>&1 | head -1 || echo "?")
        printf "  %-10s ✓  %s\n" "$cmd" "$VER"
    else
        printf "  %-10s ✗  NOT INSTALLED\n" "$cmd"
    fi
done

echo
echo "=== RPC reachability ==="
for ch in CH1_URANIUM CH2_HARVEST CH3_FEIRARI CH4_SUPERFLUID CH5_SUPERFLUID_V2; do
    var="RPC_$ch"
    rpc="${!var:-}"
    if [ -z "$rpc" ]; then
        printf "  %-25s ✗  not set in .env\n" "$ch"
        continue
    fi
    
    # JSON-RPC eth_chainId
    resp=$(curl -s -m 10 -X POST -H "Content-Type: application/json" \
        --data '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}' \
        "$rpc" 2>&1)
    
    if echo "$resp" | grep -q '"result"'; then
        chain_id_hex=$(echo "$resp" | jq -r '.result' 2>/dev/null)
        chain_id=$(printf "%d" "$chain_id_hex" 2>/dev/null || echo "?")
        printf "  %-25s ✓  chain_id=%s\n" "$ch" "$chain_id"
    else
        printf "  %-25s ✗  %s\n" "$ch" "$(echo "$resp" | head -c 100)"
    fi
done

echo
echo "=== Discord webhook ==="
if [ -n "${DISCORD_WEBHOOK_URL:-}" ]; then
    echo "  Set: ${DISCORD_WEBHOOK_URL:0:50}..."
    if curl -s -o /dev/null -w "%{http_code}" "$DISCORD_WEBHOOK_URL" | grep -q "^[23]"; then
        echo "  Reachable: ✓"
    else
        echo "  Reachable: ✗ (Discord may have removed it or URL invalid)"
    fi
else
    echo "  ✗ DISCORD_WEBHOOK_URL not set"
fi

echo
echo "=== EOA balance (current) ==="
./tools/balance.sh all 2>/dev/null || echo "  (balance check failed)"
