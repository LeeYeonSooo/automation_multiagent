#!/usr/bin/env python3
"""Continue draining MATICx rows 801+ on the current fork state (no reset)."""
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
MIN_MATICX = 10**15
BATCH_SIZE = 25
BATCH_GAS_LIMIT = 29_000_000
START_ROW = 801  # rows 1-800 already drained
END_ROW = 2000   # start with rows 801-2000, extend if needed
TARGET_GAIN = 20_000 * 10**18  # 20K MATIC should be more than enough


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


def send_tx(to=None, sig=None, args=None, gas_limit=None, create_bytecode=None):
    cmd = ["cast", "send", "--async", "--rpc-url", RPC, "--private-key", PRIVATE_KEY, "--rpc-timeout", "120"]
    if gas_limit:
        cmd += ["--gas-limit", str(gas_limit)]
    if create_bytecode:
        cmd += ["--create", create_bytecode]
    else:
        cmd.append(to)
        cmd.append(sig)
        if args:
            cmd.extend(args)
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


def load_maticx_rows(start, end):
    rows = []
    tsv = (RECON / "tmp_scan" / "maticx_fork24684669_positive_full.tsv").read_text().splitlines()
    for i, line in enumerate(tsv, 1):
        if i < start:
            continue
        if i > end:
            break
        addr, bal = line.split("\t")
        rows.append((i, addr, int(bal)))
    return rows


def main():
    start_balance = cast_balance()
    print(f"start_balance: {start_balance} ({start_balance / 10**18:.2f} MATIC)")

    # Deploy helper
    print("Compiling...")
    bytecode, _ = run(["forge", "inspect", "Run", "bytecode"])
    bytecode = bytecode.strip()

    print("Deploying helper...")
    tx_hash, raw, rc = send_tx(create_bytecode=bytecode, gas_limit=5_000_000)
    if rc != 0 or not tx_hash:
        raise RuntimeError(f"deploy failed: {raw[:300]}")

    receipt = wait_receipt(tx_hash)
    helper = receipt.get("contractAddress")
    if not helper:
        raise RuntimeError(f"no helper address: {receipt}")
    print(f"helper deployed: {helper} tx={tx_hash}")

    # Load rows
    rows = load_maticx_rows(START_ROW, END_ROW)
    print(f"Loaded {len(rows)} rows ({START_ROW}-{END_ROW})")

    total_gained = 0
    successful = 0
    failed = 0

    for batch_start in range(0, len(rows), BATCH_SIZE):
        chunk = rows[batch_start:batch_start + BATCH_SIZE]
        addresses = [addr for _, addr, _ in chunk]
        row_range = f"{chunk[0][0]}-{chunk[-1][0]}"

        # Preview
        preview_out, preview_rc = run([
            "cast", "call", "--rpc-url", RPC, helper,
            "previewSameTokenBatchCheckedNonApp(address,address[],uint256)(uint256,uint256)",
            MATICX, encode_array(addresses), str(MIN_MATICX),
        ], check=False)

        nums = [int(x, 0) for x in re.findall(r"0x[0-9a-fA-F]+|\b\d+\b", preview_out)]
        eligible = nums[0] if len(nums) >= 2 else 0
        preview_total = nums[1] if len(nums) >= 2 else 0

        if eligible == 0 or preview_total == 0:
            print(f"  rows {row_range}: skip (eligible={eligible})")
            continue

        print(f"  rows {row_range}: {eligible} eligible, ~{preview_total / 10**18:.1f} MATICx")

        # Send batch
        floor = max(preview_total // 2, 1)
        tx_hash, raw, rc = send_tx(
            to=helper,
            sig="executeSameTokenBatchCheckedNonAppCapped(address,address[],uint256,uint256)",
            args=[MATICX, encode_array(addresses), str(MIN_MATICX), str(floor)],
            gas_limit=BATCH_GAS_LIMIT,
        )

        if rc != 0 or not tx_hash:
            failed += 1
            print(f"    SEND FAIL: {raw[:200]}")
            continue

        receipt = wait_receipt(tx_hash)
        status = receipt.get("status")
        if isinstance(status, str):
            status_int = int(status, 16) if status.startswith("0x") else int(status)
        else:
            status_int = int(status) if status else 0

        if status_int != 1:
            failed += 1
            print(f"    REVERT tx={tx_hash}")
            continue

        successful += 1
        current = cast_balance()
        batch_gain = current - start_balance - total_gained
        total_gained = current - start_balance
        print(f"    OK tx={tx_hash} +{batch_gain / 10**18:.1f} MATIC (total: +{total_gained / 10**18:.1f})")

        if total_gained >= TARGET_GAIN:
            print(f"\nTarget reached! +{total_gained / 10**18:.1f} MATIC")
            break

    final_balance = cast_balance()
    print(f"\n=== DONE ===")
    print(f"Final balance: {final_balance / 10**18:.2f} MATIC")
    print(f"Total gained: {(final_balance - start_balance) / 10**18:.2f} MATIC")
    print(f"Successful: {successful}, Failed: {failed}")


if __name__ == "__main__":
    main()
