#!/usr/bin/env bash
# balance.sh - 한 챌린지의 본인 EOA native balance 출력
#
# 사용:
#   ./tools/balance.sh ch1
#   ./tools/balance.sh all

set -e

cd "$(dirname "$0")/.."
[ -f .env ] && { set -a; source .env; set +a; }

TARGET="${1:-all}"

check_one() {
    local ch="$1"
    local rpc_var
    case "$ch" in
        ch1|ch1_uranium)        rpc_var="$RPC_CH1_URANIUM" ;;
        ch2|ch2_harvest)        rpc_var="$RPC_CH2_HARVEST" ;;
        ch3|ch3_feirari)        rpc_var="$RPC_CH3_FEIRARI" ;;
        ch4|ch4_superfluid)     rpc_var="$RPC_CH4_SUPERFLUID" ;;
        ch5|ch5_superfluid_v2)  rpc_var="$RPC_CH5_SUPERFLUID_V2" ;;
        *) echo "unknown: $ch" >&2; return 1 ;;
    esac
    
    if [ -z "$rpc_var" ]; then
        echo "$ch: RPC not configured"
        return
    fi
    
    if ! command -v cast >/dev/null 2>&1; then
        echo "$ch: cast (Foundry) not installed"
        return
    fi
    
    local bal
    bal=$(cast balance "$PUBLIC_ADDRESS" --rpc-url "$rpc_var" 2>/dev/null || echo "ERROR")
    
    if [ "$bal" = "ERROR" ]; then
        printf "%-22s %s\n" "$ch" "RPC unreachable"
    else
        local bal_eth
        bal_eth=$(python3 -c "print(f'{int(\"$bal\")/1e18:.6f}')" 2>/dev/null || echo "$bal")
        printf "%-22s %s wei  (%s native)\n" "$ch" "$bal" "$bal_eth"
    fi
}

if [ "$TARGET" = "all" ]; then
    echo "Native balance of $PUBLIC_ADDRESS on each fork:"
    echo
    for ch in ch1_uranium ch2_harvest ch3_feirari ch4_superfluid ch5_superfluid_v2; do
        check_one "$ch"
    done
else
    check_one "$TARGET"
fi
