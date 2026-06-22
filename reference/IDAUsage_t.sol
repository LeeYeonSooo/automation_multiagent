// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import { ContextUtils } from "./ContextUtils.sol";

// ─────────────────────────────────────────────────────────────────────────────
// Minimal Superfluid interfaces (just enough for the IDA happy-path demo)
// ─────────────────────────────────────────────────────────────────────────────

interface ISuperAgreement {}

interface ISuperToken {
    function balanceOf(address account) external view returns (uint256);
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
}

interface ISETH is ISuperToken {
    function upgradeByETH() external payable;
    function downgradeToETH(uint256 wad) external;
}

interface ISuperfluid {
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

    function updateIndex(
        ISuperToken token,
        uint32 indexId,
        uint128 indexValue,
        bytes calldata ctx
    ) external returns (bytes memory newCtx);

    function distribute(
        ISuperToken token,
        uint32 indexId,
        uint256 amount,
        bytes calldata ctx
    ) external returns (bytes memory newCtx);

    function approveSubscription(
        ISuperToken token,
        address publisher,
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

    function claim(
        ISuperToken token,
        address publisher,
        uint32 indexId,
        address subscriber,
        bytes calldata ctx
    ) external returns (bytes memory newCtx);

    function getIndex(ISuperToken token, address publisher, uint32 indexId)
        external view
        returns (
            bool exist,
            uint128 indexValue,
            uint128 totalUnitsApproved,
            uint128 totalUnitsPending
        );

    function getSubscription(
        ISuperToken token,
        address publisher,
        uint32 indexId,
        address subscriber
    ) external view
        returns (
            bool exist,
            bool approved,
            uint128 units,
            uint256 pendingDistribution
        );
}

/// @title  IDA happy-path demo via Superfluid `callAgreement`
/// @notice Fork: Polygon @ block 24,684,651 (Feb-2022-era, pre-hack state).
///         Walks through the canonical publisher/subscriber flow using MATICx
///         (native super-token wrapper) so the test is self-funded via `vm.deal`.
///
///         Flow:
///           1. Publisher wraps MATIC → MATICx (upgradeByETH).
///           2. Publisher creates an IDA index (createIndex).
///           3. Publisher issues units:  Alice 100, Bob 300  (updateSubscription).
///           4. Alice approves her subscription (auto-credit on distribute).
///              Bob does NOT approve (must claim manually).
///           5. Publisher distributes 4 MATICx pro-rata (distribute).
///           6. Assert: Alice received 1 MATICx automatically,
///                      Bob has 3 MATICx pending until he claims.
///           7. Bob calls claim → balance materialises.
contract IDAUsageTest is Test {
    // ── Polygon mainnet addresses (sourced from packages/metadata/networks.json) ──
    ISuperfluid                       constant HOST  = ISuperfluid(0x3E14dC1b13c488a8d5D310918780c983bD5982E7);
    IInstantDistributionAgreementV1   constant IDA   = IInstantDistributionAgreementV1(0xB0aABBA4B2783A72C52956CDEF62d438ecA2d7a1);
    ISETH                             constant MATICX= ISETH(0x3aD736904E9e65189c3000c7DD2c8AC8bB7cD4e3);

    address publisher = makeAddr("publisher");
    address alice     = makeAddr("alice");
    address bob       = makeAddr("bob");

    uint32 constant INDEX_ID = 42;

    function setUp() public {
        vm.createSelectFork("polygon", 24_684_651);
        vm.deal(publisher, 20 ether); // 20 MATIC to wrap
    }

    // ─────────────────────────────────────────────────────────────────────
    // Helper: every IDA call is `HOST.callAgreement(IDA, encodedCall, "")`
    // Note the `new bytes(0)` placeholder where the Host will splice in ctx.
    // ─────────────────────────────────────────────────────────────────────
    function _call(bytes memory callData) internal {
        HOST.callAgreement(IDA, callData, new bytes(0));
    }

    function test_IDA_CreateDistributeClaim() public {
        // 1. Wrap native MATIC → MATICx so the publisher has something to distribute
        vm.prank(publisher);
        MATICX.upgradeByETH{ value: 10 ether }();
        uint256 pubBal0 = MATICX.balanceOf(publisher);
        assertEq(pubBal0, 10 ether, "publisher should hold 10 MATICx after wrap");
        console.log("[1] publisher wrapped 10 MATIC -> MATICx:", pubBal0);

        // 2. createIndex — publisher opens a distribution channel
        vm.prank(publisher);
        _call(abi.encodeCall(IDA.createIndex, (MATICX, INDEX_ID, new bytes(0))));
        (bool exists,,,) = IDA.getIndex(MATICX, publisher, INDEX_ID);
        assertTrue(exists, "index not created");
        console.log("[2] index created, id =", INDEX_ID);

        // 3. updateSubscription — issue units (shares)
        vm.startPrank(publisher);
        _call(abi.encodeCall(IDA.updateSubscription, (MATICX, INDEX_ID, alice, 100, new bytes(0))));
        _call(abi.encodeCall(IDA.updateSubscription, (MATICX, INDEX_ID, bob,   300, new bytes(0))));
        vm.stopPrank();
        console.log("[3] issued units: alice=100, bob=300 (total 400)");

        // 4. alice approves her subscription (so distribute credits her directly).
        //    bob stays un-approved so we can demonstrate `claim()` later.
        vm.prank(alice);
        _call(abi.encodeCall(IDA.approveSubscription, (MATICX, publisher, INDEX_ID, new bytes(0))));
        console.log("[4] alice approved subscription; bob did NOT");

        // 5. distribute 4 MATICx:  alice gets 100/400 = 1,  bob gets 300/400 = 3
        vm.prank(publisher);
        _call(abi.encodeCall(IDA.distribute, (MATICX, INDEX_ID, 4 ether, new bytes(0))));
        console.log("[5] distributed 4 MATICx pro-rata");

        // 6. Alice (approved) balance went up instantly
        uint256 aliceBal = MATICX.balanceOf(alice);
        assertEq(aliceBal, 1 ether, "alice should have 1 MATICx auto-credited");
        console.log("    alice MATICx balance :", aliceBal);

        // Bob (un-approved) has 0 balance but 3 MATICx pending
        uint256 bobBalPre = MATICX.balanceOf(bob);
        assertEq(bobBalPre, 0, "bob should hold 0 MATICx before claim");
        ( , , , uint256 pending) = IDA.getSubscription(MATICX, publisher, INDEX_ID, bob);
        assertEq(pending, 3 ether, "bob pendingDistribution should be 3 MATICx");
        console.log("    bob MATICx balance   :", bobBalPre, "(pending:)", pending);

        // 7. Bob claims — anyone can call claim for a subscriber; we have him do it himself
        vm.prank(bob);
        _call(abi.encodeCall(IDA.claim, (MATICX, publisher, INDEX_ID, bob, new bytes(0))));
        uint256 bobBalPost = MATICX.balanceOf(bob);
        assertEq(bobBalPost, 3 ether, "bob should have 3 MATICx after claim");
        console.log("[6] bob claimed; final MATICx balance:", bobBalPost);

        // Publisher spent exactly 4 MATICx on the distribution
        assertEq(MATICX.balanceOf(publisher), 6 ether, "publisher balance should be 6 MATICx after distribute");
        console.log("[7] publisher MATICx remaining       :", MATICX.balanceOf(publisher));
    }

    // ─────────────────────────────────────────────────────────────────────
    // Negative cases: bob has NO MATICx.  Publisher-role actions must fail.
    //
    // Setup mirrors the happy-path test except *no units are issued to bob*.
    // We still have bob call `claim` (as requested) to show it reverts because
    // he was never added as a subscriber.  Then bob tries to replicate every
    // publisher-side action on an index of his own — the on-chain economics
    // forbid it because he holds zero of the distributed super-token.
    // ─────────────────────────────────────────────────────────────────────
    function test_IDA_BobFailsWithoutTokens() public {
        // ── Publisher builds an index with Alice ONLY (Bob gets nothing) ──
        vm.prank(publisher);
        MATICX.upgradeByETH{ value: 10 ether }();

        vm.startPrank(publisher);
        _call(abi.encodeCall(IDA.createIndex,        (MATICX, INDEX_ID, new bytes(0))));
        _call(abi.encodeCall(IDA.updateSubscription, (MATICX, INDEX_ID, alice, 100, new bytes(0))));
        vm.stopPrank();

        vm.prank(alice);
        _call(abi.encodeCall(IDA.approveSubscription, (MATICX, publisher, INDEX_ID, new bytes(0))));

        vm.prank(publisher);
        _call(abi.encodeCall(IDA.distribute, (MATICX, INDEX_ID, 4 ether, new bytes(0))));

        // Sanity: alice captured the whole pie (she owns 100% of the units issued);
        //        bob holds nothing going into the failure cases.
        assertEq(MATICX.balanceOf(alice), 4 ether);
        assertEq(MATICX.balanceOf(bob),   0, "bob must start empty");
        console.log("[pre] alice:", MATICX.balanceOf(alice), " bob:", MATICX.balanceOf(bob));

        // ── (1) bob claim — he was never made a subscriber → revert ──
        vm.prank(bob);
        vm.expectRevert();      // IDA: E_SUBSCRIPTION_DOES_NOT_EXIST
        _call(abi.encodeCall(IDA.claim, (MATICX, publisher, INDEX_ID, bob, new bytes(0))));
        console.log("[1] bob.claim on publisher's index -> reverted (no subscription)");

        // ── bob spins up his own publisher setup to mimic the happy path ──
        // createIndex and updateSubscription don't move tokens, so they succeed
        // even when bob is broke.  The failure hits at settlement time.
        vm.startPrank(bob);
        _call(abi.encodeCall(IDA.createIndex,        (MATICX, INDEX_ID, new bytes(0))));
        _call(abi.encodeCall(IDA.updateSubscription, (MATICX, INDEX_ID, alice, 100, new bytes(0))));
        vm.stopPrank();
        console.log("[2] bob created his own index + allocated 100 units to alice (no tokens moved yet)");

        // ── (3) bob distribute — needs actual balance to push out → revert ──
        vm.prank(bob);
        vm.expectRevert();      // SuperToken: SF_IDA_INSUFFICIENT_BALANCE
        _call(abi.encodeCall(IDA.distribute, (MATICX, INDEX_ID, 4 ether, new bytes(0))));
        console.log("[3] bob.distribute(4e18) -> reverted (bob MATICx balance = 0)");

        // ── (4) bob updateIndex — same story, the bump implies an obligation
        //       of  indexDelta * totalUnits  MATICx that bob cannot cover → revert
        vm.prank(bob);
        vm.expectRevert();
        _call(abi.encodeCall(IDA.updateIndex, (MATICX, INDEX_ID, uint128(1e16), new bytes(0))));
        console.log("[4] bob.updateIndex(1e16) -> reverted (insufficient balance)");

        // Invariant: every failed attempt left bob's wallet untouched.
        assertEq(MATICX.balanceOf(bob), 0, "bob still holds 0 MATICx after failures");
        // Publisher's pot is unchanged too — none of bob's reverts leaked state.
        assertEq(MATICX.balanceOf(publisher), 6 ether, "publisher balance should be unchanged by bob's reverts");
    }

    // ─────────────────────────────────────────────────────────────────────
    // Shows the alternative index-style distribution: updateIndex sets the
    // cumulative indexValue directly (scaled per unit).  This is what
    // protocols use for streaming rewards that grow monotonically.
    // ─────────────────────────────────────────────────────────────────────
    function test_IDA_UpdateIndexAlternative() public {
        vm.prank(publisher);
        MATICX.upgradeByETH{ value: 5 ether }();

        vm.startPrank(publisher);
        _call(abi.encodeCall(IDA.createIndex, (MATICX, INDEX_ID, new bytes(0))));
        _call(abi.encodeCall(IDA.updateSubscription, (MATICX, INDEX_ID, alice, 100, new bytes(0))));
        vm.stopPrank();

        vm.prank(alice);
        _call(abi.encodeCall(IDA.approveSubscription, (MATICX, publisher, INDEX_ID, new bytes(0))));

        // updateIndex bumps indexValue from 0 → 1e16.
        // payout = (indexValue - lastIndexValue) * units
        //        = (1e16 - 0) * 100 = 1e18 = 1 MATICx to alice
        vm.prank(publisher);
        _call(abi.encodeCall(IDA.updateIndex, (MATICX, INDEX_ID, uint128(1e16), new bytes(0))));

        assertEq(MATICX.balanceOf(alice), 1 ether, "alice should receive 1 MATICx via index bump");
        console.log("updateIndex(1e16) paid alice:", MATICX.balanceOf(alice));
    }

    // ─────────────────────────────────────────────────────────────────────
    // Demonstrates ContextUtils.buildContext / encodeContext / decodeContext.
    // Builds a Context that looks exactly like what the Host would splice in
    // for a top-level `callAgreement(IDA.createIndex, ...)` call, packs it,
    // then decodes it and checks every field round-trips.
    // ─────────────────────────────────────────────────────────────────────
    function test_BuildAndPackContext() public view {
        bytes4 selector = IDA.createIndex.selector;
        bytes memory userData = abi.encode("example-metadata", uint256(123));

        // 1. Build the struct the way Superfluid._callAgreement would at top-level:
        //    appCallbackLevel=0, callType=AGREEMENT, timestamp=block.timestamp,
        //    msgSender = original caller, agreementSelector = function being invoked.
        ContextUtils.Context memory ctx =
            ContextUtils.buildContext(publisher, selector, userData);

        // 2. Pack to bytes using the double-encoding layout of _updateContext.
        bytes memory packed = ContextUtils.encodeContext(ctx);
        bytes32 stamp       = ContextUtils.stamp(packed);

        console.log("packed ctx length :", packed.length);
        console.log("ctx stamp (keccak256):");
        console.logBytes32(stamp);

        // 3. Round-trip: decode and verify every field.
        ContextUtils.Context memory back = ContextUtils.decodeContext(packed);
        assertEq(back.appCallbackLevel,          ctx.appCallbackLevel);
        assertEq(back.callType,                  ctx.callType);
        assertEq(back.timestamp,                 ctx.timestamp);
        assertEq(back.msgSender,                 ctx.msgSender);
        assertEq(back.agreementSelector,         ctx.agreementSelector);
        assertEq(back.userData,                  ctx.userData);
        assertEq(back.appCreditGranted,          ctx.appCreditGranted);
        assertEq(back.appCreditWantedDeprecated, ctx.appCreditWantedDeprecated);
        assertEq(back.appCreditUsed,             ctx.appCreditUsed);
        assertEq(back.appAddress,                ctx.appAddress);
        assertEq(back.appCreditToken,            ctx.appCreditToken);

        // 4. The outer layout is literally `abi.encode(bytes, bytes)` — prove it
        //    by decoding the outer envelope independently.
        (bytes memory ctx1, bytes memory ctx2) = abi.decode(packed, (bytes, bytes));
        assertGt(ctx1.length, 0);
        assertGt(ctx2.length, 0);

        // 5. Inner block 1 encodes exactly 5 fields in order.
        (
            uint256 callInfo,
            uint256 ts,
            address sender,
            bytes4  sel,
            bytes memory ud
        ) = abi.decode(ctx1, (uint256, uint256, address, bytes4, bytes));
        (uint8 lvl, uint8 ct) = ContextUtils.decodeCallInfo(callInfo);
        assertEq(lvl, 0);
        assertEq(ct,  ContextUtils.CALL_TYPE_AGREEMENT);
        assertEq(ts,  block.timestamp);
        assertEq(sender, publisher);
        assertEq(sel,    selector);
        assertEq(ud,     userData);
        console.log("[ok] ctx1 round-trip: lvl=0, callType=AGREEMENT, sender=publisher");

        // 6. Inner block 2 encodes the credit-related fields.
        (
            uint256 creditIO,
            int256  creditUsed,
            address appAddr,
            address creditToken
        ) = abi.decode(ctx2, (uint256, int256, address, address));
        assertEq(creditIO,    0);
        assertEq(creditUsed,  0);
        assertEq(appAddr,     address(0));
        assertEq(creditToken, address(0));
        console.log("[ok] ctx2 round-trip: all credit fields zero (top-level call)");
    }
}
