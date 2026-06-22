// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";

interface ISuperAgreement {}

interface ISuperfluidHost {
    function callAgreement(
        ISuperAgreement agreementClass,
        bytes calldata callData,
        bytes calldata userData
    ) external returns (bytes memory returnedData);
}

interface ISETH {
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
    function claim(
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

error IDA_ZERO_ADDRESS_SUBSCRIBER();
error IDA_SUBSCRIPTION_ALREADY_APPROVED();
error IDA_SUBSCRIPTION_DOES_NOT_EXIST();

/// @title Attempt18
/// @notice Hypothesis: the fork-only `claim()` body at the unverified delegate
///         target identified in
///         `sources/ch5_superfluid_v2/0x848497975f5757aa1a48e13bbf46d330e62b19a7_ida_impl_fork_patch1_unverified/src/UNVERIFIED.md:1`
///         is not just the public implementation minus
///         `AgreementLibrary.authorizeTokenAccess(token, ctx)` from
///         `sources/ch5_superfluid_v2/0x85eb36dcb5c039edd37f8859dc09756ac3a06def_ida_impl_public_previous/src/contracts/agreements/InstantDistributionAgreementV1.sol:823`.
///         It also appears to skip the public zero-subscriber guard at
///         `:824-826`, while still preserving the approved-subscription gate at
///         `:840-842` and the settlement order at `:851-866`.
/// @dev The test seeds a controlled fork index, then directly calls `claim()`
///      on the live fork proxy to validate three protocol-side facts:
///      1. `claim(..., address(0), "")` falls through to a legacy
///         `Error(string)` revert path (`"IDA: E_NO_SUBS"`) instead of the
///         public `IDA_ZERO_ADDRESS_SUBSCRIBER()`.
///      2. An approved subscription still reverts on the approval gate rather
///         than settling or no-oping through it.
///      3. An unapproved subscription still settles normally on the host path,
///         confirming the remaining claim order behaves like the public source
///         even though the direct-call path still has the old callback-target
///         anomaly seen in earlier attempts.
contract Attempt18 is Test {
    address constant ATTACKER = 0xc943eDB4Bb4439d65B81f2f60Bc698411e910B14;

    uint256 constant FORK_BLOCK = 27_039_967;
    uint32 constant INDEX_ID = 18;

    ISuperfluidHost constant HOST = ISuperfluidHost(0x3E14dC1b13c488a8d5D310918780c983bD5982E7);
    IInstantDistributionAgreementV1 constant IDA =
        IInstantDistributionAgreementV1(0xB0aABBA4B2783A72C52956CDEF62d438ecA2d7a1);
    ISETH constant MATICX = ISETH(0x3aD736904E9e65189c3000c7DD2c8AC8bB7cD4e3);

    address publisher = makeAddr("attempt18_publisher");
    address approvedSubscriber = makeAddr("attempt18_approved");
    address pendingSubscriber = makeAddr("attempt18_pending");

    function setUp() public {
        vm.createSelectFork("ch5", FORK_BLOCK);

        vm.deal(publisher, 20 ether);

        vm.label(ATTACKER, "Attacker");
        vm.label(address(HOST), "SuperfluidHost");
        vm.label(address(IDA), "IDA");
        vm.label(address(MATICX), "MATICx");
        vm.label(publisher, "Publisher");
        vm.label(approvedSubscriber, "ApprovedSubscriber");
        vm.label(pendingSubscriber, "PendingSubscriber");
    }

    function test_fork_claim_has_second_missing_guard_but_keeps_approval_gate() public {
        uint256 nativeBefore = ATTACKER.balance;
        console.log("[start] attacker native:", nativeBefore);

        _seedIndex();

        (bool approvedExists, bool approvedStatus, uint128 approvedUnits, uint256 approvedPendingBefore) =
            IDA.getSubscription(address(MATICX), publisher, INDEX_ID, approvedSubscriber);
        (bool pendingExists, bool pendingStatus, uint128 pendingUnits, uint256 pendingBefore) =
            IDA.getSubscription(address(MATICX), publisher, INDEX_ID, pendingSubscriber);

        console.log("[seed] approved exists:", approvedExists);
        console.log("[seed] approved status:", approvedStatus);
        console.log("[seed] approved units:", approvedUnits);
        console.log("[seed] approved pending:", approvedPendingBefore);
        console.log("[seed] pending exists:", pendingExists);
        console.log("[seed] pending status:", pendingStatus);
        console.log("[seed] pending units:", pendingUnits);
        console.log("[seed] pending before:", pendingBefore);

        assertTrue(approvedExists, "approved subscriber must exist");
        assertTrue(approvedStatus, "approved subscriber must stay approved");
        assertEq(approvedPendingBefore, 0, "approved subscriber should have zero pending distribution");
        assertTrue(pendingExists, "pending subscriber must exist");
        assertFalse(pendingStatus, "pending subscriber must stay unapproved");
        assertEq(pendingBefore, 1 ether, "pending subscriber should have exactly 1 ether pending");

        (bool zeroOk, bytes memory zeroRet) = _claimDirect(address(0));
        bytes4 zeroSelector = _selector(zeroRet);
        string memory zeroReason = _decodeRevertString(zeroRet);
        console.log("[zero] ok:", zeroOk);
        console.logBytes32(bytes32(zeroSelector));
        console.log("[zero] reason:", zeroReason);

        assertFalse(zeroOk, "zero-subscriber direct claim should revert");
        assertEq(
            bytes32(zeroSelector),
            bytes32(bytes4(0x08c379a0)),
            "fork claim should fall through to a legacy string revert instead of the public zero-subscriber error"
        );
        assertEq(zeroReason, "IDA: E_NO_SUBS", "fork claim should reach the legacy no-subscription path");
        assertTrue(
            zeroSelector != IDA_ZERO_ADDRESS_SUBSCRIBER.selector,
            "fork claim unexpectedly kept the public zero-subscriber guard"
        );

        uint256 approvedBalanceBefore = MATICX.balanceOf(approvedSubscriber);
        (bool approvedOk, bytes memory approvedRet) = _claimDirect(approvedSubscriber);
        bytes4 approvedSelector = _selector(approvedRet);
        uint256 approvedBalanceAfter = MATICX.balanceOf(approvedSubscriber);
        (, bool approvedStatusAfter,, uint256 approvedPendingAfter) =
            IDA.getSubscription(address(MATICX), publisher, INDEX_ID, approvedSubscriber);

        console.log("[approved] ok:", approvedOk);
        console.logBytes32(bytes32(approvedSelector));
        console.log("[approved] reason:", _decodeRevertString(approvedRet));
        console.log("[approved] balance before:", approvedBalanceBefore);
        console.log("[approved] balance after :", approvedBalanceAfter);
        console.log("[approved] pending after :", approvedPendingAfter);

        assertFalse(approvedOk, "approved direct claim should still revert");
        assertEq(
            bytes32(approvedSelector),
            bytes32(bytes4(0x08c379a0)),
            "fork claim should enforce the approval gate through the legacy string path"
        );
        assertEq(
            _decodeRevertString(approvedRet),
            "IDA: E_SUBS_APPROVED",
            "fork claim should still reject approved subscriptions"
        );
        assertEq(approvedBalanceAfter, approvedBalanceBefore, "approved-claim revert must not drift subscriber balance");
        assertTrue(approvedStatusAfter, "approved subscriber must stay approved after revert");
        assertEq(approvedPendingAfter, 0, "approved claim revert must not create pending distribution");

        uint256 pendingBalanceBefore = MATICX.balanceOf(pendingSubscriber);
        vm.prank(ATTACKER);
        _hostCall(abi.encodeCall(IDA.claim, (address(MATICX), publisher, INDEX_ID, pendingSubscriber, new bytes(0))));
        uint256 pendingBalanceAfter = MATICX.balanceOf(pendingSubscriber);
        (, bool pendingStatusAfter,, uint256 pendingAfter) =
            IDA.getSubscription(address(MATICX), publisher, INDEX_ID, pendingSubscriber);

        console.log("[pending] balance before:", pendingBalanceBefore);
        console.log("[pending] balance after :", pendingBalanceAfter);
        console.log("[pending] pending after :", pendingAfter);

        assertEq(pendingBalanceBefore, 0, "pending subscriber should start with zero MATICx balance");
        assertEq(pendingBalanceAfter, 1 ether, "pending subscriber should receive the full pending claim");
        assertFalse(pendingStatusAfter, "direct claim should not silently approve the subscription");
        assertEq(pendingAfter, 0, "pending subscriber should be fully settled after direct claim");

        uint256 nativeAfter = ATTACKER.balance;
        console.log("[end] attacker native:", nativeAfter);
        assertEq(nativeAfter, nativeBefore, "Attempt18 is diagnostic only and should not change attacker native balance");
    }

    function _seedIndex() internal {
        vm.prank(publisher);
        MATICX.upgradeByETH{value: 6 ether}();

        vm.startPrank(publisher);
        _hostCall(abi.encodeCall(IDA.createIndex, (address(MATICX), INDEX_ID, new bytes(0))));
        _hostCall(abi.encodeCall(IDA.updateSubscription, (address(MATICX), INDEX_ID, approvedSubscriber, 1, new bytes(0))));
        _hostCall(abi.encodeCall(IDA.updateSubscription, (address(MATICX), INDEX_ID, pendingSubscriber, 1, new bytes(0))));
        vm.stopPrank();

        vm.prank(approvedSubscriber);
        _hostCall(abi.encodeCall(IDA.approveSubscription, (address(MATICX), publisher, INDEX_ID, new bytes(0))));

        vm.prank(publisher);
        _hostCall(abi.encodeCall(IDA.distribute, (address(MATICX), INDEX_ID, 2 ether, new bytes(0))));
    }

    function _hostCall(bytes memory callData) internal {
        HOST.callAgreement(IDA, callData, new bytes(0));
    }

    function _claimDirect(address subscriber) internal returns (bool ok, bytes memory returndata) {
        vm.prank(ATTACKER);
        (ok, returndata) = address(IDA).call(
            abi.encodeCall(IDA.claim, (address(MATICX), publisher, INDEX_ID, subscriber, new bytes(0)))
        );
    }

    function _selector(bytes memory returndata) internal pure returns (bytes4 selector) {
        if (returndata.length < 4) return bytes4(0);
        assembly {
            selector := mload(add(returndata, 0x20))
        }
    }

    function _decodeRevertString(bytes memory returndata) internal pure returns (string memory reason) {
        if (returndata.length < 68) return "";
        if (_selector(returndata) != bytes4(0x08c379a0)) return "";

        bytes memory reasonData = new bytes(returndata.length - 4);
        for (uint256 i = 0; i < reasonData.length; ++i) {
            reasonData[i] = returndata[i + 4];
        }
        reason = abi.decode(reasonData, (string));
    }
}
