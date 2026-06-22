// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {ContextUtils} from "reference/ContextUtils.sol";

interface ISuperAgreement42 {}

interface IInstantDistributionAgreementV142 is ISuperAgreement42 {
    function claim(
        address token,
        address publisher,
        uint32 indexId,
        address subscriber,
        bytes calldata ctx
    ) external returns (bytes memory newCtx);

    function getSubscription(address token, address publisher, uint32 indexId, address subscriber)
        external
        view
        returns (bool exist, bool approved, uint128 units, uint256 pendingDistribution);
}

interface ISuperAppLike42 {
    function beforeAgreementUpdated(
        address superToken,
        address agreementClass,
        bytes32 agreementId,
        bytes calldata agreementData,
        bytes calldata ctx
    ) external view returns (bytes memory cbdata);

    function afterAgreementUpdated(
        address superToken,
        address agreementClass,
        bytes32 agreementId,
        bytes calldata agreementData,
        bytes calldata cbdata,
        bytes calldata ctx
    ) external returns (bytes memory newCtx);
}

/// @title Attempt42
/// @notice Offline replay of the fork IDA `claim()` body using cached fork
///         bytecode extracted earlier from `cast code`.
/// @dev The fixture at `recon/attempt40_bytecode_fixture.json` was generated
///      from `~/.foundry/cache/rpc/2403/27039967`, which itself came from the
///      challenge RPC at Polygon fork block `27,039,967`.
///
///      This attempt answers the task's three decompile questions without
///      depending on a live RPC:
///      1. whether fork-only logic exists around the two `settleBalance` calls,
///      2. whether the callback path adds non-public parameters,
///      3. whether `pendingDistribution` uses anything other than
///         `(indexValue - subscriptionIndexValue) * units`.
contract Attempt42 is Test {
    using stdJson for string;

    string internal constant FIXTURE_PATH = "recon/attempt40_bytecode_fixture.json";

    address internal constant IDA_PROXY = 0xB0aABBA4B2783A72C52956CDEF62d438ecA2d7a1;
    address internal constant IDA_IMPL = 0x848497975f5757Aa1a48e13bbF46D330E62b19A7;
    bytes32 internal constant IMPLEMENTATION_SLOT =
        0x360894A13BA1A3210667C828492DB98DCA3E2076CC3735A920A3CA505D382BBC;

    address internal constant PUBLISHER = 0xcaB28480ab5c1E133e9B7FC67E030B8DCC2A1d24;
    address internal constant SUBSCRIBER = 0x9C6B5FdC145912dfe6eE13A667aF3C5Eb07CbB89;

    uint32 internal constant INDEX_ID = 40;
    uint128 internal constant UNITS = 3;
    uint128 internal constant INDEX_VALUE = 2 ether;
    uint256 internal constant PENDING = uint256(UNITS) * uint256(INDEX_VALUE);
    uint256 internal constant PUBLISHER_AVAILABLE = 5 ether;
    uint256 internal constant PUBLISHER_DEPOSIT_SLOT_ID = uint256(1) << 32;

    uint16 internal constant CLAIM_BODY_START = 0x2758;
    uint16 internal constant CLAIM_BODY_END = 0x2b5d;
    uint16 internal constant AUTHORIZE_HELPER_ENTRY = 0x3939;

    bytes4 internal constant CLAIM_SELECTOR = IInstantDistributionAgreementV142.claim.selector;
    bytes4 internal constant SETTLE_BALANCE_SELECTOR = 0xcf97256d;
    bytes4 internal constant UPDATE_AGREEMENT_DATA_SELECTOR = 0xa1b2bf8b;
    bytes4 internal constant BEFORE_UPDATED_SELECTOR = ISuperAppLike42.beforeAgreementUpdated.selector;
    bytes4 internal constant AFTER_UPDATED_SELECTOR = ISuperAppLike42.afterAgreementUpdated.selector;

    IInstantDistributionAgreementV142 internal constant IDA = IInstantDistributionAgreementV142(IDA_PROXY);

    MockSuperToken42 internal token;

    struct CallbackBeforePayload {
        address token;
        address agreementClass;
        bytes32 agreementId;
        bytes agreementData;
        bytes placeholderCtx;
    }

    struct CallbackAfterPayload {
        address token;
        address agreementClass;
        bytes32 agreementId;
        bytes agreementData;
        bytes cbdata;
        bytes placeholderCtx;
    }

    function setUp() public {
        string memory fixture = vm.readFile(FIXTURE_PATH);

        bytes memory implCode = vm.parseBytes(fixture.readString(".ida_impl_bytecode"));
        bytes memory proxyCode = vm.parseBytes(fixture.readString(".ida_proxy_bytecode"));

        vm.etch(IDA_IMPL, implCode);
        vm.etch(IDA_PROXY, proxyCode);
        vm.store(IDA_PROXY, IMPLEMENTATION_SLOT, bytes32(uint256(uint160(IDA_IMPL))));

        token = new MockSuperToken42();

        vm.label(IDA_PROXY, "IDAProxyCached");
        vm.label(IDA_IMPL, "IDAImplCached");
        vm.label(address(token), "MockSuperToken42");
        vm.label(PUBLISHER, "Publisher");
        vm.label(SUBSCRIBER, "Subscriber");
    }

    function test_claim_body_keeps_public_settlement_shape() public view {
        bytes memory code = IDA_IMPL.code;
        uint256 settleCount = _countPush4(code, CLAIM_BODY_START, CLAIM_BODY_END, SETTLE_BALANCE_SELECTOR);
        uint256 updateCount = _countPush4(code, CLAIM_BODY_START, CLAIM_BODY_END, UPDATE_AGREEMENT_DATA_SELECTOR);
        uint256 firstSettlePc = _findNthPush4(code, CLAIM_BODY_START, CLAIM_BODY_END, SETTLE_BALANCE_SELECTOR, 1);
        uint256 secondSettlePc = _findNthPush4(code, CLAIM_BODY_START, CLAIM_BODY_END, SETTLE_BALANCE_SELECTOR, 2);
        uint256 updatePc = _findNthPush4(code, CLAIM_BODY_START, CLAIM_BODY_END, UPDATE_AGREEMENT_DATA_SELECTOR, 1);
        uint256 thirdSettlePc = _findNthPush4(code, CLAIM_BODY_START, CLAIM_BODY_END, SETTLE_BALANCE_SELECTOR, 3);

        console.log("[opcode] fork impl code size:", code.length);
        console.log("[opcode] claim selector:");
        console.logBytes4(CLAIM_SELECTOR);
        console.log("[opcode] settleBalance selector count:", settleCount);
        console.log("[opcode] updateAgreementData selector count:", updateCount);
        console.log("[opcode] first settleBalance pc:", firstSettlePc);
        console.log("[opcode] second settleBalance pc:", secondSettlePc);
        console.log("[opcode] updateAgreementData pc:", updatePc);
        console.log("[opcode] third settleBalance pc:", thirdSettlePc);

        assertEq(code.length, 24_409, "unexpected cached fork impl size");
        assertEq(settleCount, 3, "unexpected settleBalance selector shape inside claim body");
        assertEq(updateCount, 1, "unexpected updateAgreementData selector count inside claim body");
        assertLt(firstSettlePc, updatePc, "first settle selector should precede state write");
        assertLt(secondSettlePc, updatePc, "duplicate settle selector should still precede state write");
        assertLt(updatePc, thirdSettlePc, "subscriber settle selector should follow state write");
        assertFalse(
            _containsPush2(code, CLAIM_BODY_START, CLAIM_BODY_END, AUTHORIZE_HELPER_ENTRY),
            "claim body unexpectedly references the shared authorize helper"
        );
    }

    function test_callback_payload_keeps_public_argument_shape() public {
        _seedControlState();

        FakeHostRecorder42 fakeHost = new FakeHostRecorder42(IDA_PROXY);

        (bool exist, bool approved, uint128 units, uint256 pendingBefore) =
            IDA.getSubscription(address(token), PUBLISHER, INDEX_ID, SUBSCRIBER);

        bytes memory returnedCtx = fakeHost.claim(address(token), PUBLISHER, INDEX_ID, SUBSCRIBER);

        (,,, uint256 pendingAfter) = IDA.getSubscription(address(token), PUBLISHER, INDEX_ID, SUBSCRIBER);
        (bytes4 beforeSelector, CallbackBeforePayload memory beforePayload) =
            _decodeBeforeCallback(fakeHost.beforeCallbackData());
        (bytes4 afterSelector, CallbackAfterPayload memory afterPayload) =
            _decodeAfterCallback(fakeHost.afterCallbackData());

        console.log("[runtime] exist:", exist);
        console.log("[runtime] approved:", approved);
        console.log("[runtime] units:", uint256(units));
        console.log("[runtime] pending before:", pendingBefore);
        console.log("[runtime] callback pushes:", fakeHost.appCallbackPushCalls());
        console.log("[runtime] before callbacks:", fakeHost.beforeCallbackCalls());
        console.log("[runtime] after callbacks:", fakeHost.afterCallbackCalls());
        console.log("[runtime] callback pops:", fakeHost.appCallbackPopCalls());
        console.log("[runtime] first push grant:", fakeHost.firstPushGranted());
        console.logInt(fakeHost.firstPushUsed());
        console.log("[runtime] returned ctx length:", returnedCtx.length);
        console.log("[runtime] pending after:", pendingAfter);

        assertTrue(exist, "subscription should exist");
        assertFalse(approved, "subscription should stay unapproved");
        assertEq(units, UNITS, "units mismatch");
        assertEq(pendingBefore, PENDING, "pending mismatch");

        assertEq(fakeHost.appCallbackPushCalls(), 2, "claim should push callback stack twice");
        assertEq(fakeHost.beforeCallbackCalls(), 1, "claim should do one before callback");
        assertEq(fakeHost.afterCallbackCalls(), 1, "claim should do one after callback");
        assertEq(fakeHost.appCallbackPopCalls(), 2, "claim should pop callback stack twice");

        assertEq(fakeHost.firstPushApp(), PUBLISHER, "first push target should stay publisher");
        assertEq(fakeHost.secondPushApp(), PUBLISHER, "second push target should stay publisher");
        assertEq(fakeHost.firstPushToken(), address(token), "first push token mismatch");
        assertEq(fakeHost.secondPushToken(), address(token), "second push token mismatch");
        assertEq(fakeHost.firstPushGranted(), 0, "claim should not add callback credit");
        assertEq(fakeHost.secondPushGranted(), 0, "claim should not add callback credit");
        assertEq(fakeHost.firstPushUsed(), 0, "claim should not add callback credit usage");
        assertEq(fakeHost.secondPushUsed(), 0, "claim should not add callback credit usage");

        assertEq(fakeHost.beforeApp(), PUBLISHER, "before callback app must stay publisher");
        assertEq(fakeHost.afterApp(), PUBLISHER, "after callback app must stay publisher");
        assertFalse(fakeHost.beforeIsTermination(), "before hook should not use termination path");
        assertFalse(fakeHost.afterIsTermination(), "after hook should not use termination path");

        assertEq(beforeSelector, BEFORE_UPDATED_SELECTOR, "unexpected beforeAgreement selector");
        assertEq(afterSelector, AFTER_UPDATED_SELECTOR, "unexpected afterAgreement selector");
        assertEq(beforePayload.token, address(token), "before payload token mismatch");
        assertEq(afterPayload.token, address(token), "after payload token mismatch");
        assertEq(beforePayload.agreementClass, IDA_PROXY, "before payload agreementClass mismatch");
        assertEq(afterPayload.agreementClass, IDA_PROXY, "after payload agreementClass mismatch");
        assertEq(afterPayload.agreementId, beforePayload.agreementId, "agreement id should stay stable");
        assertEq(beforePayload.agreementData.length, 0, "before agreementData should stay empty");
        assertEq(afterPayload.agreementData.length, 0, "after agreementData should stay empty");
        assertEq(beforePayload.placeholderCtx.length, 0, "before ctx placeholder should stay empty");
        assertEq(afterPayload.placeholderCtx.length, 0, "after ctx placeholder should stay empty");
        assertEq(
            keccak256(afterPayload.cbdata),
            keccak256(fakeHost.expectedCbdata()),
            "after callback should receive the cbdata returned by before hook"
        );
        assertEq(pendingAfter, 0, "claim should fully materialize the pending distribution");
    }

    function test_pending_distribution_and_publisher_deposit_match_public_formula() public {
        _seedControlState();

        (bool exist, bool approved, uint128 units, uint256 pendingBefore) =
            IDA.getSubscription(address(token), PUBLISHER, INDEX_ID, SUBSCRIBER);

        int256 publisherAvailableBefore = token.debugAvailableBalance(IDA_PROXY, PUBLISHER);
        int256 subscriberAvailableBefore = token.debugAvailableBalance(IDA_PROXY, SUBSCRIBER);
        uint256 publisherDepositBefore = token.debugDeposit(IDA_PROXY, PUBLISHER);

        FakeHostRecorder42 fakeHost = new FakeHostRecorder42(IDA_PROXY);
        fakeHost.claim(address(token), PUBLISHER, INDEX_ID, SUBSCRIBER);

        (,,, uint256 pendingAfter) = IDA.getSubscription(address(token), PUBLISHER, INDEX_ID, SUBSCRIBER);

        int256 publisherAvailableAfter = token.debugAvailableBalance(IDA_PROXY, PUBLISHER);
        int256 subscriberAvailableAfter = token.debugAvailableBalance(IDA_PROXY, SUBSCRIBER);
        uint256 publisherDepositAfter = token.debugDeposit(IDA_PROXY, PUBLISHER);

        console.log("[formula] expected pending:", PENDING);
        console.log("[formula] pending before:", pendingBefore);
        console.log("[formula] publisher deposit before:", publisherDepositBefore);
        console.log("[formula] publisher deposit after:", publisherDepositAfter);
        console.logInt(subscriberAvailableAfter - subscriberAvailableBefore);
        console.log("[formula] pending after:", pendingAfter);

        assertTrue(exist, "subscription should exist");
        assertFalse(approved, "subscription should stay unapproved");
        assertEq(units, UNITS, "units mismatch");
        assertEq(pendingBefore, PENDING, "pendingDistribution should equal indexValue * units");
        assertEq(pendingAfter, 0, "claim should clear pending distribution");
        assertEq(
            subscriberAvailableAfter - subscriberAvailableBefore,
            int256(PENDING),
            "subscriber available balance should rise by pendingDistribution"
        );
        assertEq(
            publisherDepositBefore - publisherDepositAfter,
            PENDING,
            "publisher deposit release should match the subscriber payout"
        );
        assertEq(
            publisherAvailableAfter,
            publisherAvailableBefore,
            "publisher available balance should stay unchanged after deposit release + debit"
        );
    }

    function _seedControlState() internal {
        token.seedUnapprovedSubscription(
            IDA_PROXY,
            PUBLISHER,
            INDEX_ID,
            SUBSCRIBER,
            UNITS,
            INDEX_VALUE,
            PUBLISHER_DEPOSIT_SLOT_ID,
            PENDING,
            PUBLISHER_AVAILABLE
        );
    }

    function _decodeBeforeCallback(bytes memory callData)
        internal
        pure
        returns (bytes4 selector, CallbackBeforePayload memory payload)
    {
        selector = _selectorOf(callData);
        (payload.token, payload.agreementClass, payload.agreementId, payload.agreementData, payload.placeholderCtx) =
            abi.decode(_trimSelector(callData), (address, address, bytes32, bytes, bytes));
    }

    function _decodeAfterCallback(bytes memory callData)
        internal
        pure
        returns (bytes4 selector, CallbackAfterPayload memory payload)
    {
        selector = _selectorOf(callData);
        (
            payload.token,
            payload.agreementClass,
            payload.agreementId,
            payload.agreementData,
            payload.cbdata,
            payload.placeholderCtx
        ) = abi.decode(_trimSelector(callData), (address, address, bytes32, bytes, bytes, bytes));
    }

    function _trimSelector(bytes memory blob) internal pure returns (bytes memory out) {
        require(blob.length >= 4, "blob too short");
        out = new bytes(blob.length - 4);
        for (uint256 i = 4; i < blob.length; ++i) {
            out[i - 4] = blob[i];
        }
    }

    function _selectorOf(bytes memory blob) internal pure returns (bytes4 selector) {
        if (blob.length < 4) return bytes4(0);
        assembly {
            selector := mload(add(blob, 0x20))
        }
    }

    function _containsPush2(bytes memory code, uint256 start, uint256 endInclusive, uint16 value)
        internal
        pure
        returns (bool)
    {
        if (endInclusive <= start + 2) return false;

        bytes2 needle = bytes2(value);
        for (uint256 i = start; i + 2 <= endInclusive; ++i) {
            if (
                code[i] == bytes1(0x61)
                    && code[i + 1] == needle[0]
                    && code[i + 2] == needle[1]
            ) {
                return true;
            }
        }
        return false;
    }

    function _countPush4(bytes memory code, uint256 start, uint256 endInclusive, bytes4 value)
        internal
        pure
        returns (uint256 count)
    {
        for (uint256 i = start; i + 4 <= endInclusive; ++i) {
            if (uint8(code[i]) == 0x63 && _readBytes4(code, i + 1) == value) {
                count++;
            }
        }
    }

    function _findNthPush4(bytes memory code, uint256 start, uint256 endInclusive, bytes4 value, uint256 nth)
        internal
        pure
        returns (uint256 pc)
    {
        uint256 seen;
        for (uint256 i = start; i + 4 <= endInclusive; ++i) {
            if (uint8(code[i]) == 0x63 && _readBytes4(code, i + 1) == value) {
                seen++;
                if (seen == nth) return i;
            }
        }
        revert("push4 not found");
    }

    function _readBytes4(bytes memory data, uint256 offset) internal pure returns (bytes4 value) {
        assembly {
            value := mload(add(add(data, 0x20), offset))
        }
    }
}

