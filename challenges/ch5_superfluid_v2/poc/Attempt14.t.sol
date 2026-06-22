// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import "forge-std/StdJson.sol";

interface ISuperfluidHost {
    function isApp(address app) external view returns (bool);
}

interface IInstantDistributionAgreementV1 {
    function getIndex(
        address token,
        address publisher,
        uint32 indexId
    ) external view returns (bool exist, uint128 indexValue, uint128 totalUnitsApproved, uint128 totalUnitsPending);

    function getSubscription(
        address token,
        address publisher,
        uint32 indexId,
        address subscriber
    ) external view returns (bool exist, bool approved, uint128 units, uint256 pendingDistribution);
}

/// @title Attempt14
/// @notice Hypothesis: the publisher-side `claim()` branch is still live on the
///         fork because the actual historical IDA publisher universe overlaps
///         heavily with current SuperApps. The earlier "zero overlap" finding
///         was a bad target set, not a protocol limitation.
///
///         This probe consumes the corrected historical scan at
///         `recon/index_created_publishers_scan.json` and verifies one concrete
///         publisher-owned tuple recovered from chain logs. That re-opens the
///         publisher-oriented claim search on real data instead of guessed
///         subscriber seeds.
contract Attempt14 is Test {
    using stdJson for string;

    address constant ATTACKER = 0xc943eDB4Bb4439d65B81f2f60Bc698411e910B14;

    uint256 constant FORK_BLOCK = 27_039_967;
    string constant PUBLISHER_SCAN_PATH = "recon/index_created_publishers_scan.json";

    ISuperfluidHost constant HOST = ISuperfluidHost(0x3E14dC1b13c488a8d5D310918780c983bD5982E7);
    IInstantDistributionAgreementV1 constant IDA =
        IInstantDistributionAgreementV1(0xB0aABBA4B2783A72C52956CDEF62d438ecA2d7a1);

    // Earliest live app-publisher tuple recovered from narrow `cast logs`
    // windows after correcting the publisher scan.
    address constant EXAMPLE_PUBLISHER = 0x7E2E5f06e36da0BA58B08940a72Fd6b68FbDfD61;
    address constant EXAMPLE_SUBSCRIBER = 0x3226C9EaC0379F04Ba2b1E1e1fcD52ac26309aeA;
    address constant EXAMPLE_TOKEN_0 = 0x27e1e4E6BC79D93032abef01025811B7E4727e85;
    address constant EXAMPLE_TOKEN_1 = 0x263026E7e53DBFDce5ae55Ade22493f828922965;

    function setUp() public {
        vm.createSelectFork("ch5", FORK_BLOCK);

        vm.label(ATTACKER, "Attacker");
        vm.label(address(HOST), "SuperfluidHost");
        vm.label(address(IDA), "IDA");
        vm.label(EXAMPLE_PUBLISHER, "ExamplePublisherApp");
        vm.label(EXAMPLE_SUBSCRIBER, "ExampleSubscriber");
        vm.label(EXAMPLE_TOKEN_0, "ExampleToken0");
        vm.label(EXAMPLE_TOKEN_1, "ExampleToken1");
    }

    function test_corrected_publisher_scan_reopens_claim_branch() public {
        uint256 nativeBefore = ATTACKER.balance;
        console.log("[start] attacker native:", nativeBefore);
        console.log("[preflight] chain id:", block.chainid);
        console.log("[preflight] fork block:", block.number);

        string memory json = vm.readFile(PUBLISHER_SCAN_PATH);
        uint256 uniquePublisherCount = json.readUint(".uniquePublisherCount");
        uint256 superAppPublisherCount = json.readUint(".superAppPublisherCount");

        console.log("[scan] unique historical publishers:", uniquePublisherCount);
        console.log("[scan] live superapp publishers:", superAppPublisherCount);

        assertEq(uniquePublisherCount, 128, "corrected scan should recover 128 unique historical publishers");
        assertEq(superAppPublisherCount, 75, "corrected scan should recover 75 live SuperApp publishers");
        assertTrue(HOST.isApp(EXAMPLE_PUBLISHER), "example historical publisher must still be a live SuperApp");

        _assertExampleTuple(EXAMPLE_TOKEN_0, 0);
        _assertExampleTuple(EXAMPLE_TOKEN_1, 1);

        uint256 nativeAfter = ATTACKER.balance;
        console.log("[end] attacker native:", nativeAfter);
        console.logInt(int256(nativeAfter) - int256(nativeBefore));
        assertEq(nativeAfter, nativeBefore, "recon probe should not change native balance");
    }

    function _assertExampleTuple(address token, uint32 indexId) internal view {
        (bool indexExists, uint128 indexValue, uint128 totalUnitsApproved, uint128 totalUnitsPending) =
            IDA.getIndex(token, EXAMPLE_PUBLISHER, indexId);
        (bool subExists, bool approved, uint128 units, uint256 pendingDistribution) =
            IDA.getSubscription(token, EXAMPLE_PUBLISHER, indexId, EXAMPLE_SUBSCRIBER);

        console.log("[tuple] token:", token);
        console.log("[tuple] index id:", uint256(indexId));
        console.log("[tuple] index exists:", indexExists);
        console.log("[tuple] index value:", indexValue);
        console.log("[tuple] total approved:", totalUnitsApproved);
        console.log("[tuple] total pending:", totalUnitsPending);
        console.log("[tuple] sub exists:", subExists);
        console.log("[tuple] approved:", approved);
        console.log("[tuple] units:", units);
        console.log("[tuple] pending distribution:", pendingDistribution);

        assertTrue(indexExists, "historical app-owned index should still exist");
        assertTrue(subExists, "historical subscriber tuple should still exist");
        assertFalse(approved, "historical example stays on the unapproved claim path");
        assertEq(units, 1, "historical example should still have 1 unit");
        assertEq(indexValue, 0, "earliest example is a dry control with zero current index value");
        assertEq(totalUnitsApproved, 0, "earliest example should have no approved units");
        assertEq(totalUnitsPending, 1, "earliest example should still track 1 pending unit");
        assertEq(pendingDistribution, 0, "earliest example currently has no pending payout");
    }
}
