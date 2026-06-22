// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";

interface ISuperAgreement {}

interface ISuperfluidHost {
    function callAgreement(
        ISuperAgreement agreementClass,
        bytes calldata callData,
        bytes calldata userData
    ) external returns (bytes memory returnedData);
}

interface IInstantDistributionAgreementV1 is ISuperAgreement {
    function createIndex(address token, uint32 indexId, bytes calldata ctx) external returns (bytes memory newCtx);

    function updateSubscription(
        address token,
        uint32 indexId,
        address subscriber,
        uint128 units,
        bytes calldata ctx
    ) external returns (bytes memory newCtx);

    function distribute(
        address token,
        uint32 indexId,
        uint256 amount,
        bytes calldata ctx
    ) external returns (bytes memory newCtx);

    function approveSubscription(
        address token,
        address publisher,
        uint32 indexId,
        bytes calldata ctx
    ) external returns (bytes memory newCtx);

    function claim(
        address token,
        address publisher,
        uint32 indexId,
        address subscriber,
        bytes calldata ctx
    ) external returns (bytes memory newCtx);

    function getSubscription(
        address token,
        address publisher,
        uint32 indexId,
        address subscriber
    ) external view returns (bool exist, bool approved, uint128 units, uint256 pendingDistribution);
}

interface ISuperTokenLike {
    function balanceOf(address account) external view returns (uint256);

    function realtimeBalanceOfNow(address account)
        external
        view
        returns (int256 availableBalance, uint256 deposit, uint256 owedDeposit, uint256 timestamp);
}

interface IMATICxLike is ISuperTokenLike {
    function upgradeByETH() external payable;
}

interface IREXPublisherLike {
    function owner() external view returns (address);
}

