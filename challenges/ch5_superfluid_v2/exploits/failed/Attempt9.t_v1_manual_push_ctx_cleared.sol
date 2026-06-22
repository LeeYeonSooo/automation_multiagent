// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import {ContextUtils} from "reference/ContextUtils.sol";

interface ISuperAgreement {
    function agreementType() external view returns (bytes32);
}

interface ISuperToken {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}

interface ISETH is ISuperToken {
    function upgradeByETH() external payable;
    function downgradeToETH(uint256 wad) external;
}

interface ISuperfluidHost {
    function callAgreement(
        ISuperAgreement agreementClass,
        bytes calldata callData,
        bytes calldata userData
    ) external returns (bytes memory returnedData);

    function appCallbackPush(
        bytes calldata ctx,
        address app,
        uint256 appCreditGranted,
        int256 appCreditUsed,
        address appCreditToken
    ) external returns (bytes memory appCtx);

    function appCallbackPop(bytes calldata ctx, int256 appCreditUsedDelta) external returns (bytes memory newCtx);
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

contract AppProbe {
    function noop() external pure {}
}

contract AgreementTypeSpoof {
    ISuperfluidHost internal immutable host;
    bytes32 internal immutable idaAgreementType;
    bytes32 internal constant FAKE_AGREEMENT_TYPE = keccak256("attempt9.fake.agreement");
    bool internal useIdaType;

    constructor(ISuperfluidHost host_, bytes32 idaAgreementType_) {
        host = host_;
        idaAgreementType = idaAgreementType_;
    }

    function agreementType() external view returns (bytes32) {
        return useIdaType ? idaAgreementType : FAKE_AGREEMENT_TYPE;
    }

    function probePush(
        bytes calldata ctx,
        address app,
        uint256 appCreditGranted,
        int256 appCreditUsed,
        address appCreditToken,
        bool useIdaType_
    ) external returns (bool ok, bytes memory ret) {
        useIdaType = useIdaType_;
        (ok, ret) = address(host).call(
            abi.encodeCall(host.appCallbackPush, (ctx, app, appCreditGranted, appCreditUsed, appCreditToken))
        );
    }
}

/// @title Attempt9
/// @notice Hypothesis: the host's public callback helpers might let an
///         unprivileged caller manufacture callback scope manually, or a
///         forged `claim()` might leave usable app credit behind for the next
///         SuperToken operation in the same transaction.
///
///         This probe closes both branches on the patched fork:
///         1. direct `appCallbackPush(...)` is gated to listed agreement
///            classes, not just contracts that implement `agreementType()`;
///         2. after a successful forged `HOST.callAgreement(IDA.claim)`, the
///            host clears slot `0x06`, and immediate over-balance SuperToken
///            operations still fail on ordinary balance checks.
contract Attempt9 is Test {
    address constant ATTACKER = 0xc943eDB4Bb4439d65B81f2f60Bc698411e910B14;
    address constant KNOWN_USDCX_VICTIM = 0x2e9e3C24049655f2D8C59f08602Da3DE4aD34188;
    uint256 constant FORK_BLOCK = 27_039_967;

    uint32 constant INDEX_ID = 55_900_001;

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

    function test_manual_callback_push_and_residual_ctx_are_closed() public {
        vm.deal(ATTACKER, 1 ether);

        AppProbe app = new AppProbe();
        AgreementTypeSpoof spoof = new AgreementTypeSpoof(HOST, IDA.agreementType());

        vm.label(address(app), "AppProbe");
        vm.label(address(spoof), "AgreementTypeSpoof");

        uint256 nativeBefore = ATTACKER.balance;
        console.log("[start] attacker native:", nativeBefore);
        console.log("[preflight] chain id:", block.chainid);
        console.log("[preflight] fork block:", block.number);
        console.logBytes32(vm.load(address(HOST), bytes32(uint256(6))));

        bytes memory forgedCtx = _buildClaimContext();

        vm.prank(ATTACKER);
        (bool eoaPushOk, bytes memory eoaPushRet) = address(HOST).call(
            abi.encodeCall(HOST.appCallbackPush, (forgedCtx, address(app), type(uint128).max, int256(0), address(MATICX)))
        );
        console.log("[push:eoa] ok:", eoaPushOk);
        console.log("[push:eoa] decoded:", _decodeRevert(eoaPushRet));
        assertFalse(eoaPushOk, "EOA should not be able to push callback scope");

        (bool fakeAgreementPushOk, bytes memory fakeAgreementPushRet) =
            spoof.probePush(forgedCtx, address(app), type(uint128).max, 0, address(MATICX), false);
        console.log("[push:fake agreement type] ok:", fakeAgreementPushOk);
        console.log("[push:fake agreement type] decoded:", _decodeRevert(fakeAgreementPushRet));
        assertFalse(fakeAgreementPushOk, "non-listed agreement type should fail");

        (bool idaTypePushOk, bytes memory idaTypePushRet) =
            spoof.probePush(forgedCtx, address(app), type(uint128).max, 0, address(MATICX), true);
        console.log("[push:spoofed ida type] ok:", idaTypePushOk);
        console.log("[push:spoofed ida type] decoded:", _decodeRevert(idaTypePushRet));
        assertFalse(idaTypePushOk, "caller must be the listed agreement contract itself");

        assertEq(vm.load(address(HOST), bytes32(uint256(6))), bytes32(0), "failed push attempts must not leave ctx behind");

        _seedPendingClaim();

        uint256 tokenBeforeClaim = MATICX.balanceOf(ATTACKER);
        (,,, uint256 pendingBefore) = IDA.getSubscription(MATICX, ATTACKER, INDEX_ID, ATTACKER);

        vm.prank(ATTACKER);
        (bool claimOk, bytes memory claimRet) = _callAgreementWithTrailingBytes(
            IDA, abi.encodeCall(IDA.claim, (MATICX, ATTACKER, INDEX_ID, ATTACKER, forgedCtx))
        );

        uint256 tokenAfterClaim = MATICX.balanceOf(ATTACKER);
        (,,, uint256 pendingAfter) = IDA.getSubscription(MATICX, ATTACKER, INDEX_ID, ATTACKER);
        bytes32 slot6AfterClaim = vm.load(address(HOST), bytes32(uint256(6)));

        console.log("[claim] ok:", claimOk);
        console.log("[claim] wrapped return length:", claimRet.length);
        console.log("[claim] token delta:", tokenAfterClaim - tokenBeforeClaim);
        console.log("[claim] pending before:", pendingBefore);
        console.log("[claim] pending after:", pendingAfter);
        console.logBytes32(slot6AfterClaim);

        assertTrue(claimOk, "forged host claim should still succeed");
        assertEq(tokenAfterClaim - tokenBeforeClaim, 1, "claim should only materialize the pending one wei");
        assertEq(pendingBefore, 1, "seeded claim should start with one wei pending");
        assertEq(pendingAfter, 0, "claim should consume the pending distribution");
        assertEq(slot6AfterClaim, bytes32(0), "host must clear ctx slot before returning");

        uint256 overdraftAmount = tokenAfterClaim + 1;
        uint256 nativeBeforeTokenOps = ATTACKER.balance;
        address sink = makeAddr("sink");
        vm.label(sink, "Sink");

        vm.prank(ATTACKER);
        (bool transferOk, bytes memory transferRet) =
            address(MATICX).call(abi.encodeCall(ISuperToken.transfer, (sink, overdraftAmount)));
        console.log("[post-claim transfer] ok:", transferOk);
        console.log("[post-claim transfer] decoded:", _decodeRevert(transferRet));
        assertFalse(transferOk, "post-claim transfer should still respect real balance");

        vm.prank(ATTACKER);
        (bool downgradeOk, bytes memory downgradeRet) =
            address(MATICX).call(abi.encodeCall(ISETH.downgradeToETH, (overdraftAmount)));
        console.log("[post-claim downgrade] ok:", downgradeOk);
        console.log("[post-claim downgrade] decoded:", _decodeRevert(downgradeRet));
        assertFalse(downgradeOk, "post-claim downgrade should still respect real balance");

        assertEq(MATICX.balanceOf(ATTACKER), tokenAfterClaim, "failed token ops must not mint extra balance");
        assertEq(ATTACKER.balance, nativeBeforeTokenOps, "failed downgrade must not leak native balance");

        uint256 nativeAfter = ATTACKER.balance;
        console.log("[end] attacker native:", nativeAfter);
        console.logInt(int256(nativeAfter) - int256(nativeBefore));
    }

    function _seedPendingClaim() internal {
        vm.prank(ATTACKER);
        MATICX.upgradeByETH{value: 2 wei}();

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

    function _buildClaimContext() internal view returns (bytes memory) {
        ContextUtils.Context memory ctx = ContextUtils.buildContext(KNOWN_USDCX_VICTIM, IDA.claim.selector, "");
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
