// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface ICurveYPool {
    function exchange_underlying(int128 i, int128 j, uint256 dx, uint256 minDy) external;
}

interface IHVault {
    function deposit(uint256 amount) external;
    function withdraw(uint256 shares) external;
    function balanceOf(address) external view returns (uint256);
    function getPricePerFullShare() external view returns (uint256);
    function underlyingBalanceWithInvestment() external view returns (uint256);
    function strategy() external view returns (address);
}

interface IStrategy {
    function depositArbCheck() external view returns (bool);
}

interface IUniV2Pair {
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
    function token0() external view returns (address);
    function token1() external view returns (address);
}

contract DebugFUSDC is Test {
    address constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant CURVE = 0x45F783CCE6B7FF23B2ab2D70e416cdb7D6055f51;
    address constant FUSDC = 0xf0358e8c3CD5Fa238a29301d0bEa3D63A17bEdBE;
    address constant UNI_DAI_WETH = 0xA478c2975Ab1Ea89e8196811F51A7B7Ade33eB11;

    function testDebugCurveSwap() public {
        // Deal ourselves some DAI
        deal(DAI, address(this), 10_000_000e18);

        uint256 daiBal = IERC20(DAI).balanceOf(address(this));
        console.log("DAI balance:", daiBal);

        // Approve Curve
        IERC20(DAI).approve(CURVE, type(uint256).max);
        IERC20(USDC).approve(CURVE, type(uint256).max);
        IERC20(USDC).approve(FUSDC, type(uint256).max);

        // Try swap DAI -> USDC on Curve
        uint256 usdcBefore = IERC20(USDC).balanceOf(address(this));
        console.log("USDC before swap:", usdcBefore);

        console.log("Swapping 1M DAI -> USDC via Curve exchange_underlying...");
        ICurveYPool(CURVE).exchange_underlying(0, 1, 1_000_000e18, 0);

        uint256 usdcAfter = IERC20(USDC).balanceOf(address(this));
        console.log("USDC after swap:", usdcAfter);
        console.log("USDC received:", usdcAfter - usdcBefore);
    }

    function testDebugFUSDCDeposit() public {
        // Deal ourselves some USDC
        deal(USDC, address(this), 1_000_000e6);

        IERC20(USDC).approve(FUSDC, type(uint256).max);

        // Check arb check
        address strategy = IHVault(FUSDC).strategy();
        bool arbOk = IStrategy(strategy).depositArbCheck();
        console.log("depositArbCheck:", arbOk);

        uint256 ppfs = IHVault(FUSDC).getPricePerFullShare();
        console.log("pricePerFullShare:", ppfs);

        uint256 totalBal = IHVault(FUSDC).underlyingBalanceWithInvestment();
        console.log("underlyingBalanceWithInvestment:", totalBal);

        // Try deposit
        console.log("Depositing 1000 USDC...");
        IHVault(FUSDC).deposit(1000e6);

        uint256 shares = IHVault(FUSDC).balanceOf(address(this));
        console.log("Shares received:", shares);
    }

    function testDebugFullFlow() public {
        // Deal ourselves DAI and USDC to simulate flash loans
        deal(DAI, address(this), 10_000_000e18);
        deal(USDC, address(this), 50_000_000e6);

        IERC20(DAI).approve(CURVE, type(uint256).max);
        IERC20(USDC).approve(CURVE, type(uint256).max);
        IERC20(USDC).approve(FUSDC, type(uint256).max);

        uint256 usdcStart = IERC20(USDC).balanceOf(address(this));
        uint256 daiStart = IERC20(DAI).balanceOf(address(this));

        // PUMP: swap DAI -> USDC (removes USDC from Curve pool)
        console.log("=== PUMP: 10M DAI -> USDC ===");
        uint256 usdcBefore = IERC20(USDC).balanceOf(address(this));
        ICurveYPool(CURVE).exchange_underlying(0, 1, 10_000_000e18, 0);
        uint256 pumpedUSDC = IERC20(USDC).balanceOf(address(this)) - usdcBefore;
        console.log("Pumped USDC:", pumpedUSDC);

        // DEPOSIT pumped USDC
        console.log("=== DEPOSIT ===");
        address strategy = IHVault(FUSDC).strategy();
        bool arbOk = IStrategy(strategy).depositArbCheck();
        console.log("depositArbCheck after pump:", arbOk);

        IHVault(FUSDC).deposit(pumpedUSDC);
        uint256 shares = IHVault(FUSDC).balanceOf(address(this));
        console.log("Shares:", shares);

        // DUMP: swap USDC -> DAI (restores pool)
        console.log("=== DUMP: 10M USDC -> DAI ===");
        ICurveYPool(CURVE).exchange_underlying(1, 0, 10_000_000e6, 0);

        // WITHDRAW
        console.log("=== WITHDRAW ===");
        IHVault(FUSDC).withdraw(shares);

        uint256 usdcEnd = IERC20(USDC).balanceOf(address(this));
        uint256 daiEnd = IERC20(DAI).balanceOf(address(this));

        console.log("USDC profit:", int256(usdcEnd) - int256(usdcStart));
        console.log("DAI profit:", int256(daiEnd) - int256(daiStart));
    }
}