contract MockSuperToken42 {
    mapping(address agreementClass => mapping(bytes32 id => bytes32[2])) internal _agreementData;
    mapping(address agreementClass => mapping(address account => mapping(uint256 slotId => bytes32[1]))) internal _stateSlots;
    mapping(address => int256) internal _settledBalances;

    function seedUnapprovedSubscription(
        address agreementClass,
        address publisher,
        uint32 indexId,
        address subscriber,
        uint128 units,
        uint128 indexValue,
        uint256 publisherDepositSlotId,
        uint256 publisherDeposit,
        uint256 publisherAvailable
    ) external {
        bytes32 iId = keccak256(abi.encodePacked("publisher", publisher, indexId));
        bytes32 sId = keccak256(abi.encodePacked("subscription", subscriber, iId));

        _agreementData[agreementClass][iId][0] = bytes32((uint256(1) << 128) | uint256(indexValue));
        _agreementData[agreementClass][iId][1] = bytes32(uint256(units) << 128);

        _agreementData[agreementClass][sId][0] =
            bytes32((uint256(uint160(publisher)) << 96) | (uint256(indexId) << 32) | uint256(type(uint32).max));
        _agreementData[agreementClass][sId][1] = bytes32(uint256(units) << 128);

        _stateSlots[agreementClass][publisher][publisherDepositSlotId][0] = bytes32(publisherDeposit);
        _settledBalances[publisher] = int256(publisherDeposit + publisherAvailable);
        _settledBalances[subscriber] = 0;
    }

    function getAgreementData(address agreementClass, bytes32 id, uint256 dataLength)
        external
        view
        returns (bytes32[] memory data)
    {
        data = new bytes32[](dataLength);
        bytes32[2] storage stored = _agreementData[agreementClass][id];
        if (dataLength > 0) data[0] = stored[0];
        if (dataLength > 1) data[1] = stored[1];
    }

    function updateAgreementData(bytes32 id, bytes32[] calldata data) external {
        if (data.length > 0) _agreementData[msg.sender][id][0] = data[0];
        if (data.length > 1) _agreementData[msg.sender][id][1] = data[1];
    }

    function getAgreementStateSlot(address agreementClass, address account, uint256 slotId, uint256 dataLength)
        external
        view
        returns (bytes32[] memory data)
    {
        data = new bytes32[](dataLength);
        if (dataLength > 0) {
            data[0] = _stateSlots[agreementClass][account][slotId][0];
        }
    }

    function updateAgreementStateSlot(address account, uint256 slotId, bytes32[] calldata data) external {
        if (data.length > 0) {
            _stateSlots[msg.sender][account][slotId][0] = data[0];
        }
    }

    function settleBalance(address account, int256 delta) external {
        _settledBalances[account] += delta;
    }

    function debugAvailableBalance(address agreementClass, address account) external view returns (int256) {
        return _settledBalances[account] - int256(debugDeposit(agreementClass, account));
    }

    function debugDeposit(address agreementClass, address account) public view returns (uint256) {
        return uint256(_stateSlots[agreementClass][account][uint256(1) << 32][0]);
    }
}

