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

    function getSubscription(
        ISuperToken token,
        address publisher,
        uint32 indexId,
        address subscriber
    ) external view returns (bool exist, bool approved, uint128 units, uint256 pendingDistribution);
}

contract CtxSink {
    receive() external payable {}
}

/// @title Attempt6
/// @notice Hypothesis: top-level `HOST.callAgreement(IDA.claim)` does not
///         settle, mint, or credit from the agreement's returned `newCtx`.
///         The forged ctx survives the `claim()` call and comes back as raw
///         bytes, but without an actual callback frame the host does not turn
///         `appCreditGranted/appCreditUsed/appAddress/appCreditToken` into any
///         extra balance movement.
contract Attempt6 is Test {
    struct ClaimProbe {
        bool ok;
        uint256 pendingBefore;
        uint256 pendingAfter;
        int256 attackerDelta;
        int256 hostDelta;
        int256 sinkDelta;
        uint256 wrappedReturnLength;
        uint256 innerReturnLength;
        bytes32 innerReturnHash;
        bytes4 revertSelector;
        bytes innerReturn;
    }

    address constant ATTACKER = 0xc943eDB4Bb4439d65B81f2f60Bc698411e910B14;
    address constant KNOWN_USDCX_VICTIM = 0x2e9e3C24049655f2D8C59f08602Da3DE4aD34188;
    uint256 constant FORK_BLOCK = 27_039_967;

    uint32 constant BASELINE_INDEX_ID = 55_600_000;
    uint32 constant GRANTED_INDEX_ID = 55_600_001;
    uint32 constant NEGATIVE_USED_INDEX_ID = 55_600_002;
    uint32 constant CROSS_TOKEN_INDEX_ID = 55_600_003;
    uint32 constant APP_ADDRESS_INDEX_ID = 55_600_004;

    ISuperfluidHost constant HOST = ISuperfluidHost(0x3E14dC1b13c488a8d5D310918780c983bD5982E7);
    IInstantDistributionAgreementV1 constant IDA =
        IInstantDistributionAgreementV1(0xB0aABBA4B2783A72C52956CDEF62d438ecA2d7a1);
    ISETH constant MATICX = ISETH(0x3aD736904E9e65189c3000c7DD2c8AC8bB7cD4e3);
    ISuperToken constant USDCX = ISuperToken(0xCAa7349CEA390F89641fe306D93591f87595dc1F);

    function setUp() public {
        vm.createSelectFork("ch5", FORK_BLOCK);
        vm.label(ATTACKER, "Attacker");
        vm.label(KNOWN_USDCX_VICTIM, "KnownUSDCxVictim");
        vm.label(address(HOST), "SuperfluidHost");
        vm.label(address(IDA), "IDA");
        vm.label(address(MATICX), "MATICx");
        vm.label(address(USDCX), "USDCx");
    }

    function test_claim_returned_ctx_is_not_settled_without_callbacks() public {
        CtxSink sink = new CtxSink();
        vm.label(address(sink), "CtxSink");

        _seedAllClaims();

        uint256 nativeBefore = ATTACKER.balance;
        console.log("[start] attacker native:", nativeBefore);
        console.log("[preflight] chain id:", block.chainid);
        console.log("[preflight] fork block:", block.number);
        console.log("[preflight] host MATICx balance:", MATICX.balanceOf(address(HOST)));
        console.log("[preflight] sink MATICx balance:", MATICX.balanceOf(address(sink)));

        ClaimProbe memory baseline = _probeClaim(BASELINE_INDEX_ID, bytes(""), address(sink), false);

        bytes memory grantedCtx = _buildClaimContext(address(sink), address(MATICX), 0);
        bytes memory negativeUsedCtx = _buildClaimContext(address(sink), address(MATICX), -1);
        bytes memory crossTokenCtx = _buildClaimContext(address(sink), address(USDCX), 0);
        bytes memory attackerAddressCtx = _buildClaimContext(ATTACKER, address(MATICX), 0);

        ClaimProbe memory granted = _probeClaim(GRANTED_INDEX_ID, grantedCtx, address(sink), true);
        ClaimProbe memory negativeUsed = _probeClaim(NEGATIVE_USED_INDEX_ID, negativeUsedCtx, address(sink), true);
        ClaimProbe memory crossToken = _probeClaim(CROSS_TOKEN_INDEX_ID, crossTokenCtx, address(sink), true);
        ClaimProbe memory attackerAddress = _probeClaim(APP_ADDRESS_INDEX_ID, attackerAddressCtx, address(sink), true);

        _logProbe("baseline_plain_host_claim", baseline);
        _logProbe("granted_sink_maticx", granted);
        _logProbe("negative_used_sink_maticx", negativeUsed);
        _logProbe("cross_token_sink_usdcx", crossToken);
        _logProbe("app_address_attacker_eoa", attackerAddress);

        assertTrue(baseline.ok, "baseline host claim failed");
        assertEq(baseline.pendingBefore, 1, "baseline should start with one pending wei");
        assertEq(baseline.pendingAfter, 0, "baseline should consume pending claim");
        assertEq(baseline.attackerDelta, int256(1), "baseline should only credit one wei");
        assertEq(baseline.hostDelta, int256(0), "baseline should not move host balance");
        assertEq(baseline.sinkDelta, int256(0), "baseline should not move sink balance");

        _assertMatchesBaseline(granted, baseline);
        _assertMatchesBaseline(negativeUsed, baseline);
        _assertMatchesBaseline(crossToken, baseline);
        _assertMatchesBaseline(attackerAddress, baseline);

        _assertReturnedCtx(granted, address(sink), address(MATICX), 0);
        _assertReturnedCtx(negativeUsed, address(sink), address(MATICX), -1);
        _assertReturnedCtx(crossToken, address(sink), address(USDCX), 0);
        _assertReturnedCtx(attackerAddress, ATTACKER, address(MATICX), 0);

        uint256 nativeAfter = ATTACKER.balance;
        int256 nativeDelta = int256(nativeAfter) - int256(nativeBefore);
        console.log("[end] attacker native:", nativeAfter);
        console.logInt(nativeDelta);
        console.log("[end] host MATICx balance:", MATICX.balanceOf(address(HOST)));
        console.log("[end] sink MATICx balance:", MATICX.balanceOf(address(sink)));
    }

    function _seedAllClaims() internal {
        vm.deal(ATTACKER, 1 ether);

        vm.startPrank(ATTACKER);
        MATICX.upgradeByETH{value: 8}();
        _seedClaim(BASELINE_INDEX_ID);
        _seedClaim(GRANTED_INDEX_ID);
        _seedClaim(NEGATIVE_USED_INDEX_ID);
        _seedClaim(CROSS_TOKEN_INDEX_ID);
        _seedClaim(APP_ADDRESS_INDEX_ID);
        vm.stopPrank();
    }

    function _seedClaim(uint32 indexId) internal {
        _callAgreementOrRevert(abi.encodeCall(IDA.createIndex, (MATICX, indexId, new bytes(0))), "createIndex");
        _callAgreementOrRevert(
            abi.encodeCall(IDA.updateSubscription, (MATICX, indexId, ATTACKER, uint128(1), new bytes(0))),
            "updateSubscription"
        );
        _callAgreementOrRevert(abi.encodeCall(IDA.updateIndex, (MATICX, indexId, uint128(1), new bytes(0))), "updateIndex");
    }

    function _probeClaim(
        uint32 indexId,
        bytes memory fakeCtx,
        address sink,
        bool useTrailing
    ) internal returns (ClaimProbe memory probe) {
        uint256 attackerBefore = MATICX.balanceOf(ATTACKER);
        uint256 hostBefore = MATICX.balanceOf(address(HOST));
        uint256 sinkBefore = MATICX.balanceOf(sink);
        (,, , probe.pendingBefore) = IDA.getSubscription(MATICX, ATTACKER, indexId, ATTACKER);

        bytes memory wrappedReturn;
        vm.prank(ATTACKER);
        if (useTrailing) {
            (probe.ok, wrappedReturn) =
                _callAgreementWithTrailingBytes(abi.encodeCall(IDA.claim, (MATICX, ATTACKER, indexId, ATTACKER, fakeCtx)));
        } else {
            (probe.ok, wrappedReturn) =
                _callAgreementRaw(abi.encodeCall(IDA.claim, (MATICX, ATTACKER, indexId, ATTACKER, new bytes(0))));
        }

        probe.wrappedReturnLength = wrappedReturn.length;
        if (probe.ok) {
            bytes memory agreementReturn = abi.decode(wrappedReturn, (bytes));
            probe.innerReturn = agreementReturn.length == 0 ? bytes("") : abi.decode(agreementReturn, (bytes));
            probe.innerReturnLength = probe.innerReturn.length;
            probe.innerReturnHash = keccak256(probe.innerReturn);
            (,, , probe.pendingAfter) = IDA.getSubscription(MATICX, ATTACKER, indexId, ATTACKER);
        } else if (wrappedReturn.length >= 4) {
            bytes4 selector;
            assembly {
                selector := mload(add(wrappedReturn, 32))
            }
            probe.revertSelector = selector;
        }

        probe.attackerDelta = int256(MATICX.balanceOf(ATTACKER)) - int256(attackerBefore);
        probe.hostDelta = int256(MATICX.balanceOf(address(HOST))) - int256(hostBefore);
        probe.sinkDelta = int256(MATICX.balanceOf(sink)) - int256(sinkBefore);
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

    function _buildClaimContext(
        address appAddress,
        address appCreditToken,
        int256 appCreditUsed
    ) internal view returns (bytes memory) {
        ContextUtils.Context memory ctx = ContextUtils.buildContext(KNOWN_USDCX_VICTIM, IDA.claim.selector, "");
        ctx.appCreditGranted = type(uint128).max;
        ctx.appCreditUsed = appCreditUsed;
        ctx.appAddress = appAddress;
        ctx.appCreditToken = appCreditToken;
        return ContextUtils.encodeContext(ctx);
    }

    function _assertMatchesBaseline(ClaimProbe memory probe, ClaimProbe memory baseline) internal pure {
        assertTrue(probe.ok, "forged host claim failed");
        assertEq(probe.pendingBefore, baseline.pendingBefore, "pendingBefore changed");
        assertEq(probe.pendingAfter, baseline.pendingAfter, "pendingAfter changed");
        assertEq(probe.attackerDelta, baseline.attackerDelta, "attacker delta changed");
        assertEq(probe.hostDelta, baseline.hostDelta, "host delta changed");
        assertEq(probe.sinkDelta, baseline.sinkDelta, "sink delta changed");
        assertGt(probe.innerReturnLength, 0, "forged claim should return ctx bytes");
    }

    function _assertReturnedCtx(
        ClaimProbe memory probe,
        address expectedAppAddress,
        address expectedCreditToken,
        int256 expectedCreditUsed
    ) internal pure {
        ContextUtils.Context memory decoded = ContextUtils.decodeContext(probe.innerReturn);
        assertEq(decoded.msgSender, KNOWN_USDCX_VICTIM, "msgSender not preserved");
        assertEq(decoded.agreementSelector, IDA.claim.selector, "selector not preserved");
        assertEq(decoded.appCreditGranted, type(uint128).max, "granted not preserved");
        assertEq(decoded.appCreditUsed, expectedCreditUsed, "used not preserved");
        assertEq(decoded.appAddress, expectedAppAddress, "appAddress not preserved");
        assertEq(decoded.appCreditToken, expectedCreditToken, "credit token not preserved");
    }

    function _logProbe(string memory label, ClaimProbe memory probe) internal view {
        console.log("[probe]", label);
        console.log("  ok:", probe.ok);
        console.log("  pendingBefore:", probe.pendingBefore);
        console.log("  pendingAfter:", probe.pendingAfter);
        console.log("  attackerDelta:");
        console.logInt(probe.attackerDelta);
        console.log("  hostDelta:");
        console.logInt(probe.hostDelta);
        console.log("  sinkDelta:");
        console.logInt(probe.sinkDelta);
        console.log("  wrappedReturnLength:", probe.wrappedReturnLength);
        console.log("  innerReturnLength:", probe.innerReturnLength);
        console.logBytes32(probe.innerReturnHash);
        if (probe.ok && probe.innerReturnLength > 0) {
            ContextUtils.Context memory decoded = ContextUtils.decodeContext(probe.innerReturn);
            console.log("  ctx.msgSender:", decoded.msgSender);
            console.log("  ctx.appAddress:", decoded.appAddress);
            console.log("  ctx.appCreditToken:", decoded.appCreditToken);
            console.log("  ctx.appCreditGranted:", decoded.appCreditGranted);
            console.logInt(decoded.appCreditUsed);
        }
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
