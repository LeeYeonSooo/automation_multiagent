#!/usr/bin/env python3
"""Scan ALL QIx Transfer events to build a complete holder list with balances."""
import json
import subprocess
import sys
from collections import defaultdict

RPC = None
QIX = "0xe1ca10e6a10c0f72b74df6b7339912babfb1f8b5"  # Real QIx SuperToken
TRANSFER_SIG = "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"
START_BLOCK = 14425000
CHUNK = 9999

def get_env():
    global RPC
    env_path = "/Users/dldustn/Desktop/AssignmentC/.env"
    with open(env_path) as f:
        for line in f:
            line = line.strip()
            if line.startswith("RPC_CH4_SUPERFLUID="):
                RPC = line.split("=", 1)[1].strip('"').strip("'")
    if not RPC:
        print("ERROR: Could not find RPC_CH4_SUPERFLUID in .env")
        sys.exit(1)

def get_latest_block():
    r = subprocess.run(
        ["cast", "block-number", "--rpc-url", RPC],
        capture_output=True, text=True
    )
    return int(r.stdout.strip())

def fetch_logs(from_block, to_block):
    """Fetch Transfer logs for a block range."""
    r = subprocess.run(
        ["cast", "logs", "--from-block", str(from_block), "--to-block", str(to_block),
         "--address", QIX, TRANSFER_SIG, "--json", "--rpc-url", RPC],
        capture_output=True, text=True, timeout=30
    )
    if r.returncode != 0:
        return None
    try:
        return json.loads(r.stdout)
    except:
        return []

def main():
    get_env()
    latest = get_latest_block()
    print(f"Scanning QIx ({QIX}) Transfer events from block {START_BLOCK} to {latest}")
    print(f"Total range: {latest - START_BLOCK} blocks, ~{(latest - START_BLOCK) // CHUNK + 1} chunks")

    balances = defaultdict(int)
    zero_addr = "0x" + "0" * 40
    total_events = 0

    current = START_BLOCK
    chunk_count = 0
    errors = 0

    while current <= latest:
        end = min(current + CHUNK, latest)
        logs = fetch_logs(current, end)

        if logs is None:
            errors += 1
            if errors > 3:
                print(f"  Skipping block {current}-{end} after errors")
                current = end + 1
                errors = 0
                continue
            half = (end - current) // 2
            if half < 100:
                current = end + 1
                errors = 0
                continue
            end = current + half
            logs = fetch_logs(current, end)
            if logs is None:
                current = end + 1
                errors = 0
                continue

        errors = 0

        if logs:
            for log in logs:
                topics = log.get("topics", [])
                if len(topics) < 3:
                    continue
                from_addr = "0x" + topics[1][-40:]
                to_addr = "0x" + topics[2][-40:]
                data = log.get("data", "0x0")
                amount = int(data, 16) if data and data != "0x" else 0

                if from_addr.lower() != zero_addr:
                    balances[from_addr.lower()] -= amount
                if to_addr.lower() != zero_addr:
                    balances[to_addr.lower()] += amount

                total_events += 1

        chunk_count += 1
        if chunk_count % 100 == 0:
            pos_holders = sum(1 for v in balances.values() if v > 0)
            pct = (current - START_BLOCK) / (latest - START_BLOCK) * 100
            print(f"  Chunk {chunk_count} ({pct:.1f}%): block {current}-{end}, {total_events} events, {pos_holders} positive holders")
            sys.stdout.flush()

        current = end + 1

    print(f"\nDone! {total_events} total Transfer events processed in {chunk_count} chunks")

    # Filter positive balances
    positive = {k: v for k, v in balances.items() if v > 0}
    sorted_holders = sorted(positive.items(), key=lambda x: -x[1])

    print(f"\n{len(sorted_holders)} holders with positive transfer-derived balance:")
    total_bal = 0
    for addr, bal in sorted_holders[:100]:  # Show top 100
        print(f"  {addr}: {bal} ({bal / 1e18:.4f} QIx)")
        total_bal += bal
    if len(sorted_holders) > 100:
        remaining = sum(b for _, b in sorted_holders[100:])
        print(f"  ... and {len(sorted_holders) - 100} more holders with total {remaining / 1e18:.4f} QIx")
        total_bal += remaining
    print(f"\nTotal transfer-derived balance: {total_bal} ({total_bal / 1e18:.4f} QIx)")

    # Save holder list
    output = {
        "token": QIX,
        "total_events": total_events,
        "total_holders": len(sorted_holders),
        "holders": [{"address": addr, "transfer_balance": str(bal)} for addr, bal in sorted_holders]
    }

    out_path = "/Users/dldustn/Desktop/AssignmentC/challenges/ch4_superfluid/qix_holders_full.json"
    with open(out_path, "w") as f:
        json.dump(output, f, indent=2)
    print(f"\nSaved to {out_path}")

if __name__ == "__main__":
    main()
