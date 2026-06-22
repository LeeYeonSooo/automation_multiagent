#!/usr/bin/env python3
"""Scan all MATICx holders from recon data and output non-zero balances."""
import json
import urllib.request
import sys
import concurrent.futures
import time

RPC = "https://REDACTED.example.invalid/9211c782-ae68-44dd-96a4-6a307c4e3091/rpc/4gi_akali:575d580ce56856c4751f2afb8daf13cc21c4eefd48958f1734e36a44d5f23734"
MATICX = "0x3aD736904E9e65189c3000c7DD2c8AC8bB7cD4e3"
RECON_FILE = "/Users/dldustn/Desktop/upside_assignment/AssignmentC/challenges/ch4_superfluid/recon/tmp_scan/maticx_fork24684669_positive_full.tsv"
OUTPUT = "/Users/dldustn/Desktop/upside_assignment/AssignmentC/for_test/superfluid_e1/victims.json"


def check_balance(addr):
    data = '0x70a08231' + addr[2:].zfill(64)
    payload = json.dumps({'jsonrpc': '2.0', 'id': 1, 'method': 'eth_call',
                          'params': [{'to': MATICX, 'data': data}, 'latest']}).encode()
    req = urllib.request.Request(RPC, data=payload, headers={'content-type': 'application/json'})
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            result = json.loads(resp.read())
        return addr, int(result.get('result', '0x0'), 16)
    except Exception:
        return addr, -1  # retry later


def main():
    addrs = []
    with open(RECON_FILE) as f:
        for line in f:
            parts = line.strip().split('\t')
            if len(parts) >= 2:
                addrs.append(parts[0])

    print(f"Total addresses to scan: {len(addrs)}", file=sys.stderr)

    found = []
    failed = []
    scanned = 0

    with concurrent.futures.ThreadPoolExecutor(max_workers=10) as pool:
        futures = {pool.submit(check_balance, addr): addr for addr in addrs}
        for future in concurrent.futures.as_completed(futures):
            addr, bal = future.result()
            scanned += 1
            if bal > 0:
                found.append((addr, bal))
            elif bal == -1:
                failed.append(addr)
            if scanned % 1000 == 0:
                print(f"  Scanned {scanned}/{len(addrs)}, found {len(found)}, failed {len(failed)}", file=sys.stderr)

    # Retry failed ones
    if failed:
        print(f"Retrying {len(failed)} failed addresses...", file=sys.stderr)
        time.sleep(2)
        for addr in failed:
            addr, bal = check_balance(addr)
            if bal > 0:
                found.append((addr, bal))

    found.sort(key=lambda x: -x[1])
    total = sum(b for _, b in found)

    print(f"\nResults:", file=sys.stderr)
    print(f"  Non-zero holders: {len(found)}", file=sys.stderr)
    print(f"  Total balance: {total / 1e18:.2f} MATIC", file=sys.stderr)
    print(f"  Contract backing: 173014.15 MATIC", file=sys.stderr)
    print(f"  Coverage: {total / 173014147927938260623802 * 100:.2f}%", file=sys.stderr)

    # Save to JSON
    output = {
        "total_holders": len(found),
        "total_balance": str(total),
        "total_balance_ether": total / 1e18,
        "victims": [{"addr": addr, "balance": str(bal)} for addr, bal in found]
    }
    with open(OUTPUT, 'w') as f:
        json.dump(output, f, indent=2)

    print(f"\nSaved to {OUTPUT}", file=sys.stderr)

    # Also print top and bottom
    for addr, bal in found[:10]:
        print(f"  {addr}: {bal / 1e18:.4f}", file=sys.stderr)
    print(f"  ...", file=sys.stderr)
    for addr, bal in found[-5:]:
        print(f"  {addr}: {bal / 1e18:.10f}", file=sys.stderr)


if __name__ == '__main__':
    main()
