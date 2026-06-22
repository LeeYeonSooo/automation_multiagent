// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import {ContextUtils} from "reference/ContextUtils.sol";

interface ISuperAgreement {}

interface ISuperToken {}

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

    function getIndex(
        ISuperToken token,
        address publisher,
        uint32 indexId
    )
        external
        view
        returns (
            bool exist,
            uint128 indexValue,
            uint128 totalUnitsApproved,
            uint128 totalUnitsPending
        );
}

/// @title Attempt12
/// @notice Hypothesis: the forked IDA might still let us forge `createIndex()`
///         with a registered SuperApp as publisher via the v1 trailing-bytes
///         trick. This probe checks the exact fork behavior:
///         1. `createIndex()` succeeds when the Host sees the publisher directly.
///         2. A direct call still reverts `unauthorized host`.
///         3. A host-mediated trailing-bytes forge with `msgSender =
///            registeredSuperApp` reverts `invalid ctx`.
///
///         If step 3 fails with `invalid ctx`, then `createIndex()` is patched
///         on this fork and the "forge a SuperApp publisher first" branch is a
///         dead end.
contract Attempt12 is Test {
    address constant ATTACKER = 0xc943eDB4Bb4439d65B81f2f60Bc698411e910B14;
    address constant PUBLISHER_APP = 0x029cE4720F852520BBB95514B33a47c9864567a4;

    uint256 constant FORK_BLOCK = 27_039_967;
    uint32 constant ATTACKER_CONTROL_INDEX_ID = 55_120_001;
    uint32 constant APP_CONTROL_INDEX_ID = 55_120_002;
    uint32 constant FORGED_INDEX_ID = 55_120_003;
    uint32 constant DIRECT_FORGED_INDEX_ID = 55_120_004;

    ISuperfluidHost constant HOST = ISuperfluidHost(0x3E14dC1b13c488a8d5D310918780c983bD5982E7);
    IInstantDistributionAgreementV1 constant IDA =
        IInstantDistributionAgreementV1(0xB0aABBA4B2783A72C52956CDEF62d438ecA2d7a1);
    ISuperToken constant MATICX = ISuperToken(0x3aD736904E9e65189c3000c7DD2c8AC8bB7cD4e3);

    function setUp() public {
        vm.createSelectFork("ch5", FORK_BLOCK);
        vm.deal(ATTACKER, 10 ether);

        vm.label(ATTACKER, "Attacker");
        vm.label(PUBLISHER_APP, "PublisherApp");
        vm.label(address(HOST), "SuperfluidHost");
        vm.label(address(IDA), "IDA");
        vm.label(address(MATICX), "MATICx");
    }

    function test_createIndex_registered_app_publisher_is_ctx_gated() public {
        uint256 nativeBefore = ATTACKER.balance;
        console.log("[start] attacker native:", nativeBefore);
        console.log("[preflight] chain id:", block.chainid);
        console.log("[preflight] fork block:", block.number);

        (bool isSuperApp, bool isJailed, uint256 noopMask) = HOST.getAppManifest(PUBLISHER_APP);
        console.log("[publisher app] isApp:", HOST.isApp(PUBLISHER_APP));
        console.log("[publisher app] manifest isSuperApp:", isSuperApp);
        console.log("[publisher app] isJailed:", isJailed);
        console.log("[publisher app] noopMask:", noopMask);

        assertTrue(HOST.isApp(PUBLISHER_APP), "publisher app should remain registered");
        assertTrue(isSuperApp, "publisher app manifest should report a SuperApp");
        assertFalse(isJailed, "publisher app should be live for this probe");

        vm.prank(ATTACKER);
        _callAgreementOrRevert(
            abi.encodeCall(IDA.createIndex, (MATICX, ATTACKER_CONTROL_INDEX_ID, new bytes(0))),
            "attacker plain host createIndex"
        );
        (bool attackerIndexExists,,,) = IDA.getIndex(MATICX, ATTACKER, ATTACKER_CONTROL_INDEX_ID);
        console.log("[control attacker] index exists:", attackerIndexExists);
        assertTrue(attackerIndexExists, "plain host createIndex should work for the attacker");

        vm.prank(PUBLISHER_APP);
        _callAgreementOrRevert(
            abi.encodeCall(IDA.createIndex, (MATICX, APP_CONTROL_INDEX_ID, new bytes(0))),
            "publisher app plain host createIndex"
        );
        (bool appIndexExists,,,) = IDA.getIndex(MATICX, PUBLISHER_APP, APP_CONTROL_INDEX_ID);
        console.log("[control publisher app] index exists:", appIndexExists);
        assertTrue(appIndexExists, "plain host createIndex should work when the publisher really is the app");

        bytes memory forgedCtx = _buildForgedCreateIndexContext(PUBLISHER_APP);

        vm.prank(ATTACKER);
        (bool directOk, bytes memory directRet) =
            address(IDA).call(abi.encodeCall(IDA.createIndex, (MATICX, DIRECT_FORGED_INDEX_ID, forgedCtx)));
        string memory directReason = _decodeRevert(directRet);
        console.log("[direct forged] ok:", directOk);
        console.log("[direct forged] revert:", directReason);
        assertFalse(directOk, "direct forged createIndex should fail");
        assertEq(directReason, "unauthorized host", "direct createIndex should still hit host gating");

        vm.prank(ATTACKER);
        (bool trailingOk, bytes memory trailingRet) = _callAgreementWithTrailingBytes(
            abi.encodeCall(IDA.createIndex, (MATICX, FORGED_INDEX_ID, forgedCtx))
        );
        string memory trailingReason = _decodeRevert(trailingRet);
        console.log("[host trailing forged app publisher] ok:", trailingOk);
        console.log("[host trailing forged app publisher] revert:", trailingReason);

        (bool forgedAppIndexExists,,,) = IDA.getIndex(MATICX, PUBLISHER_APP, FORGED_INDEX_ID);
        (bool forgedAttackerIndexExists,,,) = IDA.getIndex(MATICX, ATTACKER, FORGED_INDEX_ID);
        console.log("[forged result] app index exists:", forgedAppIndexExists);
        console.log("[forged result] attacker index exists:", forgedAttackerIndexExists);

        assertFalse(trailingOk, "host trailing forged createIndex should fail on this fork");
        assertEq(trailingReason, "invalid ctx", "createIndex should still validate ctx on the fork");
        assertFalse(forgedAppIndexExists, "forged publisher app index should not be created");
        assertFalse(forgedAttackerIndexExists, "failed forged path should not create an attacker index either");

        uint256 nativeAfter = ATTACKER.balance;
        console.log("[end] attacker native:", nativeAfter);
        console.logInt(int256(nativeAfter) - int256(nativeBefore));
    }

    function _buildForgedCreateIndexContext(address forgedPublisher) internal view returns (bytes memory) {
        ContextUtils.Context memory context = ContextUtils.buildContext(
            forgedPublisher,
            IDA.createIndex.selector,
            hex"c0ffee"
        );
        return ContextUtils.encodeContext(context);
    }

    function _callAgreementOrRevert(bytes memory inner, string memory step) internal {
        (bool ok, bytes memory ret) = _callAgreementRaw(inner);
        require(ok, string.concat(step, ": ", _decodeRevert(ret)));
    }

    function _callAgreementRaw(bytes memory inner) internal returns (bool ok, bytes memory ret) {
        return address(HOST).call(abi.encodeCall(HOST.callAgreement, (IDA, inner, new bytes(0))));
    }

    function _callAgreementWithTrailingBytes(bytes memory inner) internal returns (bool ok, bytes memory ret) {
        bytes memory outer = abi.encodePacked(inner, abi.encode(new bytes(0)));
        return address(HOST).call(abi.encodeCall(HOST.callAgreement, (IDA, outer, new bytes(0))));
    }

    function _decodeRevert(bytes memory revertData) internal pure returns (string memory) {
        if (revertData.length < 4) {
            if (revertData.length == 0) return "silent revert";
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