/// @title Attempt33
/// @notice Diagnostic POC for the surviving ch5 `claim()` path.
/// @dev This intentionally uses only normal host-mediated IDA calls copied from
///      the `reference/IDAUsage_t.sol` happy-path shape:
///      `HOST.callAgreement(IDA, abi.encodeCall(...), "")`.
/// @dev The concrete checks requested for this attempt are:
///      1. replay the live `MATICx / publisher=0xcaB... / indexId=1 /
///         subscriber=0x9C6B...` claim with no ctx forgery and trace the exact
///         publisher/subscriber balance deltas,
///      2. verify the full live pending-subscription corpus on the fork
///         (59 tuples, 7 tokens, total pending
///         36_356_939_490_036_657_835_928),
///      3. prove the attacker is not already the subscriber on any live pending
///         tuple,
///      4. test the `approveSubscription` branches directly:
///         - pre-approved subscriber path keeps pending at zero and auto-credits
///           future distributions,
///         - late approval after a prior distribution materializes the already
///           pending balance immediately.
contract Attempt33 is Test {
    uint256 internal constant FORK_BLOCK = 27_039_967;

    address internal constant ATTACKER = 0xc943eDB4Bb4439d65B81f2f60Bc698411e910B14;

    address internal constant HOST_ADDR = 0x3E14dC1b13c488a8d5D310918780c983bD5982E7;
    address internal constant IDA_ADDR = 0xB0aABBA4B2783A72C52956CDEF62d438ecA2d7a1;

    address internal constant SDTX = 0x12c294107772b10815307c05989DABD71C21670e;
    address internal constant DAIX = 0x1305F6B6Df9Dc47159D12Eb7aC2804d4A33173c2;
    address internal constant ETHX = 0x27e1e4E6BC79D93032abef01025811B7E4727e85;
    address internal constant RIC = 0x263026E7e53DBFDce5ae55Ade22493f828922965;
    address internal constant MATICX_ADDR = 0x3aD736904E9e65189c3000c7DD2c8AC8bB7cD4e3;
    address internal constant WBTCX = 0x4086eBf75233e8492F1BCDa41C7f2A8288c2fB92;
    address internal constant USDCX = 0xCAa7349CEA390F89641fe306D93591f87595dc1F;

    address internal constant LIVE_REX_PUBLISHER = 0xcaB28480ab5c1E133e9B7FC67E030B8DCC2A1d24;
    address internal constant LIVE_REX_OWNER_SAFE = 0x9C6B5FdC145912dfe6eE13A667aF3C5Eb07CbB89;
    uint32 internal constant LIVE_MATICX_INDEX_ID = 1;
    uint256 internal constant LIVE_MATICX_PENDING = 89_179_336_596_046_560;

    uint256 internal constant TOTAL_PENDING_ROWS = 59;
    uint256 internal constant TOTAL_PENDING_SUM = 36_356_939_490_036_657_835_928;

    uint256 internal constant RIC_COUNT = 20;
    uint256 internal constant SDTX_COUNT = 2;
    uint256 internal constant USDCX_COUNT = 15;
    uint256 internal constant DAIX_COUNT = 4;
    uint256 internal constant MATICX_COUNT = 2;
    uint256 internal constant ETHX_COUNT = 11;
    uint256 internal constant WBTCX_COUNT = 5;

    uint256 internal constant RIC_SUM = 34_781_935_781_605_553_324_634;
    uint256 internal constant SDTX_SUM = 1_400_000_000_000_000_000_000;
    uint256 internal constant USDCX_SUM = 171_763_035_701_367_575_420;
    uint256 internal constant DAIX_SUM = 2_700_116_693_388_961_684;
    uint256 internal constant MATICX_SUM = 509_316_434_636_141_380;
    uint256 internal constant ETHX_SUM = 31_205_741_295_043_458;
    uint256 internal constant WBTCX_SUM = 33_860_416_789_352;

    uint32 internal constant EARLY_APPROVE_INDEX_ID = 10_001;
    uint32 internal constant LATE_APPROVE_INDEX_ID = 10_002;

    ISuperfluidHost internal constant HOST = ISuperfluidHost(HOST_ADDR);
    IInstantDistributionAgreementV1 internal constant IDA = IInstantDistributionAgreementV1(IDA_ADDR);
    IMATICxLike internal constant MATICX = IMATICxLike(MATICX_ADDR);

    struct Snapshot {
        int256 availableBalance;
        uint256 deposit;
        uint256 owedDeposit;
        uint256 timestamp;
        uint256 erc20Balance;
    }

    struct PendingRow {
        address token;
        address publisher;
        uint32 indexId;
        address subscriber;
        uint128 units;
        uint256 pending;
    }

    function setUp() public {
        vm.createSelectFork("ch5", FORK_BLOCK);

        vm.label(ATTACKER, "Attacker");
        vm.label(HOST_ADDR, "SuperfluidHost");
        vm.label(IDA_ADDR, "IDA");
        vm.label(SDTX, "SDTx");
        vm.label(DAIX, "DAIx");
        vm.label(ETHX, "ETHx");
        vm.label(RIC, "RIC");
        vm.label(MATICX_ADDR, "MATICx");
        vm.label(WBTCX, "WBTCx");
        vm.label(USDCX, "USDCx");
        vm.label(LIVE_REX_PUBLISHER, "LiveREXPublisher");
        vm.label(LIVE_REX_OWNER_SAFE, "LiveREXOwnerSafe");
    }

    function test_live_claim_pays_rex_owner_safe_and_not_the_publisher() public {
        assertEq(IREXPublisherLike(LIVE_REX_PUBLISHER).owner(), LIVE_REX_OWNER_SAFE, "live owner chain changed");

        uint256 attackerNativeBefore = ATTACKER.balance;
        Snapshot memory publisherBefore = _snapshot(MATICX_ADDR, LIVE_REX_PUBLISHER);
        Snapshot memory subscriberBefore = _snapshot(MATICX_ADDR, LIVE_REX_OWNER_SAFE);
        (bool exist, bool approved, uint128 units, uint256 pendingBefore) =
            IDA.getSubscription(MATICX_ADDR, LIVE_REX_PUBLISHER, LIVE_MATICX_INDEX_ID, LIVE_REX_OWNER_SAFE);

        console.log("[live claim] publisher:", LIVE_REX_PUBLISHER);
        console.log("[live claim] subscriber(owner safe):", LIVE_REX_OWNER_SAFE);
        console.log("[live claim] indexId:", LIVE_MATICX_INDEX_ID);
        console.log("[live claim] units:", uint256(units));
        console.log("[live claim] pending before:", pendingBefore);
        _logSnapshot("publisher before", publisherBefore);
        _logSnapshot("subscriber before", subscriberBefore);

        assertTrue(exist, "live tuple must exist");
        assertFalse(approved, "live tuple must stay unapproved before claim");
        assertEq(pendingBefore, LIVE_MATICX_PENDING, "unexpected live pending value");

        vm.prank(ATTACKER);
        _hostCall(abi.encodeCall(IDA.claim, (MATICX_ADDR, LIVE_REX_PUBLISHER, LIVE_MATICX_INDEX_ID, LIVE_REX_OWNER_SAFE, new bytes(0))));

        Snapshot memory publisherAfter = _snapshot(MATICX_ADDR, LIVE_REX_PUBLISHER);
        Snapshot memory subscriberAfter = _snapshot(MATICX_ADDR, LIVE_REX_OWNER_SAFE);
        (, bool approvedAfter,, uint256 pendingAfter) =
            IDA.getSubscription(MATICX_ADDR, LIVE_REX_PUBLISHER, LIVE_MATICX_INDEX_ID, LIVE_REX_OWNER_SAFE);

        uint256 publisherErc20Delta = publisherAfter.erc20Balance - publisherBefore.erc20Balance;
        uint256 subscriberErc20Delta = subscriberAfter.erc20Balance - subscriberBefore.erc20Balance;

        console.log("[live claim] pending after:", pendingAfter);
        _logSnapshot("publisher after", publisherAfter);
        _logSnapshot("subscriber after", subscriberAfter);
        console.log("[live claim] publisher ERC20 delta:", publisherErc20Delta);
        console.log("[live claim] subscriber ERC20 delta:", subscriberErc20Delta);
        console.log("[live claim] attacker native before:", attackerNativeBefore);
        console.log("[live claim] attacker native after :", ATTACKER.balance);

        assertFalse(approvedAfter, "claim should not silently approve the live subscription");
        assertEq(pendingAfter, 0, "claim should fully clear the pending distribution");
        assertEq(subscriberErc20Delta, pendingBefore, "the owner safe should receive the pending MATICx");

        assertEq(publisherErc20Delta, 0, "publisher ERC20-visible balance should stay flat");
        assertEq(
            publisherAfter.availableBalance,
            publisherBefore.availableBalance,
            "publisher spendable realtime balance should stay flat"
        );
        assertEq(
            publisherBefore.deposit - publisherAfter.deposit,
            pendingBefore,
            "publisher deposit should release exactly the claimed amount"
        );
        assertEq(ATTACKER.balance, attackerNativeBefore, "diagnostic claim should not change attacker native balance");
    }

    function test_enumerate_all_live_pending_subscriptions_and_confirm_no_attacker_subscriber_path() public {
        PendingRow[] memory rows = _livePendingRows();

        uint256 totalPending;
        uint256 safeSubscriberRows;
        uint256 attackerSubscriberRows;

        uint256 ricCount;
        uint256 sdtxCount;
        uint256 usdcxCount;
        uint256 daixCount;
        uint256 maticxCount;
        uint256 ethxCount;
        uint256 wbtcxCount;

        uint256 ricSum;
        uint256 sdtxSum;
        uint256 usdcxSum;
        uint256 daixSum;
        uint256 maticxSum;
        uint256 ethxSum;
        uint256 wbtcxSum;

        for (uint256 i = 0; i < rows.length; ++i) {
            PendingRow memory row = rows[i];
            (bool exist, bool approved, uint128 units, uint256 pendingDistribution) =
                IDA.getSubscription(row.token, row.publisher, row.indexId, row.subscriber);

            assertTrue(exist, "snapshot tuple disappeared");
            assertFalse(approved, "snapshot tuple should still be unapproved");
            assertEq(units, row.units, "snapshot units drifted");
            assertEq(pendingDistribution, row.pending, "snapshot pending drifted");

            totalPending += pendingDistribution;

            if (row.subscriber == LIVE_REX_OWNER_SAFE) safeSubscriberRows += 1;
            if (row.subscriber == ATTACKER) attackerSubscriberRows += 1;

            if (row.token == RIC) {
                ricCount += 1;
                ricSum += pendingDistribution;
            } else if (row.token == SDTX) {
                sdtxCount += 1;
                sdtxSum += pendingDistribution;
            } else if (row.token == USDCX) {
                usdcxCount += 1;
                usdcxSum += pendingDistribution;
            } else if (row.token == DAIX) {
                daixCount += 1;
                daixSum += pendingDistribution;
            } else if (row.token == MATICX_ADDR) {
                maticxCount += 1;
                maticxSum += pendingDistribution;
            } else if (row.token == ETHX) {
                ethxCount += 1;
                ethxSum += pendingDistribution;
            } else if (row.token == WBTCX) {
                wbtcxCount += 1;
                wbtcxSum += pendingDistribution;
            } else {
                revert("unexpected token in live pending snapshot");
            }
        }

        console.log("[pending scan] rows:", rows.length);
        console.log("[pending scan] total pending:", totalPending);
        console.log("[pending scan] rows with subscriber=safe:", safeSubscriberRows);
        console.log("[pending scan] rows with subscriber=attacker:", attackerSubscriberRows);

        console.log("[pending scan] RIC  count/sum:", ricCount, ricSum);
        console.log("[pending scan] SDTx count/sum:", sdtxCount, sdtxSum);
        console.log("[pending scan] USDCx count/sum:", usdcxCount, usdcxSum);
        console.log("[pending scan] DAIx count/sum:", daixCount, daixSum);
        console.log("[pending scan] MATICx count/sum:", maticxCount, maticxSum);
        console.log("[pending scan] ETHx count/sum:", ethxCount, ethxSum);
        console.log("[pending scan] WBTCx count/sum:", wbtcxCount, wbtcxSum);

        assertEq(rows.length, TOTAL_PENDING_ROWS, "live pending row count changed");
        assertEq(totalPending, TOTAL_PENDING_SUM, "live pending total changed");
        assertEq(safeSubscriberRows, 22, "safe-row count changed");
        assertEq(attackerSubscriberRows, 0, "attacker is not a subscriber on any live pending tuple");

        assertEq(ricCount, RIC_COUNT, "RIC pending row count changed");
        assertEq(sdtxCount, SDTX_COUNT, "SDTx pending row count changed");
        assertEq(usdcxCount, USDCX_COUNT, "USDCx pending row count changed");
        assertEq(daixCount, DAIX_COUNT, "DAIx pending row count changed");
        assertEq(maticxCount, MATICX_COUNT, "MATICx pending row count changed");
        assertEq(ethxCount, ETHX_COUNT, "ETHx pending row count changed");
        assertEq(wbtcxCount, WBTCX_COUNT, "WBTCx pending row count changed");

        assertEq(ricSum, RIC_SUM, "RIC pending sum changed");
        assertEq(sdtxSum, SDTX_SUM, "SDTx pending sum changed");
        assertEq(usdcxSum, USDCX_SUM, "USDCx pending sum changed");
        assertEq(daixSum, DAIX_SUM, "DAIx pending sum changed");
        assertEq(maticxSum, MATICX_SUM, "MATICx pending sum changed");
        assertEq(ethxSum, ETHX_SUM, "ETHx pending sum changed");
        assertEq(wbtcxSum, WBTCX_SUM, "WBTCx pending sum changed");
    }

    function test_approveSubscription_syncs_current_index_but_late_approval_materializes_existing_pending() public {
        address earlyPublisher = makeAddr("earlyPublisher");
        address futureSubscriber = makeAddr("futureSubscriber");
        address latePublisher = makeAddr("latePublisher");
        address lateSubscriber = makeAddr("lateSubscriber");

        vm.deal(earlyPublisher, 10 ether);
        vm.deal(latePublisher, 10 ether);

        vm.prank(earlyPublisher);
        MATICX.upgradeByETH{value: 5 ether}();

        vm.startPrank(earlyPublisher);
        _hostCall(abi.encodeCall(IDA.createIndex, (MATICX_ADDR, EARLY_APPROVE_INDEX_ID, new bytes(0))));
        vm.stopPrank();

        vm.prank(futureSubscriber);
        _hostCall(abi.encodeCall(IDA.approveSubscription, (MATICX_ADDR, earlyPublisher, EARLY_APPROVE_INDEX_ID, new bytes(0))));

        (bool earlyExist0, bool earlyApproved0, uint128 earlyUnits0, uint256 earlyPending0) =
            IDA.getSubscription(MATICX_ADDR, earlyPublisher, EARLY_APPROVE_INDEX_ID, futureSubscriber);

        console.log("[approve control] early path post-approve exist:", earlyExist0);
        console.log("[approve control] early path post-approve approved:", earlyApproved0);
        console.log("[approve control] early path post-approve units:", uint256(earlyUnits0));
        console.log("[approve control] early path post-approve pending:", earlyPending0);

        assertTrue(earlyExist0, "early approve should create the subscriber record");
        assertTrue(earlyApproved0, "early approve should mark the record approved");
        assertEq(earlyUnits0, 0, "fresh approve should sync to current index with zero units");
        assertEq(earlyPending0, 0, "fresh approve should not create pending");

        vm.prank(earlyPublisher);
        _hostCall(abi.encodeCall(IDA.updateSubscription, (MATICX_ADDR, EARLY_APPROVE_INDEX_ID, futureSubscriber, uint128(100), new bytes(0))));

        (bool earlyExist1, bool earlyApproved1, uint128 earlyUnits1, uint256 earlyPending1) =
            IDA.getSubscription(MATICX_ADDR, earlyPublisher, EARLY_APPROVE_INDEX_ID, futureSubscriber);

        uint256 futureSubscriberBefore = MATICX.balanceOf(futureSubscriber);

        vm.prank(earlyPublisher);
        _hostCall(abi.encodeCall(IDA.distribute, (MATICX_ADDR, EARLY_APPROVE_INDEX_ID, 1 ether, new bytes(0))));

        uint256 futureSubscriberAfter = MATICX.balanceOf(futureSubscriber);
        (, bool earlyApproved2, uint128 earlyUnits2, uint256 earlyPending2) =
            IDA.getSubscription(MATICX_ADDR, earlyPublisher, EARLY_APPROVE_INDEX_ID, futureSubscriber);

        console.log("[approve control] early path units after publisher update:", uint256(earlyUnits1));
        console.log("[approve control] early path pending after publisher update:", earlyPending1);
        console.log("[approve control] early path balance delta after distribute:", futureSubscriberAfter - futureSubscriberBefore);
        console.log("[approve control] early path final pending:", earlyPending2);

        assertTrue(earlyExist1, "subscription should still exist after publisher unit update");
        assertTrue(earlyApproved1, "publisher update should preserve approval");
        assertEq(earlyUnits1, 100, "publisher update should set the approved units");
        assertEq(earlyPending1, 0, "approved subscription should not accrue pending before distribute");
        assertTrue(earlyApproved2, "approved subscription should stay approved after distribute");
        assertEq(earlyUnits2, 100, "approved units should stay constant through distribute");
        assertEq(futureSubscriberAfter - futureSubscriberBefore, 1 ether, "approved subscriber should auto-receive distribute()");
        assertEq(earlyPending2, 0, "approved subscriber should keep pending at zero");

        vm.prank(latePublisher);
        MATICX.upgradeByETH{value: 5 ether}();

        vm.startPrank(latePublisher);
        _hostCall(abi.encodeCall(IDA.createIndex, (MATICX_ADDR, LATE_APPROVE_INDEX_ID, new bytes(0))));
        _hostCall(abi.encodeCall(IDA.updateSubscription, (MATICX_ADDR, LATE_APPROVE_INDEX_ID, lateSubscriber, uint128(100), new bytes(0))));
        _hostCall(abi.encodeCall(IDA.distribute, (MATICX_ADDR, LATE_APPROVE_INDEX_ID, 2 ether, new bytes(0))));
        vm.stopPrank();

        uint256 lateSubscriberBefore = MATICX.balanceOf(lateSubscriber);
        (bool lateExist0, bool lateApproved0, uint128 lateUnits0, uint256 latePending0) =
            IDA.getSubscription(MATICX_ADDR, latePublisher, LATE_APPROVE_INDEX_ID, lateSubscriber);

        console.log("[approve control] late path pre-approve exist:", lateExist0);
        console.log("[approve control] late path pre-approve approved:", lateApproved0);
        console.log("[approve control] late path pre-approve units:", uint256(lateUnits0));
        console.log("[approve control] late path pre-approve pending:", latePending0);

        assertTrue(lateExist0, "late path subscription should exist");
        assertFalse(lateApproved0, "late path must stay unapproved until subscriber acts");
        assertEq(lateUnits0, 100, "late path units mismatch");
        assertEq(latePending0, 2 ether, "late path should accumulate pending before approval");

        vm.prank(lateSubscriber);
        _hostCall(abi.encodeCall(IDA.approveSubscription, (MATICX_ADDR, latePublisher, LATE_APPROVE_INDEX_ID, new bytes(0))));

        uint256 lateSubscriberAfter = MATICX.balanceOf(lateSubscriber);
        (, bool lateApproved1, uint128 lateUnits1, uint256 latePending1) =
            IDA.getSubscription(MATICX_ADDR, latePublisher, LATE_APPROVE_INDEX_ID, lateSubscriber);

        console.log("[approve control] late path balance delta on approve:", lateSubscriberAfter - lateSubscriberBefore);
        console.log("[approve control] late path approved after approve:", lateApproved1);
        console.log("[approve control] late path units after approve:", uint256(lateUnits1));
        console.log("[approve control] late path pending after approve:", latePending1);

        assertTrue(lateApproved1, "late approve should flip the record to approved");
        assertEq(lateUnits1, 100, "late approve should preserve the allocated units");
        assertEq(lateSubscriberAfter - lateSubscriberBefore, 2 ether, "late approve should materialize the old pending amount");
        assertEq(latePending1, 0, "late approve should clear the pending amount");
    }

    function _hostCall(bytes memory callData) internal {
        HOST.callAgreement(IDA, callData, new bytes(0));
    }

    function _snapshot(address token, address account) internal view returns (Snapshot memory snap) {
        (snap.availableBalance, snap.deposit, snap.owedDeposit, snap.timestamp) = ISuperTokenLike(token).realtimeBalanceOfNow(account);
        snap.erc20Balance = ISuperTokenLike(token).balanceOf(account);
    }

    function _logSnapshot(string memory label, Snapshot memory snap) internal pure {
        console.log(label);
        console.logInt(snap.availableBalance);
        console.log("  deposit:", snap.deposit);
        console.log("  owedDeposit:", snap.owedDeposit);
        console.log("  timestamp:", snap.timestamp);
        console.log("  balanceOf:", snap.erc20Balance);
    }

    function _livePendingRows() internal pure returns (PendingRow[] memory rows) {
        rows = new PendingRow[](59);
        rows[0] = PendingRow({token: address(uint160(0x00263026e7e53dbfdce5ae55ade22493f828922965)), publisher: address(uint160(0x005786d3754443c0d3d1ddea5bb550ccc476fdf11d)), indexId: 1, subscriber: address(uint160(0x000251aeb3407fdffef515fc5f9731f010c476a0e6)), units: 3858, pending: 33004232945271142108650});
        rows[1] = PendingRow({token: address(uint160(0x0012c294107772b10815307c05989dabd71c21670e)), publisher: address(uint160(0x00d6fb1f82ff2296b55bddffcce80abde7fbc6c22d)), indexId: 0, subscriber: address(uint160(0x00819c9db8f78d6c7cc1c9e844d53fdab4d8905554)), units: 700, pending: 700000000000000000000});
        rows[2] = PendingRow({token: address(uint160(0x0012c294107772b10815307c05989dabd71c21670e)), publisher: address(uint160(0x00d6fb1f82ff2296b55bddffcce80abde7fbc6c22d)), indexId: 0, subscriber: address(uint160(0x00bacc2d322c4bc33f52c886016129c8c157fca7be)), units: 700, pending: 700000000000000000000});
        rows[3] = PendingRow({token: address(uint160(0x00263026e7e53dbfdce5ae55ade22493f828922965)), publisher: address(uint160(0x00cab28480ab5c1e133e9b7fc67e030b8dcc2a1d24)), indexId: 3, subscriber: address(uint160(0x0066177bdec367f638be98e53d1493ee043d20b4a2)), units: 3288880, pending: 524411409360645565920});
        rows[4] = PendingRow({token: address(uint160(0x00263026e7e53dbfdce5ae55ade22493f828922965)), publisher: address(uint160(0x00e0073786618b886aa1aa44df103850a227ade9ae)), indexId: 3, subscriber: address(uint160(0x0066177bdec367f638be98e53d1493ee043d20b4a2)), units: 3780840, pending: 454738808256624393600});
        rows[5] = PendingRow({token: address(uint160(0x00263026e7e53dbfdce5ae55ade22493f828922965)), publisher: address(uint160(0x0087588653f2f840bf0589d5715679db77d8fc021d)), indexId: 3, subscriber: address(uint160(0x0066177bdec367f638be98e53d1493ee043d20b4a2)), units: 2608760, pending: 337780347272424169960});
        rows[6] = PendingRow({token: address(uint160(0x00263026e7e53dbfdce5ae55ade22493f828922965)), publisher: address(uint160(0x00cab28480ab5c1e133e9b7fc67e030b8dcc2a1d24)), indexId: 2, subscriber: address(uint160(0x0087d81731f5912d5375157d9a625c84c686a00af4)), units: 980, pending: 272136711112335612900});
        rows[7] = PendingRow({token: address(uint160(0x00caa7349cea390f89641fe306d93591f87595dc1f)), publisher: address(uint160(0x00f6a03fcf12cdc8066afaf12255105ca301e15ba6)), indexId: 0, subscriber: address(uint160(0x001f8e5ffcbf45b392afa0b776cb8ceb66d286409c)), units: 138, pending: 103583638818518311740});
        rows[8] = PendingRow({token: address(uint160(0x00263026e7e53dbfdce5ae55ade22493f828922965)), publisher: address(uint160(0x0027c7d067a0c143990ec6ed2772e7136cfcfaecd6)), indexId: 1, subscriber: address(uint160(0x000251aeb3407fdffef515fc5f9731f010c476a0e6)), units: 38580246914, pending: 66479444522328234628});
        rows[9] = PendingRow({token: address(uint160(0x00caa7349cea390f89641fe306d93591f87595dc1f)), publisher: address(uint160(0x000d0e1381d6f6f71e6f0d8f4970bf5bd53c23d7e5)), indexId: 0, subscriber: address(uint160(0x009c6b5fdc145912dfe6ee13a667af3c5eb07cbb89)), units: 149994, pending: 48184671186000002160});
        rows[10] = PendingRow({token: address(uint160(0x00263026e7e53dbfdce5ae55ade22493f828922965)), publisher: address(uint160(0x00cab28480ab5c1e133e9b7fc67e030b8dcc2a1d24)), indexId: 3, subscriber: address(uint160(0x00b47555fdefec0f41b0ad39f21fdce5f42e04f4c3)), units: 980, pending: 23741479689347326480});
        rows[11] = PendingRow({token: address(uint160(0x00263026e7e53dbfdce5ae55ade22493f828922965)), publisher: address(uint160(0x00e0073786618b886aa1aa44df103850a227ade9ae)), indexId: 2, subscriber: address(uint160(0x007224941ae4d0f22f286d89dcba02f04a67e82d54)), units: 1960, pending: 21809273999999994200});
        rows[12] = PendingRow({token: address(uint160(0x00263026e7e53dbfdce5ae55ade22493f828922965)), publisher: address(uint160(0x00e0073786618b886aa1aa44df103850a227ade9ae)), indexId: 3, subscriber: address(uint160(0x003a3082c48a5531a14e13a88051f0a4126e862d5f)), units: 377300, pending: 20036523342673560800});
        rows[13] = PendingRow({token: address(uint160(0x00263026e7e53dbfdce5ae55ade22493f828922965)), publisher: address(uint160(0x0087588653f2f840bf0589d5715679db77d8fc021d)), indexId: 2, subscriber: address(uint160(0x00840647cb127112d0edb9e6c3ce8e0c083b99516a)), units: 22540, pending: 14820155626316880000});
        rows[14] = PendingRow({token: address(uint160(0x00263026e7e53dbfdce5ae55ade22493f828922965)), publisher: address(uint160(0x00cab28480ab5c1e133e9b7fc67e030b8dcc2a1d24)), indexId: 2, subscriber: address(uint160(0x00eecce11af9d72ae9ff15d7c106f13349d336aeaf)), units: 543900, pending: 14002458345321902400});
        rows[15] = PendingRow({token: address(uint160(0x00263026e7e53dbfdce5ae55ade22493f828922965)), publisher: address(uint160(0x0087588653f2f840bf0589d5715679db77d8fc021d)), indexId: 2, subscriber: address(uint160(0x0055557c4c2c9515d339a1f8136f9b67537ffe3333)), units: 6860, pending: 10035626578063193940});
        rows[16] = PendingRow({token: address(uint160(0x00caa7349cea390f89641fe306d93591f87595dc1f)), publisher: address(uint160(0x0065d0186ac944714a56822b855e7f803ec709a105)), indexId: 0, subscriber: address(uint160(0x009c6b5fdc145912dfe6ee13a667af3c5eb07cbb89)), units: 20, pending: 9427771660000000000});
        rows[17] = PendingRow({token: address(uint160(0x00263026e7e53dbfdce5ae55ade22493f828922965)), publisher: address(uint160(0x0087588653f2f840bf0589d5715679db77d8fc021d)), indexId: 3, subscriber: address(uint160(0x006961367ef8b92c1a306a68c87add9eafd09f7787)), units: 14700, pending: 7788804849533271900});
        rows[18] = PendingRow({token: address(uint160(0x00caa7349cea390f89641fe306d93591f87595dc1f)), publisher: address(uint160(0x000d0e1381d6f6f71e6f0d8f4970bf5bd53c23d7e5)), indexId: 0, subscriber: address(uint160(0x002e62ee3af78d005a0dffb116295b13ef45b6f2c0)), units: 16666, pending: 5353852354000000240});
        rows[19] = PendingRow({token: address(uint160(0x00263026e7e53dbfdce5ae55ade22493f828922965)), publisher: address(uint160(0x0087588653f2f840bf0589d5715679db77d8fc021d)), indexId: 3, subscriber: address(uint160(0x00eecce11af9d72ae9ff15d7c106f13349d336aeaf)), units: 755580, pending: 2858487977265062940});
        rows[20] = PendingRow({token: address(uint160(0x001305f6b6df9dc47159d12eb7ac2804d4a33173c2)), publisher: address(uint160(0x00e0b7907fa4b759fa4cb201f0e02e16374bc523fd)), indexId: 0, subscriber: address(uint160(0x003226c9eac0379f04ba2b1e1e1fcd52ac26309aea)), units: 1, pending: 2323443541782769564});
        rows[21] = PendingRow({token: address(uint160(0x00263026e7e53dbfdce5ae55ade22493f828922965)), publisher: address(uint160(0x00e0073786618b886aa1aa44df103850a227ade9ae)), indexId: 3, subscriber: address(uint160(0x00eecce11af9d72ae9ff15d7c106f13349d336aeaf)), units: 755580, pending: 2196183812522777700});
        rows[22] = PendingRow({token: address(uint160(0x00263026e7e53dbfdce5ae55ade22493f828922965)), publisher: address(uint160(0x0087588653f2f840bf0589d5715679db77d8fc021d)), indexId: 3, subscriber: address(uint160(0x009999530f0d0379f9ab0eb2102e14d4576547ffff)), units: 37240, pending: 2013800203679454960});
        rows[23] = PendingRow({token: address(uint160(0x00263026e7e53dbfdce5ae55ade22493f828922965)), publisher: address(uint160(0x0087588653f2f840bf0589d5715679db77d8fc021d)), indexId: 2, subscriber: address(uint160(0x008726924fb2498d2738e973faf8396c685119a853)), units: 543900, pending: 1786078636363400400});
        rows[24] = PendingRow({token: address(uint160(0x00caa7349cea390f89641fe306d93591f87595dc1f)), publisher: address(uint160(0x00f6a03fcf12cdc8066afaf12255105ca301e15ba6)), indexId: 0, subscriber: address(uint160(0x003226c9eac0379f04ba2b1e1e1fcd52ac26309aea)), units: 2, pending: 1501212156790120460});
        rows[25] = PendingRow({token: address(uint160(0x00caa7349cea390f89641fe306d93591f87595dc1f)), publisher: address(uint160(0x00fbf91d299db56624f46f544dc1dcd0d0da2e3327)), indexId: 0, subscriber: address(uint160(0x009c6b5fdc145912dfe6ee13a667af3c5eb07cbb89)), units: 7700, pending: 1339118880000001100});
        rows[26] = PendingRow({token: address(uint160(0x00263026e7e53dbfdce5ae55ade22493f828922965)), publisher: address(uint160(0x000d0e1381d6f6f71e6f0d8f4970bf5bd53c23d7e5)), indexId: 1, subscriber: address(uint160(0x009c6b5fdc145912dfe6ee13a667af3c5eb07cbb89)), units: 2680, pending: 974702905415088720});
        rows[27] = PendingRow({token: address(uint160(0x00caa7349cea390f89641fe306d93591f87595dc1f)), publisher: address(uint160(0x00bda1c295b5fb13304ee8d6aaabcf6ce92311defa)), indexId: 0, subscriber: address(uint160(0x00412711e2ff9decb1697762800eaa8938ba957d4c)), units: 254, pending: 790828170746636666});
        rows[28] = PendingRow({token: address(uint160(0x00caa7349cea390f89641fe306d93591f87595dc1f)), publisher: address(uint160(0x00f415cd95999c94ad9dfcb29b71908329d635e5fe)), indexId: 0, subscriber: address(uint160(0x009c6b5fdc145912dfe6ee13a667af3c5eb07cbb89)), units: 2260, pending: 778194340000000120});
        rows[29] = PendingRow({token: address(uint160(0x00caa7349cea390f89641fe306d93591f87595dc1f)), publisher: address(uint160(0x00ef2c9e8777648d7dea03b319c64ea53f38ec1398)), indexId: 0, subscriber: address(uint160(0x009c6b5fdc145912dfe6ee13a667af3c5eb07cbb89)), units: 220, pending: 626241040000000040});
        rows[30] = PendingRow({token: address(uint160(0x003ad736904e9e65189c3000c7dd2c8ac8bb7cd4e3)), publisher: address(uint160(0x0087588653f2f840bf0589d5715679db77d8fc021d)), indexId: 1, subscriber: address(uint160(0x009c6b5fdc145912dfe6ee13a667af3c5eb07cbb89)), units: 77420, pending: 420137098040094820});
        rows[31] = PendingRow({token: address(uint160(0x001305f6b6df9dc47159d12eb7ac2804d4a33173c2)), publisher: address(uint160(0x00e0073786618b886aa1aa44df103850a227ade9ae)), indexId: 0, subscriber: address(uint160(0x009c6b5fdc145912dfe6ee13a667af3c5eb07cbb89)), units: 40, pending: 181636343386363440});
        rows[32] = PendingRow({token: address(uint160(0x001305f6b6df9dc47159d12eb7ac2804d4a33173c2)), publisher: address(uint160(0x00cab28480ab5c1e133e9b7fc67e030b8dcc2a1d24)), indexId: 0, subscriber: address(uint160(0x009c6b5fdc145912dfe6ee13a667af3c5eb07cbb89)), units: 11120, pending: 111130901522261040});
        rows[33] = PendingRow({token: address(uint160(0x003ad736904e9e65189c3000c7dd2c8ac8bb7cd4e3)), publisher: address(uint160(0x00cab28480ab5c1e133e9b7fc67e030b8dcc2a1d24)), indexId: 1, subscriber: address(uint160(0x009c6b5fdc145912dfe6ee13a667af3c5eb07cbb89)), units: 92640, pending: 89179336596046560});
        rows[34] = PendingRow({token: address(uint160(0x00caa7349cea390f89641fe306d93591f87595dc1f)), publisher: address(uint160(0x00c4fdc34158f50e99358e0af7aef432c1d8761090)), indexId: 0, subscriber: address(uint160(0x003226c9eac0379f04ba2b1e1e1fcd52ac26309aea)), units: 2, pending: 86916585733882140});
        rows[35] = PendingRow({token: address(uint160(0x001305f6b6df9dc47159d12eb7ac2804d4a33173c2)), publisher: address(uint160(0x005970acd9e2cb09089fe61f4d0fec1ae0e959bbde)), indexId: 0, subscriber: address(uint160(0x009c6b5fdc145912dfe6ee13a667af3c5eb07cbb89)), units: 2280, pending: 83905906697567640});
        rows[36] = PendingRow({token: address(uint160(0x00caa7349cea390f89641fe306d93591f87595dc1f)), publisher: address(uint160(0x000c9d97e6b7c73eb3a082497cd077c20304887777)), indexId: 0, subscriber: address(uint160(0x003226c9eac0379f04ba2b1e1e1fcd52ac26309aea)), units: 2291, pending: 47234919553275584});
        rows[37] = PendingRow({token: address(uint160(0x00263026e7e53dbfdce5ae55ade22493f828922965)), publisher: address(uint160(0x00fbf91d299db56624f46f544dc1dcd0d0da2e3327)), indexId: 1, subscriber: address(uint160(0x009c6b5fdc145912dfe6ee13a667af3c5eb07cbb89)), units: 380, pending: 47206535166629800});
        rows[38] = PendingRow({token: address(uint160(0x00263026e7e53dbfdce5ae55ade22493f828922965)), publisher: address(uint160(0x00baf5e9a1a8659578263d6fbfa0d41f909321d450)), indexId: 0, subscriber: address(uint160(0x003226c9eac0379f04ba2b1e1e1fcd52ac26309aea)), units: 3472, pending: 45333308384694736});
        rows[39] = PendingRow({token: address(uint160(0x00caa7349cea390f89641fe306d93591f87595dc1f)), publisher: address(uint160(0x0087588653f2f840bf0589d5715679db77d8fc021d)), indexId: 0, subscriber: address(uint160(0x009c6b5fdc145912dfe6ee13a667af3c5eb07cbb89)), units: 16280, pending: 30384899999994320});
        rows[40] = PendingRow({token: address(uint160(0x0027e1e4e6bc79d93032abef01025811b7e4727e85)), publisher: address(uint160(0x0065d0186ac944714a56822b855e7f803ec709a105)), indexId: 1, subscriber: address(uint160(0x009c6b5fdc145912dfe6ee13a667af3c5eb07cbb89)), units: 37380, pending: 28989789305056860});
        rows[41] = PendingRow({token: address(uint160(0x00caa7349cea390f89641fe306d93591f87595dc1f)), publisher: address(uint160(0x0045d89b39446558dd5737d2d607100827e6e48952)), indexId: 0, subscriber: address(uint160(0x009c6b5fdc145912dfe6ee13a667af3c5eb07cbb89)), units: 346, pending: 6986688430508748});
        rows[42] = PendingRow({token: address(uint160(0x00caa7349cea390f89641fe306d93591f87595dc1f)), publisher: address(uint160(0x000c9d97e6b7c73eb3a082497cd077c20304887777)), indexId: 0, subscriber: address(uint160(0x00412711e2ff9decb1697762800eaa8938ba957d4c)), units: 254, pending: 5236870173082496});
        rows[43] = PendingRow({token: address(uint160(0x0027e1e4e6bc79d93032abef01025811b7e4727e85)), publisher: address(uint160(0x00f6a03fcf12cdc8066afaf12255105ca301e15ba6)), indexId: 1, subscriber: address(uint160(0x003226c9eac0379f04ba2b1e1e1fcd52ac26309aea)), units: 7716, pending: 1156550995919772});
        rows[44] = PendingRow({token: address(uint160(0x00caa7349cea390f89641fe306d93591f87595dc1f)), publisher: address(uint160(0x0045d89b39446558dd5737d2d607100827e6e48952)), indexId: 0, subscriber: address(uint160(0x00412711e2ff9decb1697762800eaa8938ba957d4c)), units: 37, pending: 747131421759606});
        rows[45] = PendingRow({token: address(uint160(0x0027e1e4e6bc79d93032abef01025811b7e4727e85)), publisher: address(uint160(0x00c4fdc34158f50e99358e0af7aef432c1d8761090)), indexId: 1, subscriber: address(uint160(0x00662080b785fc5c2d41ad83b42f55674dac7cdf23)), units: 378086419, pending: 587348555928863});
        rows[46] = PendingRow({token: address(uint160(0x0027e1e4e6bc79d93032abef01025811b7e4727e85)), publisher: address(uint160(0x00bda1c295b5fb13304ee8d6aaabcf6ce92311defa)), indexId: 1, subscriber: address(uint160(0x004444ad20879051b696a1c14ccf6e3b0459466666)), units: 771, pending: 265378067757309});
        rows[47] = PendingRow({token: address(uint160(0x0027e1e4e6bc79d93032abef01025811b7e4727e85)), publisher: address(uint160(0x00f415cd95999c94ad9dfcb29b71908329d635e5fe)), indexId: 1, subscriber: address(uint160(0x009c6b5fdc145912dfe6ee13a667af3c5eb07cbb89)), units: 192680, pending: 89206329939240});
        rows[48] = PendingRow({token: address(uint160(0x0027e1e4e6bc79d93032abef01025811b7e4727e85)), publisher: address(uint160(0x005970acd9e2cb09089fe61f4d0fec1ae0e959bbde)), indexId: 1, subscriber: address(uint160(0x009c6b5fdc145912dfe6ee13a667af3c5eb07cbb89)), units: 23120, pending: 87252523586480});
        rows[49] = PendingRow({token: address(uint160(0x004086ebf75233e8492f1bcda41c7f2a8288c2fb92)), publisher: address(uint160(0x00e0073786618b886aa1aa44df103850a227ade9ae)), indexId: 1, subscriber: address(uint160(0x009c6b5fdc145912dfe6ee13a667af3c5eb07cbb89)), units: 100280, pending: 18449999955760});
        rows[50] = PendingRow({token: address(uint160(0x0027e1e4e6bc79d93032abef01025811b7e4727e85)), publisher: address(uint160(0x00c90c8339089c3070f513b36435a28c7917c88ffc)), indexId: 1, subscriber: address(uint160(0x009c6b5fdc145912dfe6ee13a667af3c5eb07cbb89)), units: 7716, pending: 12603157927236});
        rows[51] = PendingRow({token: address(uint160(0x0027e1e4e6bc79d93032abef01025811b7e4727e85)), publisher: address(uint160(0x000c9d97e6b7c73eb3a082497cd077c20304887777)), indexId: 1, subscriber: address(uint160(0x003226c9eac0379f04ba2b1e1e1fcd52ac26309aea)), units: 6944, pending: 11507458003328});
        rows[52] = PendingRow({token: address(uint160(0x004086ebf75233e8492f1bcda41c7f2a8288c2fb92)), publisher: address(uint160(0x00ef2c9e8777648d7dea03b319c64ea53f38ec1398)), indexId: 1, subscriber: address(uint160(0x009c6b5fdc145912dfe6ee13a667af3c5eb07cbb89)), units: 27120, pending: 7715599998000});
        rows[53] = PendingRow({token: address(uint160(0x0027e1e4e6bc79d93032abef01025811b7e4727e85)), publisher: address(uint160(0x00c4fdc34158f50e99358e0af7aef432c1d8761090)), indexId: 1, subscriber: address(uint160(0x003226c9eac0379f04ba2b1e1e1fcd52ac26309aea)), units: 8487650, pending: 4827215135100});
        rows[54] = PendingRow({token: address(uint160(0x004086ebf75233e8492f1bcda41c7f2a8288c2fb92)), publisher: address(uint160(0x001f001afc25dc911fba6c86b9a81ad71bb6ddafd6)), indexId: 1, subscriber: address(uint160(0x009c6b5fdc145912dfe6ee13a667af3c5eb07cbb89)), units: 7, pending: 4379454545452});
        rows[55] = PendingRow({token: address(uint160(0x004086ebf75233e8492f1bcda41c7f2a8288c2fb92)), publisher: address(uint160(0x0045d89b39446558dd5737d2d607100827e6e48952)), indexId: 1, subscriber: address(uint160(0x009c6b5fdc145912dfe6ee13a667af3c5eb07cbb89)), units: 6944, pending: 2984040925824});
        rows[56] = PendingRow({token: address(uint160(0x0027e1e4e6bc79d93032abef01025811b7e4727e85)), publisher: address(uint160(0x000c9d97e6b7c73eb3a082497cd077c20304887777)), indexId: 1, subscriber: address(uint160(0x004444ad20879051b696a1c14ccf6e3b0459466666)), units: 771, pending: 1277685789252});
        rows[57] = PendingRow({token: address(uint160(0x004086ebf75233e8492f1bcda41c7f2a8288c2fb92)), publisher: address(uint160(0x0045d89b39446558dd5737d2d607100827e6e48952)), indexId: 1, subscriber: address(uint160(0x004444ad20879051b696a1c14ccf6e3b0459466666)), units: 771, pending: 331321364316});
        rows[58] = PendingRow({token: address(uint160(0x0027e1e4e6bc79d93032abef01025811b7e4727e85)), publisher: address(uint160(0x00e6a190d5c70c357be7804c4f31911dde8228fdc5)), indexId: 0, subscriber: address(uint160(0x003226c9eac0379f04ba2b1e1e1fcd52ac26309aea)), units: 1, pending: 18});
    }
}
