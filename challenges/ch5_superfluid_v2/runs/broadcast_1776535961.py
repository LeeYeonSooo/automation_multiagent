#!/usr/bin/env python3
import json
import os
import pathlib
import subprocess
import sys
from datetime import datetime, timezone


ROOT = pathlib.Path("/Users/dldustn/Desktop/AssignmentC")
CH_DIR = ROOT / "challenges" / "ch5_superfluid_v2"
MANIFEST_PATH = CH_DIR / "broadcast" / "Run.s.sol" / "2403" / "dry-run" / "run-latest.json"
PREFLIGHT_PATH = CH_DIR / "runs" / "exploit_1776535961_preflight.json"
LOG_PATH = CH_DIR / "runs" / "exploit_1776535961.log"


def run(cmd: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(cmd, text=True, capture_output=True)


def log(line: str = "") -> None:
    with LOG_PATH.open("a") as fh:
        fh.write(line)
        if not line.endswith("\n"):
            fh.write("\n")


def receipt_or_die(raw: str, tx_index: int) -> dict:
    try:
        receipt = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise SystemExit(f"failed to parse receipt at tx {tx_index}: {exc}") from exc

    if receipt.get("status") != "0x1":
        raise SystemExit(f"tx {tx_index} reverted")

    return receipt


def main() -> int:
    rpc = os.environ["RPC_CH5_SUPERFLUID_V2"]
    private_key = os.environ["PRIVATE_KEY"]
    public_address = os.environ["PUBLIC_ADDRESS"]

    manifest = json.loads(MANIFEST_PATH.read_text())
    transactions = manifest["transactions"]

    LOG_PATH.write_text("")
    log(f"=== exploit_1776535961 {datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')} ===")
    log("manual broadcast from broadcast/Run.s.sol/2403/dry-run/run-latest.json after forge script runner hung before first tx")
    log(PREFLIGHT_PATH.read_text())

    pre_nonce = run(["cast", "nonce", public_address, "--rpc-url", rpc])
    pre_balance = run(["cast", "balance", public_address, "--rpc-url", rpc])
    if pre_nonce.returncode != 0 or pre_balance.returncode != 0:
        log(pre_nonce.stderr)
        log(pre_balance.stderr)
        return 1

    pre_nonce_str = pre_nonce.stdout.strip()
    pre_balance_str = pre_balance.stdout.strip()
    log(f"$ cast nonce $PUBLIC_ADDRESS --rpc-url $RPC_CH5_SUPERFLUID_V2\n{pre_nonce_str}")
    log(f"$ cast balance $PUBLIC_ADDRESS --rpc-url $RPC_CH5_SUPERFLUID_V2\n{pre_balance_str}")

    if int(pre_nonce_str) != 0:
        log("ERROR: nonce is not 0 on reset head; refusing manifest replay")
        return 1

    hashes: list[str] = []

    for idx, tx in enumerate(transactions, 1):
        transaction = tx["transaction"]
        gas_limit = str(int(transaction["gas"], 16))
        value = str(int(transaction.get("value", "0x0"), 16))

        if tx["transactionType"] == "CREATE":
            display = (
                f"$ cast send --gas-limit {gas_limit} --rpc-url $RPC_CH5_SUPERFLUID_V2 "
                "--private-key $PRIVATE_KEY --json --create <input>"
            )
            cmd = [
                "cast",
                "send",
                "--gas-limit",
                gas_limit,
                "--rpc-url",
                rpc,
                "--private-key",
                private_key,
                "--json",
                "--create",
                transaction["input"],
            ]
            if value != "0":
                cmd.extend(["--value", value])
        else:
            signature = tx["function"]
            args = [str(arg) for arg in (tx.get("arguments") or [])]
            joined_args = " ".join(args)
            suffix = f' "{signature}"'
            if joined_args:
                suffix += f" {joined_args}"
            if value != "0":
                suffix += f" --value {value}"

            display = (
                f"$ cast send --gas-limit {gas_limit} --rpc-url $RPC_CH5_SUPERFLUID_V2 "
                f"--private-key $PRIVATE_KEY --json {tx['contractAddress']}{suffix}"
            )
            cmd = [
                "cast",
                "send",
                "--gas-limit",
                gas_limit,
                "--rpc-url",
                rpc,
                "--private-key",
                private_key,
                "--json",
                tx["contractAddress"],
                signature,
                *args,
            ]
            if value != "0":
                cmd.extend(["--value", value])

        log(display)
        proc = run(cmd)
        if proc.stdout:
            log(proc.stdout)
        if proc.stderr:
            log(proc.stderr)
        if proc.returncode != 0:
            print(f"failed at tx {idx}", file=sys.stderr)
            return proc.returncode

        receipt = receipt_or_die(proc.stdout, idx)
        hashes.append(receipt["transactionHash"])
        print(f"tx {idx}/{len(transactions)} ok {receipt['transactionHash']}")

    post_balance = run(["cast", "balance", public_address, "--rpc-url", rpc])
    post_nonce = run(["cast", "nonce", public_address, "--rpc-url", rpc])
    if post_balance.returncode != 0 or post_nonce.returncode != 0:
        log(post_balance.stderr)
        log(post_nonce.stderr)
        return 1

    post_balance_str = post_balance.stdout.strip()
    post_nonce_str = post_nonce.stdout.strip()
    log(f"$ cast nonce $PUBLIC_ADDRESS --rpc-url $RPC_CH5_SUPERFLUID_V2\n{post_nonce_str}")
    log(f"$ cast balance $PUBLIC_ADDRESS --rpc-url $RPC_CH5_SUPERFLUID_V2\n{post_balance_str}")

    print(
        json.dumps(
            {
                "tx_hashes": hashes,
                "pre_balance_wei": pre_balance_str,
                "post_balance_wei": post_balance_str,
                "actual_delta_wei": str(int(post_balance_str) - int(pre_balance_str)),
                "post_nonce": post_nonce_str,
            },
            indent=2,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
