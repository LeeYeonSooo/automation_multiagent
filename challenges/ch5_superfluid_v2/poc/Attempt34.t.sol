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
}

interface IMATICxLike {
    function upgradeByETH() external payable;
    function balanceOf(address account) external view returns (uint256);
}

interface IInstantDistributionAgreementV1 is ISuperAgreement {
    function createIndex(address token, uint32 indexId, bytes calldata ctx) external returns (bytes memory newCtx);

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

    function distribute(
        address token,
        uint32 indexId,
        uint256 amount,
        bytes calldata ctx
    ) external returns (bytes memory newCtx);

    function deleteSubscription(
        address token,
        address publisher,
        uint32 indexId,
        address subscriber,
        bytes calldata ctx
    ) external returns (bytes memory newCtx);

    function getSubscription(
        address token,
        address publisher,
        uint32 indexId,
        address subscriber
    ) external view returns (bool exist, bool approved, uint128 units, uint256 pendingDistribution);
}

error IDA_OPERATION_NOT_ALLOWED();

/// @title Attempt34
/// @notice Validates the ch5 deleteSubscription branch directly on the fork:
///         1. direct IDA proxy calls stay host-gated,
///         2. host-trailing forged ctx fails at `invalid ctx` before any
///            sender-specific delete logic, and
///         3. deleteSubscription settles pending value only for unapproved
///            subscriptions; once a subscription is approved, delete zeroes the
///            units without any extra payout.
/// @dev The public Superfluid source snapshots stored under `sources/` place
///      `AgreementLibrary.authorizeTokenAccess(token, ctx)` at the top of
///      `deleteSubscription()`. This PoC checks that the live fork still
///      behaves in that exact order.
contract Attempt34 is Test {
    uint256 internal constant FORK_BLOCK = 27_039_967;

    address internal constant ATTACKER = 0xc943eDB4Bb4439d65B81f2f60Bc698411e910B14;
    address internal constant HOST_ADDR = 0x3E14dC1b13c488a8d5D310918780c983bD5982E7;
    address internal constant IDA_ADDR = 0xB0aABBA4B2783A72C52956CDEF62d438ecA2d7a1;
    address internal constant MATICX_ADDR = 0x3aD736904E9e65189c3000c7DD2c8AC8bB7cD4e3;

    uint32 internal constant INDEX_DIRECT_PUBLISHER = 34_001;
    uint32 internal constant INDEX_DIRECT_SUBSCRIBER = 34_002;
    uint32 internal constant INDEX_PLAIN_PUBLISHER = 34_003;
    uint32 internal constant INDEX_PLAIN_SUBSCRIBER = 34_004;
    uint32 internal constant INDEX_TRAILING_PUBLISHER = 34_005;
    uint32 internal constant INDEX_TRAILING_SUBSCRIBER = 34_006;
    uint32 internal constant INDEX_SETTLE_UNAPPROVED = 34_007;
    uint32 internal constant INDEX_SETTLE_LATE_APPROVED = 34_008;

    uint128 internal constant UNITS = 1;
    uint256 internal constant DISTRIBUTION_AMOUNT = 2 ether;
    uint256 internal constant SEED_WRAP_AMOUNT = 12 ether;

    ISuperfluidHost internal constant HOST = ISuperfluidHost(HOST_ADDR);
    IInstantDistributionAgreementV1 internal constant IDA = IInstantDistributionAgreementV1(IDA_ADDR);
    IMATICxLike internal constant MATICX = IMATICxLike(MATICX_ADDR);

    address internal publisher;
    address internal subscriber;
    address internal altSubscriber;

    function setUp() public {
        vm.createSelectFork(vm.envString("RPC_CH5_SUPERFLUID_V2"), FORK_BLOCK);

        publisher = makeAddr("attempt34_publisher");
        subscriber = makeAddr("attempt34_subscriber");
        altSubscriber = makeAddr("attempt34_alt_subscriber");

        vm.label(ATTACKER, "Attacker");
        vm.label(HOST_ADDR, "SuperfluidHost");
        vm.label(IDA_ADDR, "IDA");
        vm.label(MATICX_ADDR, "MATICx");
        vm.label(publisher, "Attempt34Publisher");
        vm.label(subscriber, "Attempt34Subscriber");
        vm.label(altSubscriber, "Attempt34AltSubscriber");
    }

    function test_deleteSubscription_auth_matrix_matches_authorizeTokenAccess_then_sender_logic() public {
        _seedSubscription(INDEX_DIRECT_PUBLISHER, subscriber);
        _seedSubscription(INDEX_DIRECT_SUBSCRIBER, subscriber);
        _seedSubscription(INDEX_PLAIN_PUBLISHER, subscriber);
        _seedSubscription(INDEX_PLAIN_SUBSCRIBER, subscriber);
        _seedSubscription(INDEX_TRAILING_PUBLISHER, subscriber);
        _seedSubscription(INDEX_TRAILING_SUBSCRIBER, subscriber);

        bytes memory forgedPublisherCtx = _buildContext(publisher, IDA.deleteSubscription.selector);
        bytes memory forgedSubscriberCtx = _buildContext(subscriber, IDA.deleteSubscription.selector);

        vm.prank(ATTACKER);
        (bool directPublisherOk, bytes memory directPublisherRet) = address(IDA).call(
            abi.encodeCall(
                IDA.deleteSubscription,
                (MATICX_ADDR, publisher, INDEX_DIRECT_PUBLISHER, subscriber, forgedPublisherCtx)
            )
        );

        vm.prank(ATTACKER);
        (bool directSubscriberOk, bytes memory directSubscriberRet) = address(IDA).call(
            abi.encodeCall(
                IDA.deleteSubscription,
                (MATICX_ADDR, publisher, INDEX_DIRECT_SUBSCRIBER, subscriber, forgedSubscriberCtx)
            )
        );

        vm.prank(publisher);
        (bool plainPublisherOk, bytes memory plainPublisherRet) = _callAgreementRaw(
            abi.encodeCall(IDA.deleteSubscription, (MATICX_ADDR, publisher, INDEX_PLAIN_PUBLISHER, subscriber, new bytes(0)))
        );

        vm.prank(subscriber);
        (bool plainSubscriberOk, bytes memory plainSubscriberRet) = _callAgreementRaw(
            abi.encodeCall(
                IDA.deleteSubscription, (MATICX_ADDR, publisher, INDEX_PLAIN_SUBSCRIBER, subscriber, new bytes(0))
            )
        );

        vm.prank(ATTACKER);
        (bool trailingPublisherOk, bytes memory trailingPublisherRet) = _callAgreementWithTrailingBytes(
            abi.encodeCall(
                IDA.deleteSubscription,
                (MATICX_ADDR, publisher, INDEX_TRAILING_PUBLISHER, subscriber, forgedPublisherCtx)
            )
        );

        vm.prank(ATTACKER);
        (bool trailingSubscriberOk, bytes memory trailingSubscriberRet) = _callAgreementWithTrailingBytes(
            abi.encodeCall(
                IDA.deleteSubscription,
                (MATICX_ADDR, publisher, INDEX_TRAILING_SUBSCRIBER, subscriber, forgedSubscriberCtx)
            )
        );

        console.log("[direct forged publisher] ok:", directPublisherOk);
        console.log("[direct forged publisher] revert:", _decodeRevert(directPublisherRet));
        console.log("[direct forged subscriber] ok:", directSubscriberOk);
        console.log("[direct forged subscriber] revert:", _decodeRevert(directSubscriberRet));
        console.log("[plain host publisher] ok:", plainPublisherOk);
        console.log("[plain host publisher] return bytes:", plainPublisherRet.length);
        console.log("[plain host subscriber] ok:", plainSubscriberOk);
        console.log("[plain host subscriber] revert:", _decodeRevert(plainSubscriberRet));
        console.log("[trailing forged publisher] ok:", trailingPublisherOk);
        console.log("[trailing forged publisher] revert:", _decodeRevert(trailingPublisherRet));
        console.log("[trailing forged subscriber] ok:", trailingSubscriberOk);
        console.log("[trailing forged subscriber] revert:", _decodeRevert(trailingSubscriberRet));

        assertFalse(directPublisherOk, "direct delete with forged publisher ctx unexpectedly succeeded");
        assertFalse(directSubscriberOk, "direct delete with forged subscriber ctx unexpectedly succeeded");
        assertEq(_decodeRevert(directPublisherRet), "unauthorized host", "direct publisher-forged delete changed revert");
        assertEq(_decodeRevert(directSubscriberRet), "unauthorized host", "direct subscriber-forged delete changed revert");

        assertTrue(plainPublisherOk, "real publisher host delete should succeed");

        assertFalse(plainSubscriberOk, "real subscriber host delete unexpectedly succeeded on fork");
        assertEq(
            _decodeRevert(plainSubscriberRet),
            "IDA: E_NOT_ALLOWED",
            "subscriber delete should fail on sender-authorization, not ctx validation"
        );

        assertFalse(trailingPublisherOk, "publisher-forged trailing delete unexpectedly succeeded");
        assertFalse(trailingSubscriberOk, "subscriber-forged trailing delete unexpectedly succeeded");
        assertEq(_decodeRevert(trailingPublisherRet), "invalid ctx", "publisher-forged trailing delete changed revert");
        assertEq(_decodeRevert(trailingSubscriberRet), "invalid ctx", "subscriber-forged trailing delete changed revert");

        (bool plainPublisherExist,, uint128 plainPublisherUnits, uint256 plainPublisherPending) =
            IDA.getSubscription(MATICX_ADDR, publisher, INDEX_PLAIN_PUBLISHER, subscriber);
        (bool plainSubscriberExist,, uint128 plainSubscriberUnits, uint256 plainSubscriberPending) =
            IDA.getSubscription(MATICX_ADDR, publisher, INDEX_PLAIN_SUBSCRIBER, subscriber);
        (bool trailingPublisherExist,, uint128 trailingPublisherUnits, uint256 trailingPublisherPending) =
            IDA.getSubscription(MATICX_ADDR, publisher, INDEX_TRAILING_PUBLISHER, subscriber);
        (bool trailingSubscriberExist,, uint128 trailingSubscriberUnits, uint256 trailingSubscriberPending) =
            IDA.getSubscription(MATICX_ADDR, publisher, INDEX_TRAILING_SUBSCRIBER, subscriber);

        console.log("[post plain publisher] exist:", plainPublisherExist);
        console.log("[post plain publisher] units:", uint256(plainPublisherUnits));
        console.log("[post plain publisher] pending:", plainPublisherPending);
        console.log("[post plain subscriber] exist:", plainSubscriberExist);
        console.log("[post plain subscriber] units:", uint256(plainSubscriberUnits));
        console.log("[post plain subscriber] pending:", plainSubscriberPending);
        console.log("[post trailing publisher] exist:", trailingPublisherExist);
        console.log("[post trailing publisher] units:", uint256(trailingPublisherUnits));
        console.log("[post trailing publisher] pending:", trailingPublisherPending);
        console.log("[post trailing subscriber] exist:", trailingSubscriberExist);
        console.log("[post trailing subscriber] units:", uint256(trailingSubscriberUnits));
        console.log("[post trailing subscriber] pending:", trailingSubscriberPending);

        assertFalse(plainPublisherExist, "publisher delete should terminate the subscription");
        assertTrue(plainSubscriberExist, "subscriber-side revert must preserve the subscription");
        assertEq(plainSubscriberUnits, UNITS, "subscriber-side revert must preserve units");
        assertTrue(trailingPublisherExist, "invalid ctx must preserve publisher-forged subscription");
        assertTrue(trailingSubscriberExist, "invalid ctx must preserve subscriber-forged subscription");
    }

    function test_deleteSubscription_unapproved_settles_pending_to_subscriber() public {
        _seedSubscription(INDEX_SETTLE_UNAPPROVED, subscriber);
        _distribute(INDEX_SETTLE_UNAPPROVED, DISTRIBUTION_AMOUNT);

        (bool existBefore, bool approvedBefore, uint128 unitsBefore, uint256 pendingBefore) =
            IDA.getSubscription(MATICX_ADDR, publisher, INDEX_SETTLE_UNAPPROVED, subscriber);
        uint256 subscriberBalanceBefore = MATICX.balanceOf(subscriber);

        console.log("[unapproved before] exist:", existBefore);
        console.log("[unapproved before] approved:", approvedBefore);
        console.log("[unapproved before] units:", uint256(unitsBefore));
        console.log("[unapproved before] pending:", pendingBefore);
        console.log("[unapproved before] subscriber balance:", subscriberBalanceBefore);

        assertTrue(existBefore, "unapproved subscription missing before delete");
        assertFalse(approvedBefore, "unapproved control unexpectedly approved");
        assertEq(unitsBefore, UNITS, "unapproved control units changed");
        assertEq(pendingBefore, DISTRIBUTION_AMOUNT, "unapproved control pending changed");
        assertEq(subscriberBalanceBefore, 0, "unapproved control subscriber should start at zero balance");

        vm.prank(publisher);
        HOST.callAgreement(
            IDA,
            abi.encodeCall(
                IDA.deleteSubscription,
                (MATICX_ADDR, publisher, INDEX_SETTLE_UNAPPROVED, subscriber, new bytes(0))
            ),
            new bytes(0)
        );

        (bool existAfter, bool approvedAfter, uint128 unitsAfter, uint256 pendingAfter) =
            IDA.getSubscription(MATICX_ADDR, publisher, INDEX_SETTLE_UNAPPROVED, subscriber);
        uint256 subscriberBalanceAfter = MATICX.balanceOf(subscriber);

        console.log("[unapproved after] exist:", existAfter);
        console.log("[unapproved after] approved:", approvedAfter);
        console.log("[unapproved after] units:", uint256(unitsAfter));
        console.log("[unapproved after] pending:", pendingAfter);
        console.log("[unapproved after] subscriber balance:", subscriberBalanceAfter);

        assertFalse(existAfter, "delete should terminate the unapproved subscription");
        assertFalse(approvedAfter, "terminated unapproved subscription must not stay approved");
        assertEq(unitsAfter, 0, "terminated unapproved subscription must zero units");
        assertEq(pendingAfter, 0, "terminated unapproved subscription must clear pending");
        assertEq(
            subscriberBalanceAfter - subscriberBalanceBefore,
            pendingBefore,
            "deleteSubscription should settle the pending unapproved amount to the subscriber"
        );
    }

    function test_deleteSubscription_late_approved_subscription_has_no_extra_payout() public {
        _seedSubscription(INDEX_SETTLE_LATE_APPROVED, altSubscriber);
        _distribute(INDEX_SETTLE_LATE_APPROVED, DISTRIBUTION_AMOUNT);

        (, bool approvedBeforeApprove,, uint256 pendingBeforeApprove) =
            IDA.getSubscription(MATICX_ADDR, publisher, INDEX_SETTLE_LATE_APPROVED, altSubscriber);
        uint256 balanceBeforeApprove = MATICX.balanceOf(altSubscriber);

        console.log("[late approve pre-approve] approved:", approvedBeforeApprove);
        console.log("[late approve pre-approve] pending:", pendingBeforeApprove);
        console.log("[late approve pre-approve] subscriber balance:", balanceBeforeApprove);

        assertFalse(approvedBeforeApprove, "late-approve control must start unapproved");
        assertEq(pendingBeforeApprove, DISTRIBUTION_AMOUNT, "late-approve control pending changed");
        assertEq(balanceBeforeApprove, 0, "late-approve control subscriber should start at zero balance");

        vm.prank(altSubscriber);
        HOST.callAgreement(
            IDA,
            abi.encodeCall(
                IDA.approveSubscription, (MATICX_ADDR, publisher, INDEX_SETTLE_LATE_APPROVED, new bytes(0))
            ),
            new bytes(0)
        );

        (bool existAfterApprove, bool approvedAfterApprove, uint128 unitsAfterApprove, uint256 pendingAfterApprove) =
            IDA.getSubscription(MATICX_ADDR, publisher, INDEX_SETTLE_LATE_APPROVED, altSubscriber);
        uint256 balanceAfterApprove = MATICX.balanceOf(altSubscriber);

        console.log("[late approve post-approve] exist:", existAfterApprove);
        console.log("[late approve post-approve] approved:", approvedAfterApprove);
        console.log("[late approve post-approve] units:", uint256(unitsAfterApprove));
        console.log("[late approve post-approve] pending:", pendingAfterApprove);
        console.log("[late approve post-approve] subscriber balance:", balanceAfterApprove);

        assertTrue(existAfterApprove, "subscription should still exist immediately after approve");
        assertTrue(approvedAfterApprove, "subscription should become approved after approve");
        assertEq(unitsAfterApprove, UNITS, "approve should preserve units");
        assertEq(pendingAfterApprove, 0, "approve should materialize the historic pending amount");
        assertEq(
            balanceAfterApprove - balanceBeforeApprove,
            pendingBeforeApprove,
            "approve should pay the pre-existing pending amount exactly once"
        );

        vm.prank(publisher);
        HOST.callAgreement(
            IDA,
            abi.encodeCall(
                IDA.deleteSubscription,
                (MATICX_ADDR, publisher, INDEX_SETTLE_LATE_APPROVED, altSubscriber, new bytes(0))
            ),
            new bytes(0)
        );

        (bool existAfterDelete, bool approvedAfterDelete, uint128 unitsAfterDelete, uint256 pendingAfterDelete) =
            IDA.getSubscription(MATICX_ADDR, publisher, INDEX_SETTLE_LATE_APPROVED, altSubscriber);
        uint256 balanceAfterDelete = MATICX.balanceOf(altSubscriber);

        console.log("[late approve post-delete] exist:", existAfterDelete);
        console.log("[late approve post-delete] approved:", approvedAfterDelete);
        console.log("[late approve post-delete] units:", uint256(unitsAfterDelete));
        console.log("[late approve post-delete] pending:", pendingAfterDelete);
        console.log("[late approve post-delete] subscriber balance:", balanceAfterDelete);

        assertFalse(existAfterDelete, "delete should terminate the approved subscription");
        assertFalse(approvedAfterDelete, "terminated approved subscription must not stay approved");
        assertEq(unitsAfterDelete, 0, "delete should zero units");
        assertEq(pendingAfterDelete, 0, "delete should not recreate pending after approval");
        assertEq(
            balanceAfterDelete - balanceAfterApprove,
            0,
            "approved subscription delete should not pay any additional amount"
        );
    }

    function _seedSubscription(uint32 indexId, address targetSubscriber) internal {
        vm.deal(publisher, SEED_WRAP_AMOUNT);

        vm.prank(publisher);
        MATICX.upgradeByETH{value: SEED_WRAP_AMOUNT}();

        vm.startPrank(publisher);
        HOST.callAgreement(IDA, abi.encodeCall(IDA.createIndex, (MATICX_ADDR, indexId, new bytes(0))), new bytes(0));
        HOST.callAgreement(
            IDA,
            abi.encodeCall(IDA.updateSubscription, (MATICX_ADDR, indexId, targetSubscriber, UNITS, new bytes(0))),
            new bytes(0)
        );
        vm.stopPrank();
    }

    function _distribute(uint32 indexId, uint256 amount) internal {
        vm.prank(publisher);
        HOST.callAgreement(
            IDA,
            abi.encodeCall(IDA.distribute, (MATICX_ADDR, indexId, amount, new bytes(0))),
            new bytes(0)
        );
    }

    function _buildContext(address forgedMsgSender, bytes4 selector) internal view returns (bytes memory) {
        ContextUtils.Context memory context =
            ContextUtils.buildContext(forgedMsgSender, selector, abi.encodePacked("attempt34:", selector));
        return ContextUtils.encodeContext(context);
    }

    function _callAgreementRaw(bytes memory inner) internal returns (bool ok, bytes memory ret) {
        return address(HOST).call(abi.encodeCall(HOST.callAgreement, (IDA, inner, new bytes(0))));
    }

    function _callAgreementWithTrailingBytes(bytes memory inner) internal returns (bool ok, bytes memory ret) {
        bytes memory outer = abi.encodePacked(inner, abi.encode(new bytes(0)));
        return address(HOST).call(abi.encodeCall(HOST.callAgreement, (IDA, outer, new bytes(0))));
    }

    function _decodeRevert(bytes memory data) internal pure returns (string memory) {
        if (data.length == 0) return "<empty>";

        bytes4 sel = _selector(data);
        if (sel == 0x08c379a0) {
            bytes memory reasonData = new bytes(data.length - 4);
            for (uint256 i = 4; i < data.length; ++i) {
                reasonData[i - 4] = data[i];
            }
            return abi.decode(reasonData, (string));
        }

        if (sel == 0x4e487b71) return "<panic>";
        if (sel == IDA_OPERATION_NOT_ALLOWED.selector) return "IDA_OPERATION_NOT_ALLOWED";
        return "<custom error>";
    }

    function _selector(bytes memory data) internal pure returns (bytes4 sel) {
        if (data.length < 4) return bytes4(0);
        assembly {
            sel := mload(add(data, 0x20))
        }
    }
}
