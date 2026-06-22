// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import "forge-std/console.sol";

interface IComptroller {
    function enterMarkets(address[] calldata cTokens) external returns (uint256[] memory);
    function exitMarket(address cToken) external returns (uint256);
    function getAssetsIn(address) external view returns (address[] memory);
}

interface ICErc20 {
    function mint(uint256 mintAmount) external returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function redeem(uint256 redeemTokens) external returns (uint256);
    function underlying() external view returns (address);
}

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

contract Pool72Test11 is Test {
    IComptroller constant COMPTROLLER = IComptroller(0xDcc615Ba569e60c7eD31B74686624fC1770bdD9A);

    // Other markets in Pool 72
    address constant MARKET_1 = 0x644375F7145c7F2B520058043b9C7A30Ab16f1C3;
    address constant MARKET_2 = 0x4b3d6aD21CB4c02c0f38a131AE2358C2813Af13f; // FEI
    address constant MARKET_3 = 0x72c234187Df4d0fB6734afB7463351a86d023590;
    address constant MARKET_4 = 0x65D9912a6BfbD9ad91C02F14B83Eb36E027c4799;

    function testExitMarketOtherMarkets() public {
        // Test exitMarket on FEI market (MARKET_2)
        address fei = ICErc20(MARKET_2).underlying();
        console.log("FEI underlying:", fei);

        address user = address(0xBEEF);

        // Get some FEI tokens
        deal(fei, user, 1000e18);

        vm.startPrank(user);
        IERC20(fei).approve(MARKET_2, type(uint256).max);

        uint256 mintResult = ICErc20(MARKET_2).mint(100e18);
        console.log("Mint FEI result:", mintResult);

        uint256 cTokens = ICErc20(MARKET_2).balanceOf(user);
        console.log("cTokens:", cTokens);

        // Enter market
        address[] memory m = new address[](1);
        m[0] = MARKET_2;
        uint256[] memory results = COMPTROLLER.enterMarkets(m);
        console.log("Enter result:", results[0]);

        // Check assets
        address[] memory assets = COMPTROLLER.getAssetsIn(user);
        console.log("Assets in:", assets.length);

        // Try exit
        try COMPTROLLER.exitMarket(MARKET_2) returns (uint256 exitCode) {
            console.log("Exit FEI result:", exitCode);
        } catch {
            console.log("Exit FEI REVERTED (assert)");
        }

        vm.stopPrank();
    }
}
