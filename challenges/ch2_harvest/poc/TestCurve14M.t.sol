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

contract TestCurve14M is Test {
    function test14MSwap() public {
        address USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
        address USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
        address CURVE = 0x45F783CCE6B7FF23B2ab2D70e416cdb7D6055f51;
        
        deal(USDC, address(this), 14_000_000e6);
        IERC20(USDC).approve(CURVE, type(uint256).max);
        
        uint256 before = IERC20(USDT).balanceOf(address(this));
        ICurveYPool(CURVE).exchange_underlying(1, 2, 14_000_000e6, 0);
        uint256 after_ = IERC20(USDT).balanceOf(address(this));
        emit log_named_uint("USDT received from 14M USDC", after_ - before);
    }
    
    function testRoundTrip14M() public {
        address USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
        address USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
        address CURVE = 0x45F783CCE6B7FF23B2ab2D70e416cdb7D6055f51;
        
        deal(USDC, address(this), 14_000_000e6);
        deal(USDT, address(this), 14_000_000e6);
        IERC20(USDC).approve(CURVE, type(uint256).max);
        // Safe USDT approve
        (bool s,) = USDT.call(abi.encodeWithSignature("approve(address,uint256)", CURVE, type(uint256).max));
        require(s);
        
        // Pump: USDC → USDT
        ICurveYPool(CURVE).exchange_underlying(1, 2, 14_000_000e6, 0);
        emit log_named_uint("After pump, USDT bal", IERC20(USDT).balanceOf(address(this)));
        
        // Dump: USDT → USDC (14M)
        ICurveYPool(CURVE).exchange_underlying(2, 1, 14_000_000e6, 0);
        emit log_named_uint("After dump, USDC bal", IERC20(USDC).balanceOf(address(this)));
    }
}
