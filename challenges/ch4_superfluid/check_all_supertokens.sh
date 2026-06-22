#!/bin/bash
source /Users/dldustn/Desktop/AssignmentC/.env
RPC=$RPC_CH4_SUPERFLUID

# Check all factory tokens for remaining supply
while IFS= read -r addr; do
    ts=$(cast call "$addr" "totalSupply()(uint256)" --rpc-url "$RPC" 2>/dev/null)
    if [ -z "$ts" ] || [ "$ts" = "0" ]; then
        continue
    fi
    # Parse the number
    raw=$(echo "$ts" | awk '{print $1}')
    if [ "$raw" != "0" ]; then
        name=$(cast call "$addr" "symbol()(string)" --rpc-url "$RPC" 2>/dev/null)
        echo "$addr $name: $ts"
    fi
done < /Users/dldustn/Desktop/AssignmentC/challenges/ch4_superfluid/runs/factory_tokens_current.txt
