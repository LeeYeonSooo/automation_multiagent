// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";

interface IPriceOracle {
    function getUnderlyingPrice(address cToken) external view returns (uint256);
}

interface IComptroller {
    function oracle() external view returns (address);
    function getAllMarkets() external view returns (address[] memory);
    function markets(address) external view returns (bool, uint256);
    function admin() external view returns (address);
    function enterMarkets(address[] calldata) external returns (uint256[] memory);
    function getAccountLiquidity(address) external view returns (uint256, uint256, uint256);
    function _setPriceOracle(address newOracle) external returns (uint256);
    function _setCollateralFactor(address cToken, uint256 newCollateralFactorMantissa) external returns (uint256);
}

interface ICToken {
    function name() external view returns (string memory);
    function getCash() external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function totalBorrows() external view returns (uint256);
    function exchangeRateStored() external view returns (uint256);
    function underlying() external view returns (address);
    function mint(uint256) external returns (uint256);
    function borrow(uint256) external returns (uint256);
    function balanceOf(address) external view returns (uint256);
}

interface ICEther {
    function mint() external payable;
    function borrow(uint256) external returns (uint256);
    function getCash() external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
}

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function decimals() external view returns (uint8);
    function symbol() external view returns (string memory);
}

interface IWMATIC {
    function deposit() external payable;
    function withdraw(uint256) external;
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

interface IUniswapV2Router {
    function swapExactTokensForTokens(uint256, uint256, address[] calldata, address, uint256) external returns (uint256[] memory);
    function getAmountsOut(uint256, address[] calldata) external view returns (uint256[] memory);
}

interface IUniswapV2Pair {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves() external view returns (uint112, uint112, uint32);
}

interface IUniswapV2Factory {
    function getPair(address, address) external view returns (address);
}

contract OracleTraceTest is Test {
    // Hundred Finance
    address constant HF_COMPTROLLER = 0xEdBA32185BAF7fEf9A26ca567bC4A6cbe426e499;
    address constant HF_MATIC = 0xEbd7f3349AbA8bB15b897e03D6c1a4Ba95B55e31;
    address constant HF_USDC = 0x607312a5C671D0C511998171e634DE32156e69d0;
    address constant HF_DAI = 0xE4e43864ea18d5E5211352a4B810383460aB7fcC;
    address constant HF_USDT = 0x103f2CA2148B863942397dbc50a425cc4f4E9A27;
    address constant HF_FRAX = 0x2c7a9d9919f042C4C120199c69e126124d09BE7c;
    address constant HF_ETH = 0x243E33aa7f6787154a8E59d3C27a66db3F8818ee;

    // Tokens
    address constant WMATIC = 0x0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270;
    address constant USDC = 0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174;
    address constant DAI = 0x8f3Cf7ad23Cd3CaDbD9735AFf958023239c6A063;
    address constant WETH = 0x7ceB23fD6bC0adD59E62ac25578270cFf1b9f619;
    address constant USDT = 0xc2132D05D31c914a87C6611C10748AEb04B58e8F;

    // DEX
    address constant QUICKSWAP_FACTORY = 0x5757371414417b8C6CAad45bAeF941aBc7d3Ab32;
    address constant QUICKSWAP_ROUTER = 0xa5E0829CaCEd8fFDD4De3c43696c57F7D7A678ff;
    address constant SUSHISWAP_FACTORY = 0xc35DADB65012eC5796536bD9864eD8773aBc74C4;
    address constant SUSHISWAP_ROUTER = 0x1b02dA8Cb0d097eB8D57A175b88c7D8b47997506;

    function test_traceOracle() public view {
        IPriceOracle oracle = IPriceOracle(IComptroller(HF_COMPTROLLER).oracle());
        console.log("Oracle address:", address(oracle));

        // Get prices for all markets
        console.log("hMATIC price:", oracle.getUnderlyingPrice(HF_MATIC));
        console.log("hUSDC price:", oracle.getUnderlyingPrice(HF_USDC));
        console.log("hDAI price:", oracle.getUnderlyingPrice(HF_DAI));
        console.log("hETH price:", oracle.getUnderlyingPrice(HF_ETH));
    }

    function test_adminExploit() public {
        // Check if we can impersonate admin
        IComptroller comp = IComptroller(HF_COMPTROLLER);
        address admin = comp.admin();
        console.log("HF Admin:", admin);

        // Try to set a malicious oracle as admin
        vm.prank(admin);
        uint256 err = comp._setPriceOracle(address(this));
        console.log("setPriceOracle result:", err);

        // If we could set our own oracle, we could inflate our collateral value
    }

    function test_checkDEXLiquidity() public view {
        // Check QuickSwap WMATIC/USDC pair
        IUniswapV2Factory quickFactory = IUniswapV2Factory(QUICKSWAP_FACTORY);
        address pair = quickFactory.getPair(WMATIC, USDC);
        console.log("QuickSwap WMATIC/USDC pair:", pair);

        if (pair != address(0)) {
            (uint112 r0, uint112 r1,) = IUniswapV2Pair(pair).getReserves();
            address t0 = IUniswapV2Pair(pair).token0();
            console.log("Token0:", t0);
            console.log("Reserve0:", r0);
            console.log("Reserve1:", r1);
        }

        // Check SushiSwap
        address sushiPair = IUniswapV2Factory(SUSHISWAP_FACTORY).getPair(WMATIC, USDC);
        console.log("SushiSwap WMATIC/USDC pair:", sushiPair);
        if (sushiPair != address(0)) {
            (uint112 r0, uint112 r1,) = IUniswapV2Pair(sushiPair).getReserves();
            console.log("Reserve0:", r0);
            console.log("Reserve1:", r1);
        }
    }

    function test_fullBorrowStrategy() public {
        // Strategy: Supply 999K MATIC to Hundred Finance, borrow max of each stable
        uint256 supplyAmount = 500_000 ether; // 500K MATIC
        address attacker = makeAddr("attacker");
        vm.deal(attacker, supplyAmount);
        vm.startPrank(attacker);

        // Enter market
        address[] memory markets = new address[](1);
        markets[0] = HF_MATIC;
        IComptroller(HF_COMPTROLLER).enterMarkets(markets);

        // Mint hMATIC
        ICEther(HF_MATIC).mint{value: supplyAmount}();
        console.log("hMATIC minted:", ICEther(HF_MATIC).balanceOf(attacker));

        // Check liquidity
        (uint256 err, uint256 liq, uint256 sf) = IComptroller(HF_COMPTROLLER).getAccountLiquidity(attacker);
        console.log("Liquidity (USD, 18 dec):", liq);
        // liq is in USD with 18 decimals

        // Borrow USDC
        uint256 usdcCash = ICToken(HF_USDC).getCash();
        console.log("USDC cash available:", usdcCash);

        // Borrow up to liquidity limit (in USDC terms)
        // liq is in USD*1e18, USDC price is ~1e30
        // So USDC amount = liq / 1e12
        uint256 maxUSDCBorrow = liq / 1e12;
        if (maxUSDCBorrow > usdcCash) maxUSDCBorrow = usdcCash;
        console.log("Max USDC borrow:", maxUSDCBorrow);

        uint256 borrowResult = ICToken(HF_USDC).borrow(maxUSDCBorrow);
        console.log("Borrow USDC result:", borrowResult);
        console.log("USDC balance:", IERC20(USDC).balanceOf(attacker));

        // Check remaining liquidity
        (err, liq, sf) = IComptroller(HF_COMPTROLLER).getAccountLiquidity(attacker);
        console.log("Remaining liquidity:", liq);

        // Borrow DAI
        uint256 daiCash = ICToken(HF_DAI).getCash();
        // DAI price ~1e18, so DAI amount = liq
        uint256 maxDAIBorrow = liq;
        if (maxDAIBorrow > daiCash) maxDAIBorrow = daiCash;
        if (maxDAIBorrow > 0) {
            borrowResult = ICToken(HF_DAI).borrow(maxDAIBorrow);
            console.log("Borrow DAI result:", borrowResult);
            console.log("DAI balance:", IERC20(DAI).balanceOf(attacker));
        }

        // Total value borrowed
        console.log("=== Summary ===");
        console.log("MATIC supplied:", supplyAmount / 1e18, "MATIC");
        console.log("USDC borrowed:", IERC20(USDC).balanceOf(attacker));
        console.log("DAI borrowed:", IERC20(DAI).balanceOf(attacker) / 1e18);

        vm.stopPrank();
    }

    // Check if swapping borrowed stables to MATIC is profitable
    function test_swapCheck() public view {
        // Check how much MATIC we'd get for 1M USDC on QuickSwap
        address[] memory path = new address[](2);
        path[0] = USDC;
        path[1] = WMATIC;

        uint256[] memory amounts = IUniswapV2Router(QUICKSWAP_ROUTER).getAmountsOut(1_000_000 * 1e6, path);
        console.log("1M USDC -> WMATIC:", amounts[1] / 1e18);

        // Check MATIC -> USDC
        path[0] = WMATIC;
        path[1] = USDC;
        amounts = IUniswapV2Router(QUICKSWAP_ROUTER).getAmountsOut(500_000 ether, path);
        console.log("500K WMATIC -> USDC:", amounts[1]);
    }
}