contract FakeHostRecorder42 {
    address public immutable ida;

    uint256 public appCallbackPushCalls;
    uint256 public beforeCallbackCalls;
    uint256 public afterCallbackCalls;
    uint256 public appCallbackPopCalls;

    address public firstPushApp;
    address public secondPushApp;
    address public firstPushToken;
    address public secondPushToken;
    uint256 public firstPushGranted;
    uint256 public secondPushGranted;
    int256 public firstPushUsed;
    int256 public secondPushUsed;

    address public beforeApp;
    address public afterApp;
    bool public beforeIsTermination;
    bool public afterIsTermination;

    bytes public beforeCallbackData;
    bytes public afterCallbackData;

    constructor(address ida_) {
        ida = ida_;
    }

    function claim(address token, address publisher, uint32 indexId, address subscriber)
        external
        returns (bytes memory)
    {
        return IInstantDistributionAgreementV142(ida).claim(token, publisher, indexId, subscriber, _blankAgreementCtx());
    }

    function getAppManifest(address) external pure returns (bool, bool, uint256) {
        return (true, false, 0);
    }

    function isApp(address) external pure returns (bool) {
        return true;
    }

    function isCtxValid(bytes calldata) external pure returns (bool) {
        return true;
    }

    function decodeCtx(bytes memory packed)
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
        ContextUtils.Context memory ctx = ContextUtils.decodeContext(packed);
        return (
            ctx.appCallbackLevel,
            ctx.callType,
            ctx.timestamp,
            ctx.msgSender,
            ctx.agreementSelector,
            ctx.userData,
            ctx.appCreditGranted,
            ctx.appCreditWantedDeprecated,
            ctx.appCreditUsed,
            ctx.appAddress,
            ctx.appCreditToken
        );
    }

    function appCallbackPush(bytes calldata ctx, address app, uint256 granted, int256 used, address token)
        external
        returns (bytes memory)
    {
        if (appCallbackPushCalls == 0) {
            firstPushApp = app;
            firstPushToken = token;
            firstPushGranted = granted;
            firstPushUsed = used;
        } else if (appCallbackPushCalls == 1) {
            secondPushApp = app;
            secondPushToken = token;
            secondPushGranted = granted;
            secondPushUsed = used;
        }

        appCallbackPushCalls++;
        return ctx;
    }

    function appCallbackPop(bytes calldata ctx, int256) external returns (bytes memory) {
        appCallbackPopCalls++;
        return ctx;
    }

    function callAppBeforeCallback(address app, bytes calldata callData, bool isTermination, bytes calldata)
        external
        returns (bytes memory)
    {
        beforeCallbackCalls++;
        beforeApp = app;
        beforeIsTermination = isTermination;
        beforeCallbackData = callData;
        return expectedCbdata();
    }

    function callAppAfterCallback(address app, bytes calldata callData, bool isTermination, bytes calldata ctx)
        external
        returns (bytes memory)
    {
        afterCallbackCalls++;
        afterApp = app;
        afterIsTermination = isTermination;
        afterCallbackData = callData;
        return ctx;
    }

    function expectedCbdata() public pure returns (bytes memory) {
        return abi.encodePacked(uint256(0x40));
    }

    function _blankAgreementCtx() internal view returns (bytes memory packed) {
        ContextUtils.Context memory ctx = ContextUtils.buildContext(address(this), IInstantDistributionAgreementV142.claim.selector, "");
        packed = ContextUtils.encodeContext(ctx);
    }
}
