// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import "forge-std/console.sol";

interface IIDA {
    function claim(address token, address publisher, uint32 indexId, address subscriber, bytes calldata ctx)
        external returns (bytes memory);
    function updateSubscription(address token, uint32 indexId, address subscriber, uint128 units, bytes calldata ctx)
        external returns (bytes memory);
    function approveSubscription(address token, address publisher, uint32 indexId, bytes calldata ctx)
        external returns (bytes memory);
    function getSubscription(address token, address publisher, uint32 indexId, address subscriber)
        external view returns (bool exist, bool approved, uint128 units, uint256 pendingDistribution);
    function getIndex(address token, address publisher, uint32 indexId)
        external view returns (bool exist, uint128 indexValue, uint128 totalUnitsApproved, uint128 totalUnitsPending);
}

interface ISuperfluidToken {
    function balanceOf(address account) external view returns (uint256);
    function realtimeBalanceOfNow(address account)
        external view returns (int256 availableBalance, uint256 deposit, uint256 owedDeposit, uint256 timestamp);
    function getHost() external view returns (address);
}

/// @dev FakeHost that mimics the Superfluid host interface
contract FakeHostTest {
    address public immutable ida;
    address public immutable superToken;

    constructor(address ida_, address superToken_) {
        ida = ida_;
        superToken = superToken_;
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
        external pure
        returns (uint8, uint8, uint256, address, bytes4, bytes memory, uint256, uint256, int256, address, address)
    {
        return (0, 1, 0, address(0), bytes4(0), "", 0, 0, 0, address(0), address(0));
    }

    function appCallbackPush(bytes calldata, address, uint256, int256, address) external pure returns (bytes memory) {
        return "";
    }

    function appCallbackPop(bytes calldata, int256) external pure returns (bytes memory) {
        return "";
    }

    function callAppBeforeCallback(address, bytes calldata, bool, bytes calldata) external pure returns (bytes memory) {
        return "";
    }

    function callAppAfterCallback(address, bytes calldata, bool, bytes calldata ctx) external pure returns (bytes memory) {
        return ctx;
    }

    function _blankCtx() internal pure returns (bytes memory) {
        return abi.encode(
            abi.encode(uint256(1 << 32), uint256(0), address(0), bytes4(0), bytes("")),
            abi.encode(uint256(0), int256(0), address(0), address(0))
        );
    }

    /// @notice Try to call claim on an existing subscription
    function tryClaim(address publisher, uint32 indexId, address subscriber) external returns (bool success, bytes memory ret) {
        (success, ret) = ida.call(
            abi.encodeWithSelector(
                IIDA.claim.selector,
                superToken, publisher, indexId, subscriber, _blankCtx()
            )
        );
    }

    /// @notice Try to call updateSubscription
    function tryUpdateSubscription(uint32 indexId, address subscriber, uint128 units) external returns (bool success, bytes memory ret) {
        (success, ret) = ida.call(
            abi.encodeWithSelector(
                IIDA.updateSubscription.selector,
                superToken, indexId, subscriber, units, _blankCtx()
            )
        );
    }

    /// @notice Try to call approveSubscription
    function tryApproveSubscription(address publisher, uint32 indexId) external returns (bool success, bytes memory ret) {
        (success, ret) = ida.call(
            abi.encodeWithSelector(
                IIDA.approveSubscription.selector,
                superToken, publisher, indexId, _blankCtx()
            )
        );
    }

    receive() external payable {}
}


contract FakeHostExistingSubTest is Test {
    address constant IDA    = 0xB0aABBA4B2783A72C52956CDEF62d438ecA2d7a1;
    address constant MATICX = 0x3aD736904E9e65189c3000c7DD2c8AC8bB7cD4e3;
    address constant HOST   = 0x3E14dC1b13c488a8d5D310918780c983bD5982E7;

    // A live pending subscription (MATICx)
    address constant LIVE_PUBLISHER  = 0x87588653F2F840Bf0589d5715679Db77d8fC021d;
    uint32  constant LIVE_INDEX_ID   = 1;
    address constant LIVE_SUBSCRIBER = 0x9C6B5FdC145912dfe6eE13A667aF3C5Eb07CbB89;

    FakeHostTest fakeHost;

    function setUp() public {
        fakeHost = new FakeHostTest(IDA, MATICX);
    }

    /// @notice Test 1: Verify the live subscription exists and has pending
    function test_01_liveSubscriptionExists() public view {
        (bool exist, bool approved, uint128 units, uint256 pending) =
            IIDA(IDA).getSubscription(MATICX, LIVE_PUBLISHER, LIVE_INDEX_ID, LIVE_SUBSCRIBER);

        console.log("Exists:", exist);
        console.log("Approved:", approved);
        console.log("Units:", units);
        console.log("Pending:", pending);

        assertTrue(exist, "subscription should exist");
        assertFalse(approved, "subscription should NOT be approved (claimable)");
        assertTrue(units > 0, "should have units");
        assertTrue(pending > 0, "should have pending distribution");
    }

    /// @notice Test 2: FakeHost can call claim directly (no host check in on-chain bytecode)
    function test_02_fakeHostCanCallClaim() public {
        // Get subscriber balance before
        (int256 balBefore,,,) = ISuperfluidToken(MATICX).realtimeBalanceOfNow(LIVE_SUBSCRIBER);
        console.log("Subscriber balance before (signed):", balBefore > 0 ? uint256(balBefore) : 0);

        // Try claim via FakeHost
        (bool success, bytes memory ret) = fakeHost.tryClaim(LIVE_PUBLISHER, LIVE_INDEX_ID, LIVE_SUBSCRIBER);
        console.log("Claim success:", success);
        if (!success) {
            console.log("Claim revert data length:", ret.length);
            if (ret.length >= 4) {
                console.logBytes4(bytes4(ret));
            }
        }

        // Get subscriber balance after
        (int256 balAfter,,,) = ISuperfluidToken(MATICX).realtimeBalanceOfNow(LIVE_SUBSCRIBER);
        console.log("Subscriber balance after (signed):", balAfter > 0 ? uint256(balAfter) : 0);

        if (success) {
            console.log("CRITICAL: FakeHost CAN claim on existing subscriptions!");
            console.log("Delta to subscriber:", balAfter > balBefore ? uint256(balAfter - balBefore) : 0);
        }
    }

    /// @notice Test 3: FakeHost CANNOT call updateSubscription (host check blocks it)
    function test_03_fakeHostCannotUpdateSubscription() public {
        (bool success, bytes memory ret) = fakeHost.tryUpdateSubscription(0, address(this), 1);
        console.log("updateSubscription success:", success);
        assertFalse(success, "updateSubscription should fail with unauthorized host");
        // Decode error string
        if (ret.length > 4) {
            console.log("Revert data length:", ret.length);
            console.logBytes(ret);
        }
    }

    /// @notice Test 4: FakeHost CANNOT call approveSubscription
    function test_04_fakeHostCannotApproveSubscription() public {
        (bool success, bytes memory ret) = fakeHost.tryApproveSubscription(LIVE_PUBLISHER, LIVE_INDEX_ID);
        console.log("approveSubscription success:", success);
        assertFalse(success, "approveSubscription should fail with unauthorized host");
    }

    /// @notice Test 5: Can we claim with ATTACKER as subscriber? Should fail - no subscription exists
    function test_05_claimWithAttackerAsSubscriber() public {
        address attacker = address(0xBEEF);
        (bool success, bytes memory ret) = fakeHost.tryClaim(LIVE_PUBLISHER, LIVE_INDEX_ID, attacker);
        console.log("Claim with attacker as subscriber success:", success);
        assertFalse(success, "should fail because attacker has no subscription");
    }

    /// @notice Test 6: Verify claim on existing sub sends funds to SUBSCRIBER not caller
    function test_06_claimFundsGoToSubscriberNotCaller() public {
        (int256 subscriberBefore,,,) = ISuperfluidToken(MATICX).realtimeBalanceOfNow(LIVE_SUBSCRIBER);
        (int256 fakeHostBefore,,,) = ISuperfluidToken(MATICX).realtimeBalanceOfNow(address(fakeHost));

        uint256 publisherBalBefore = ISuperfluidToken(MATICX).balanceOf(LIVE_PUBLISHER);

        console.log("--- Before claim ---");
        console.log("Subscriber realtime bal:", subscriberBefore > 0 ? uint256(subscriberBefore) : 0);
        console.log("FakeHost realtime bal:", fakeHostBefore > 0 ? uint256(fakeHostBefore) : 0);
        console.log("Publisher ERC20 bal:", publisherBalBefore);

        (bool success,) = fakeHost.tryClaim(LIVE_PUBLISHER, LIVE_INDEX_ID, LIVE_SUBSCRIBER);

        if (success) {
            (int256 subscriberAfter,,,) = ISuperfluidToken(MATICX).realtimeBalanceOfNow(LIVE_SUBSCRIBER);
            (int256 fakeHostAfter,,,) = ISuperfluidToken(MATICX).realtimeBalanceOfNow(address(fakeHost));

            console.log("--- After claim ---");
            console.log("Subscriber realtime bal:", subscriberAfter > 0 ? uint256(subscriberAfter) : 0);
            console.log("FakeHost realtime bal:", fakeHostAfter > 0 ? uint256(fakeHostAfter) : 0);

            int256 subscriberDelta = subscriberAfter - subscriberBefore;
            int256 fakeHostDelta = fakeHostAfter - fakeHostBefore;

            console.log("Subscriber delta:", subscriberDelta > 0 ? uint256(subscriberDelta) : 0);
            console.log("FakeHost delta:", fakeHostDelta > 0 ? uint256(fakeHostDelta) : 0);

            assertTrue(subscriberDelta > 0, "subscriber should receive funds");
            assertEq(fakeHostDelta, 0, "fakeHost should NOT receive funds");
        } else {
            console.log("Claim failed - cannot test fund flow");
        }
    }
}
