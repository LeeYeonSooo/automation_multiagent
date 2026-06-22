// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";

interface IIDAClaim38 {
    function claim(address token, address publisher, uint32 indexId, address subscriber, bytes calldata ctx)
        external
        returns (bytes memory newCtx);

    function getSubscription(address token, address publisher, uint32 indexId, address subscriber)
        external
        view
        returns (bool exist, bool approved, uint128 units, uint256 pendingDistribution);
}

interface IERC20Like38 {
    function balanceOf(address account) external view returns (uint256);
}

interface ISuperApp38 {
    function beforeAgreementUpdated(address superToken, address agreementClass, bytes32 agreementId, bytes calldata agreementData, bytes calldata ctx)
        external
        view
        returns (bytes memory cbdata);

    function afterAgreementUpdated(
        address superToken,
        address agreementClass,
        bytes32 agreementId,
        bytes calldata agreementData,
        bytes calldata cbdata,
        bytes calldata ctx
    ) external returns (bytes memory newCtx);
}

/// @title Attempt38
/// @notice Manual claim() bytecode diff for the fork-only IDA implementation.
/// @dev Public reference source:
///      [0x85eb...]/src/contracts/agreements/InstantDistributionAgreementV1.sol:823-875
///
///      Public 0x85eb claim() order:
///      1. line 823   `AgreementLibrary.authorizeTokenAccess(token, ctx);`
///      2. line 824   zero-address subscriber guard
///      3. line 831   `_loadAllData(...)`
///      4. line 840   `subId == _UNALLOCATED_SUB_ID` check
///      5. line 844   `pendingDistribution` calculation
///      6. line 847   `createCallbackInputs(token, publisher, sId, "")`
///      7. line 856   before-callback
///      8. line 859   `_adjustPublisherDeposit(...)`
///      9. line 860   `token.settleBalance(publisher, -pending)`
///      10. line 864 `token.updateAgreementData(...)`
///      11. line 865 `token.settleBalance(subscriber, +pending)`
///      12. line 867 emit `IndexDistributionClaimed`
///      13. line 868 emit `SubscriptionDistributionClaimed`
///      14. line 871 after-callback
///
///      Fork runtime 0x848497... manual map:
///      - decoder entry          0x0614
///      - body entry             0x2758
///      - body starts with       `_loadAllData(...)` via jump 0x3afa
///      - no jump into shared    authorize helper 0x3939
///      - sibling approve path   0x2b5e does jump into 0x3939 first
///      - settlement order keeps public source ordering:
///          0x2794..27e5 subId check
///          0x27e6..2818 pendingDistribution
///          0x2819..2837 createCallbackInputs
///          0x283a..286d ctx copy
///          0x287b..28a3 before-callback helper
///          0x28a8..2908 token.settleBalance(publisher, -pending)
///          0x293b..29dc token.updateAgreementData(...)
///          0x29ec..2a47 token.settleBalance(subscriber, +pending)
///          0x2a76..2af4 claim events
///          0x2af5..2b10 after-callback helper
///          0x2b17..2b5d zero-pending return branch
///
///      Practical diff:
///      - Fork claim() skips the public source's authorizeTokenAccess path
///        entirely, so there is no `getHost()`, `isCtxValid(ctx)`, or
///        `decodeCtx(ctx)` prelude before storage loads.
///      - Fork claim() also skips the public zero-address subscriber guard.
///      - No extra fork-only storage write surfaced inside the body itself; the
///        fork-only behavior is the missing validation prelude, not added state
///        mutation.
contract Attempt38 is Test {
    address internal constant ATTACKER = 0xc943eDB4Bb4439d65B81f2f60Bc698411e910B14;

    address internal constant IDA_PROXY = 0xB0aABBA4B2783A72C52956CDEF62d438ecA2d7a1;
    address internal constant IDA_IMPL = 0x848497975f5757Aa1a48e13bbF46D330E62b19A7;

    address internal constant MATICX = 0x3aD736904E9e65189c3000c7DD2c8AC8bB7cD4e3;
    address internal constant LIVE_PUBLISHER = 0xcaB28480ab5c1E133e9B7FC67E030B8DCC2A1d24;
    address internal constant LIVE_SUBSCRIBER = 0x9C6B5FdC145912dfe6eE13A667aF3C5Eb07CbB89;
    uint32 internal constant LIVE_INDEX_ID = 1;

    uint16 internal constant CLAIM_DECODE_ENTRY = 0x0614;
    uint16 internal constant CLAIM_BODY_ENTRY = 0x2758;
    uint16 internal constant APPROVE_BODY_ENTRY = 0x2b5e;
    uint16 internal constant AUTHORIZE_HELPER_ENTRY = 0x3939;

    bytes4 internal constant CLAIM_SELECTOR = 0xacafa1b8;
    bytes4 internal constant SETTLE_BALANCE_SELECTOR = 0xcf97256d;
    bytes4 internal constant UPDATE_AGREEMENT_DATA_SELECTOR = 0xa1b2bf8b;
    bytes4 internal constant BEFORE_UPDATED_SELECTOR = ISuperApp38.beforeAgreementUpdated.selector;
    bytes4 internal constant AFTER_UPDATED_SELECTOR = ISuperApp38.afterAgreementUpdated.selector;
    bytes4 internal constant PUBLIC_ZERO_SUBSCRIBER_ERROR =
        bytes4(keccak256("IDA_ZERO_ADDRESS_SUBSCRIBER()"));

    bytes32 internal constant INDEX_DISTRIBUTION_CLAIMED_TOPIC =
        0x467eccd248ef31c8bcef16d94856855799a8783aeef10f3759e43614059a6bb1;
    bytes32 internal constant SUBSCRIPTION_DISTRIBUTION_CLAIMED_TOPIC =
        0x48a3d91d4a07e4982b081260e24f922bd33bb965882772d6de19c922c3eabdea;

    IIDAClaim38 internal constant ida = IIDAClaim38(IDA_PROXY);

    function setUp() public {
        vm.createSelectFork(vm.envString("RPC_CH5_SUPERFLUID_V2"));

        vm.label(ATTACKER, "Attacker");
        vm.label(IDA_PROXY, "IDAProxy");
        vm.label(IDA_IMPL, "IDAImplFork");
        vm.label(MATICX, "MATICx");
        vm.label(LIVE_PUBLISHER, "LivePublisher");
        vm.label(LIVE_SUBSCRIBER, "LiveSubscriber");
    }

    function test_manual_claim_body_map_matches_fork_runtime() public {
        bytes memory code = IDA_IMPL.code;

        console.log("[manual] fork impl code bytes:", code.length);
        console.log("[manual] claim decode entry:", uint256(CLAIM_DECODE_ENTRY));
        console.log("[manual] claim body entry:", uint256(CLAIM_BODY_ENTRY));
        console.log("[manual] sibling approve body entry:", uint256(APPROVE_BODY_ENTRY));
        console.log("[manual] shared authorize helper entry:", uint256(AUTHORIZE_HELPER_ENTRY));

        assertEq(code.length, 24_400, "unexpected fork impl code size");

        _assertPush4(code, 0x009f, CLAIM_SELECTOR);
        assertEq(_readU16(code, 0x00a6), CLAIM_DECODE_ENTRY, "claim selector no longer dispatches to 0x0614");

        _assertPush2(code, 0x06aa, CLAIM_BODY_ENTRY);
        _assertPush2(code, 0x2bae, AUTHORIZE_HELPER_ENTRY);
        assertFalse(
            _containsPush2(code, CLAIM_BODY_ENTRY, APPROVE_BODY_ENTRY - 1, AUTHORIZE_HELPER_ENTRY),
            "claim body unexpectedly references the authorize helper"
        );

        _assertPush4(code, 0x28a8, SETTLE_BALANCE_SELECTOR);
        _assertPush4(code, 0x293b, UPDATE_AGREEMENT_DATA_SELECTOR);
        _assertPush32(code, 0x2a76, INDEX_DISTRIBUTION_CLAIMED_TOPIC);
        _assertPush32(code, 0x2aca, SUBSCRIPTION_DISTRIBUTION_CLAIMED_TOPIC);

        console.log("[manual] claim skips authorize helper and jumps straight into _loadAllData");
        console.log("[manual] approveSubscription still jumps into authorize helper 0x3939 first");
        console.log("[manual] claim keeps the public settleBalance -> updateAgreementData -> settleBalance order");
    }

    function test_direct_claim_uses_arbitrary_msg_sender_callback_surface() public {
        FakeHostRecorder38 fakeHost = new FakeHostRecorder38(IDA_PROXY);

        (bool exist, bool approved, uint128 units, uint256 pendingBefore) =
            ida.getSubscription(MATICX, LIVE_PUBLISHER, LIVE_INDEX_ID, LIVE_SUBSCRIBER);
        uint256 subscriberBefore = IERC20Like38(MATICX).balanceOf(LIVE_SUBSCRIBER);

        console.log("[runtime] exist:", exist);
        console.log("[runtime] approved:", approved);
        console.log("[runtime] units:", uint256(units));
        console.log("[runtime] pending before:", pendingBefore);

        bytes memory ret = fakeHost.claim(MATICX, LIVE_PUBLISHER, LIVE_INDEX_ID, LIVE_SUBSCRIBER);

        uint256 subscriberAfter = IERC20Like38(MATICX).balanceOf(LIVE_SUBSCRIBER);
        (,,, uint256 pendingAfter) = ida.getSubscription(MATICX, LIVE_PUBLISHER, LIVE_INDEX_ID, LIVE_SUBSCRIBER);

        console.log("[runtime] fakeHost appCallbackPush calls:", fakeHost.appCallbackPushCalls());
        console.log("[runtime] fakeHost before-callback calls:", fakeHost.beforeCallbackCalls());
        console.log("[runtime] fakeHost after-callback calls:", fakeHost.afterCallbackCalls());
        console.log("[runtime] fakeHost appCallbackPop calls:", fakeHost.appCallbackPopCalls());
        console.log("[runtime] push app:", fakeHost.lastPushApp());
        console.log("[runtime] push token:", fakeHost.lastPushToken());
        console.log("[runtime] before selector:");
        console.logBytes4(fakeHost.lastBeforeSelector());
        console.log("[runtime] after selector:");
        console.logBytes4(fakeHost.lastAfterSelector());
        console.log("[runtime] returned ctx length:", ret.length);
        console.log("[runtime] subscriber delta:", subscriberAfter - subscriberBefore);
        console.log("[runtime] pending after:", pendingAfter);

        assertTrue(exist, "expected live tuple to exist");
        assertFalse(approved, "expected live tuple to stay on the unapproved claim path");
        assertGt(pendingBefore, 0, "expected positive pending distribution");

        assertEq(fakeHost.appCallbackPushCalls(), 2, "expected push before both callback phases");
        assertEq(fakeHost.beforeCallbackCalls(), 1, "expected exactly one before callback");
        assertEq(fakeHost.afterCallbackCalls(), 1, "expected exactly one after callback");
        assertEq(fakeHost.appCallbackPopCalls(), 2, "expected pop after both callback phases");

        assertEq(fakeHost.lastPushApp(), LIVE_PUBLISHER, "appCallbackPush should receive publisher");
        assertEq(fakeHost.lastPushToken(), MATICX, "appCallbackPush should receive the claim token");
        assertEq(fakeHost.lastBeforeApp(), LIVE_PUBLISHER, "before callback should target publisher");
        assertEq(fakeHost.lastAfterApp(), LIVE_PUBLISHER, "after callback should target publisher");
        assertEq(fakeHost.lastBeforeSelector(), BEFORE_UPDATED_SELECTOR, "unexpected before callback selector");
        assertEq(fakeHost.lastAfterSelector(), AFTER_UPDATED_SELECTOR, "unexpected after callback selector");

        assertEq(subscriberAfter - subscriberBefore, pendingBefore, "plain fake-host claim should pay the real subscriber once");
        assertEq(pendingAfter, 0, "claim should consume the pending distribution");
    }

    function test_zero_address_guard_is_missing_relative_to_public_0x85eb_source() public {
        FakeHostRecorder38 fakeHost = new FakeHostRecorder38(IDA_PROXY);

        bytes memory returnedCtx = fakeHost.claimZeroSubscriber(MATICX, LIVE_PUBLISHER, LIVE_INDEX_ID);

        console.log("[zero-subscriber] returned ctx length:", returnedCtx.length);
        console.log("[zero-subscriber] appCallbackPush calls:", fakeHost.appCallbackPushCalls());
        console.log("[zero-subscriber] before-callback calls:", fakeHost.beforeCallbackCalls());
        console.log("[zero-subscriber] after-callback calls:", fakeHost.afterCallbackCalls());
        console.log("[zero-subscriber] appCallbackPop calls:", fakeHost.appCallbackPopCalls());

        assertGt(returnedCtx.length, 0, "fork zero-subscriber path unexpectedly reverted");
        assertEq(fakeHost.appCallbackPushCalls(), 0, "zero-pending zero-subscriber path should not reach callbacks");
        assertEq(fakeHost.beforeCallbackCalls(), 0, "zero-pending zero-subscriber path should not reach callbacks");
        assertEq(fakeHost.afterCallbackCalls(), 0, "zero-pending zero-subscriber path should not reach callbacks");
        assertEq(fakeHost.appCallbackPopCalls(), 0, "zero-pending zero-subscriber path should not reach callbacks");
        assertTrue(PUBLIC_ZERO_SUBSCRIBER_ERROR != bytes4(0), "sanity");
    }

    function _assertPush2(bytes memory code, uint256 pc, uint16 value) internal pure {
        assertEq(uint8(code[pc]), 0x61, "expected PUSH2");
        assertEq(_readU16(code, pc + 1), value, "unexpected PUSH2 immediate");
    }

    function _assertPush4(bytes memory code, uint256 pc, bytes4 value) internal pure {
        assertEq(uint8(code[pc]), 0x63, "expected PUSH4");
        assertEq(_readBytes4(code, pc + 1), value, "unexpected PUSH4 immediate");
    }

    function _assertPush32(bytes memory code, uint256 pc, bytes32 value) internal pure {
        assertEq(uint8(code[pc]), 0x7f, "expected PUSH32");
        assertEq(_readBytes32(code, pc + 1), value, "unexpected PUSH32 immediate");
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

    function _readU16(bytes memory data, uint256 offset) internal pure returns (uint16 value) {
        value = (uint16(uint8(data[offset])) << 8) | uint16(uint8(data[offset + 1]));
    }

    function _readBytes4(bytes memory data, uint256 offset) internal pure returns (bytes4 value) {
        assembly {
            value := mload(add(add(data, 0x20), offset))
        }
    }

    function _readBytes32(bytes memory data, uint256 offset) internal pure returns (bytes32 value) {
        assembly {
            value := mload(add(add(data, 0x20), offset))
        }
    }

    function _selectorOf(bytes memory blob) internal pure returns (bytes4 selector) {
        if (blob.length < 4) return bytes4(0);
        assembly {
            selector := mload(add(blob, 0x20))
        }
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

contract FakeHostRecorder38 {
    address public immutable ida;

    uint256 public appCallbackPushCalls;
    uint256 public beforeCallbackCalls;
    uint256 public afterCallbackCalls;
    uint256 public appCallbackPopCalls;

    address public lastPushApp;
    address public lastPushToken;
    address public lastBeforeApp;
    address public lastAfterApp;
    bytes4 public lastBeforeSelector;
    bytes4 public lastAfterSelector;

    constructor(address _ida) {
        ida = _ida;
    }

    function claim(address token, address publisher, uint32 indexId, address subscriber)
        external
        returns (bytes memory)
    {
        return IIDAClaim38(ida).claim(token, publisher, indexId, subscriber, _ctx());
    }

    function claimZeroSubscriber(address token, address publisher, uint32 indexId)
        external
        returns (bytes memory)
    {
        return IIDAClaim38(ida).claim(token, publisher, indexId, address(0), _ctx());
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

    function appCallbackPush(bytes calldata ctx, address app, uint256, int256, address token)
        external
        returns (bytes memory)
    {
        appCallbackPushCalls++;
        lastPushApp = app;
        lastPushToken = token;
        return ctx;
    }

    function appCallbackPop(bytes calldata ctx, int256) external returns (bytes memory) {
        appCallbackPopCalls++;
        return ctx;
    }

    function callAppBeforeCallback(address app, bytes calldata callData, bool, bytes calldata)
        external
        returns (bytes memory)
    {
        beforeCallbackCalls++;
        lastBeforeApp = app;
        lastBeforeSelector = _selectorFromMemory(callData);
        return abi.encodePacked(uint256(0x38));
    }

    function callAppAfterCallback(address app, bytes calldata callData, bool, bytes calldata ctx)
        external
        returns (bytes memory)
    {
        afterCallbackCalls++;
        lastAfterApp = app;
        lastAfterSelector = _selectorFromMemory(callData);
        return ctx;
    }

    function _selectorFromMemory(bytes calldata data) internal pure returns (bytes4 selector) {
        bytes memory blob = data;
        if (blob.length < 4) return bytes4(0);
        assembly {
            selector := mload(add(blob, 0x20))
        }
    }

    function _ctx() internal pure returns (bytes memory) {
        return abi.encode(
            abi.encode(uint256(1 << 32), uint256(0), address(0), bytes4(0), bytes("")),
            abi.encode(uint256(0), int256(0), address(0), address(0))
        );
    }
}
