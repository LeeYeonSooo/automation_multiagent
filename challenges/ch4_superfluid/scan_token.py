#!/usr/bin/env python3
"""Scan any SuperToken Transfer events to find all holders."""
import json
import subprocess
import sys
from collections import defaultdict

TRANSFER_SIG = "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"
CHUNK = 9999

def get_rpc():
    env_path = "/Users/dldustn/Desktop/AssignmentC/.env"
    with open(env_path) as f:
        for line in f:
            line = line.strip()
            if line.startswith("RPC_CH4_SUPERFLUID="):
                return line.split("=", 1)[1].strip('"').strip("'")
    return None

def fetch_logs(rpc, token, from_block, to_block):
    r = subprocess.run(
        ["cast", "logs", "--from-block", str(from_block), "--to-block", str(to_block),
         "--address", token, TRANSFER_SIG, "--json", "--rpc-url", rpc],
        capture_output=True, text=True, timeout=30
    )
    if r.returncode != 0:
        return None
    try:
        return json.loads(r.stdout)
    except:
        return []

def find_deployment(rpc, token):
    """Binary search for deployment block."""
    lo, hi = 0, int(subprocess.run(["cast", "block-number", "--rpc-url", rpc], capture_output=True, text=True).stdout.strip())
    while lo < hi:
        mid = (lo + hi) // 2
        r = subprocess.run(["cast", "code", token, "--block", str(mid), "--rpc-url", rpc], capture_output=True, text=True)
        if r.stdout.strip() == "0x":
            lo = mid + 1
        else:
            hi = mid
    return lo

def scan_token(token_addr, name="token"):
    rpc = get_rpc()
    r = subprocess.run(["cast", "block-number", "--rpc-url", rpc], capture_output=True, text=True)
    latest = int(r.stdout.strip())

    start = find_deployment(rpc, token_addr)
    print(f"Scanning {name} ({token_addr}) from block {start} to {latest}")

    balances = defaultdict(int)
    zero_addr = "0x" + "0" * 40
    total_events = 0
    current = start

    while current <= latest:
        end = min(current + CHUNK, latest)
        logs = fetch_logs(rpc, token_addr, current, end)
        if logs is None:
            current = end + 1
            continue
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
        current = end + 1

    positive = {k: v for k, v in balances.items() if v > 0}
    sorted_holders = sorted(positive.items(), key=lambda x: -x[1])
    print(f"\n{total_events} events, {len(sorted_holders)} holders with positive balance:")
    for addr, bal in sorted_holders[:50]:
        print(f"  {addr}: {bal} ({bal/1e18:.4f})")
    return sorted_holders

if __name__ == "__main__":
    if len(sys.argv) < 3:
        print("Usage: scan_token.py <address> <name>")
        sys.exit(1)
    scan_token(sys.argv[1], sys.argv[2])
