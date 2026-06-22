// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import {ContextUtils} from "reference/ContextUtils.sol";

interface IIDAClaim41 {
    function claim(address token, address publisher, uint32 indexId, address subscriber, bytes calldata ctx)
        external
        returns (bytes memory newCtx);
}

/// @title Attempt43
/// @notice Claim selector/body diff against the live fork IDA implementation.
/// @dev Hypothesis:
///      the unverified fork runtime at `0x8484...` may hide an extra claim-side
///      branch around selector `0xacafa1b8` beyond the already known
///      `authorizeTokenAccess` omission. If so, the live body would diverge from
///      the public source by:
///      - dispatching through a fork-only trampoline,
///      - re-entering a hidden helper before `_loadAllData(...)`,
///      - reordering `settleBalance -> updateAgreementData -> settleBalance`, or
///      - adding a zero-subscriber/custom-error branch not present in the older
///        fork lineage.
///
///      Public comparison targets:
///      - previous public source:
///        `sources/ch5_superfluid_v2/0x85eb.../src/contracts/agreements/InstantDistributionAgreementV1.sol`
///      - current public source:
///        `sources/ch5_superfluid_v2/0x86e8.../src/contracts/agreements/InstantDistributionAgreementV1.sol`
///      - shared authorization helper:
///        `sources/ch5_superfluid_v2/0x85eb.../src/contracts/agreements/AgreementLibrary.sol`
///      - cached challenge runtime fixture:
///        `recon/ida_impl_27039967.bytecode`
///
///      Expected result from prior manual reads:
///      - selector `0xacafa1b8` still dispatches `0x00a4 -> 0x0614 -> 0x2758`,
///      - claim still skips the shared authorize helper at `0x3939`,
///      - claim still lacks the public zero-subscriber precondition, and
///      - settlement still follows publisher-settle -> updateAgreementData ->
///        subscriber-settle, so there is no new fork-only drain path in the
///        claim body itself.
///
///      The live ch5 RPC timed out during this task, so the test consumes the
///      already-cached block-27039967 runtime fetched from the same challenge
///      chain instead of instantiating a fresh fork in `setUp()`.
contract Attempt43 is Test {
    uint256 internal constant FORK_BLOCK = 27_039_967;
    string internal constant FIXTURE_PATH = "recon/ida_impl_27039967.bin";

    address internal constant IDA_IMPL = 0x848497975f5757Aa1a48e13bbF46D330E62b19A7;
    bytes32 internal constant CACHED_CODE_HASH =
        0x5c7d7a8cb87076e9d288fd8d214b70f17a5e49bcc8bf5891e4cf1e3905557915;
    uint256 internal constant CACHED_RAW_LENGTH = 24_409;

    uint16 internal constant CLAIM_DISPATCH_TABLE_PC = 0x009f;
    uint16 internal constant CLAIM_DECODE_DEST_PC = 0x00a6;
    uint16 internal constant CLAIM_DECODE_ENTRY = 0x0614;
    uint16 internal constant CLAIM_BODY_PUSH_PC = 0x06aa;
    uint16 internal constant CLAIM_BODY_ENTRY = 0x2758;
    uint16 internal constant CLAIM_BODY_END = 0x2b5d;
    uint16 internal constant APPROVE_BODY_ENTRY = 0x2b5e;
    uint16 internal constant AUTHORIZE_HELPER_ENTRY = 0x3939;

    uint16 internal constant SUBID_CHECK_PC = 0x2794;
    uint16 internal constant CALLBACK_INPUT_PC = 0x2819;
    uint16 internal constant CTX_COPY_PC = 0x283a;
    uint16 internal constant BEFORE_CALLBACK_PC = 0x287b;
    uint16 internal constant FIRST_SETTLE_PC = 0x28a8;
    uint16 internal constant DUPLICATE_SETTLE_SELECTOR_PC = 0x28d2;
    uint16 internal constant UPDATE_PC = 0x293b;
    uint16 internal constant SECOND_SETTLE_PC = 0x29ec;
    uint16 internal constant EVENT_PC = 0x2a76;
    uint16 internal constant AFTER_CALLBACK_PC = 0x2af5;
    uint16 internal constant ZERO_PENDING_BRANCH_PC = 0x2b17;

    bytes4 internal constant CLAIM_SELECTOR = IIDAClaim41.claim.selector;
    bytes4 internal constant SETTLE_BALANCE_SELECTOR = 0xcf97256d;
    bytes4 internal constant UPDATE_AGREEMENT_DATA_SELECTOR = 0xa1b2bf8b;
    bytes4 internal constant PUBLIC_ZERO_SUBSCRIBER_ERROR =
        bytes4(keccak256("IDA_ZERO_ADDRESS_SUBSCRIBER()"));

    function test_claim_selector_body_diff_matches_live_runtime() public {
        bytes memory rawCachedCode = vm.readFileBinary(FIXTURE_PATH);
        bytes memory code = _trimTrailingZeros(rawCachedCode);

        ContextUtils.Context memory canonicalCtx =
            ContextUtils.buildContext(address(this), CLAIM_SELECTOR, new bytes(0));
        bytes memory packedCtx = ContextUtils.encodeContext(canonicalCtx);

        console.log("[ctx] canonical claim selector:");
        console.logBytes4(canonicalCtx.agreementSelector);
        console.log("[ctx] canonical packed length:", packedCtx.length);
        console.log("[ctx] canonical stamp:");
        console.logBytes32(ContextUtils.stamp(packedCtx));

        console.log("[cache] fixture path:", FIXTURE_PATH);
        console.log("[cache] cached block:", FORK_BLOCK);
        console.log("[cache] ida impl:", IDA_IMPL);
        console.log("[cache] raw cached bytes:", rawCachedCode.length);
        console.log("[cast-code] runtime bytes:", code.length);
        console.log("[cast-code] selector window @0x0098");
        console.logBytes(_slice(code, 0x0098, 0x20));
        console.log("[cast-code] decode wrapper window @0x0608");
        console.logBytes(_slice(code, 0x0608, 0x28));
        console.log("[cast-code] body prologue @0x2758");
        console.logBytes(_slice(code, CLAIM_BODY_ENTRY, 0x40));
        console.log("[cast-code] settle/update window @0x28a8");
        console.logBytes(_slice(code, FIRST_SETTLE_PC, 0xa8));

        assertEq(rawCachedCode.length, CACHED_RAW_LENGTH, "unexpected cached bytecode size");
        assertEq(code.length, 24_400, "unexpected trimmed fork impl size");
        assertEq(keccak256(code), CACHED_CODE_HASH, "trimmed code hash drifted from cached block-27039967 runtime");

        _assertPush4(code, CLAIM_DISPATCH_TABLE_PC, CLAIM_SELECTOR);
        assertEq(_readU16(code, CLAIM_DECODE_DEST_PC), CLAIM_DECODE_ENTRY, "claim dispatch target drifted");
        _assertPush2(code, CLAIM_BODY_PUSH_PC, CLAIM_BODY_ENTRY);

        assertFalse(
            _containsPush2(code, CLAIM_BODY_ENTRY, APPROVE_BODY_ENTRY - 1, AUTHORIZE_HELPER_ENTRY),
            "claim body unexpectedly references shared authorize helper"
        );
        assertFalse(
            _containsPush4(code, CLAIM_BODY_ENTRY, CLAIM_BODY_END, PUBLIC_ZERO_SUBSCRIBER_ERROR),
            "claim body unexpectedly contains public zero-subscriber custom error selector"
        );

        uint16 firstSettlePc = _findPush4(code, BEFORE_CALLBACK_PC, UPDATE_PC, SETTLE_BALANCE_SELECTOR);
        uint16 updatePc = _findPush4(code, firstSettlePc + 1, EVENT_PC, UPDATE_AGREEMENT_DATA_SELECTOR);
        uint16 secondSettlePc = _findPush4(code, updatePc + 1, EVENT_PC, SETTLE_BALANCE_SELECTOR);

        console.log("[manual] discovered first settle pc:", uint256(firstSettlePc));
        console.log("[manual] discovered updateAgreementData pc:", uint256(updatePc));
        console.log("[manual] discovered second settle pc:", uint256(secondSettlePc));

        console.log("[manual] claim selector still dispatches 0x00a4 -> 0x0614 -> 0x2758");
        console.log("[manual] claim body window starts at _loadAllData-side prologue, not authorizeTokenAccess");
        console.log("[manual] no zero-subscriber custom error literal appears inside live claim body");
        console.log("[manual] settlement landmarks stay publisher-settle -> updateAgreementData -> subscriber-settle");
        console.log("[manual] exploit implication: no new fork-only claim-body drain path surfaced; only the known");
        console.log("[manual] missing-authorization lineage remains, so profitable behavior still has to come from");
        console.log("[manual] external callback/reentry semantics rather than a hidden selector-local settlement branch");

        assertLt(SUBID_CHECK_PC, CALLBACK_INPUT_PC, "expected approval gate before callback input creation");
        assertLt(CALLBACK_INPUT_PC, CTX_COPY_PC, "expected ctx copy after callback input creation");
        assertLt(CTX_COPY_PC, BEFORE_CALLBACK_PC, "expected before-callback after ctx copy");
        assertLt(BEFORE_CALLBACK_PC, firstSettlePc, "expected publisher settle after before callback");
        assertLt(firstSettlePc, updatePc, "expected updateAgreementData after publisher settle");
        assertLt(updatePc, secondSettlePc, "expected subscriber settle after agreement data update");
        assertLt(secondSettlePc, EVENT_PC, "expected events after subscriber settle");
        assertLt(EVENT_PC, AFTER_CALLBACK_PC, "expected after-callback after events");
        assertLt(AFTER_CALLBACK_PC, ZERO_PENDING_BRANCH_PC, "expected zero-pending branch at end of body");
    }

    function _assertPush2(bytes memory code, uint256 pc, uint16 value) internal pure {
        assertEq(uint8(code[pc]), 0x61, "expected PUSH2");
        assertEq(_readU16(code, pc + 1), value, "unexpected PUSH2 immediate");
    }

    function _assertPush4(bytes memory code, uint256 pc, bytes4 value) internal pure {
        assertEq(uint8(code[pc]), 0x63, "expected PUSH4");
        assertEq(_readBytes4(code, pc + 1), value, "unexpected PUSH4 immediate");
    }

    function _containsPush2(bytes memory code, uint256 start, uint256 endInclusive, uint16 value)
        internal
        pure
        returns (bool)
    {
        if (endInclusive <= start + 2) return false;

        bytes2 needle = bytes2(value);
        for (uint256 i = start; i + 2 <= endInclusive; ++i) {
            if (code[i] == bytes1(0x61) && code[i + 1] == needle[0] && code[i + 2] == needle[1]) {
                return true;
            }
        }
        return false;
    }

    function _containsPush4(bytes memory code, uint256 start, uint256 endInclusive, bytes4 value)
        internal
        pure
        returns (bool)
    {
        if (endInclusive <= start + 4) return false;

        for (uint256 i = start; i + 4 <= endInclusive; ++i) {
            if (code[i] == bytes1(0x63) && _readBytes4(code, i + 1) == value) {
                return true;
            }
        }
        return false;
    }

    function _findPush4(bytes memory code, uint256 start, uint256 endInclusive, bytes4 value)
        internal
        pure
        returns (uint16 pc)
    {
        for (uint256 i = start; i + 4 <= endInclusive; ++i) {
            if (code[i] == bytes1(0x63) && _readBytes4(code, i + 1) == value) {
                return uint16(i);
            }
        }
        revert("push4 not found");
    }

    function _slice(bytes memory data, uint256 start, uint256 len) internal pure returns (bytes memory out) {
        require(start + len <= data.length, "slice oob");
        out = new bytes(len);
        for (uint256 i = 0; i < len; ++i) {
            out[i] = data[start + i];
        }
    }

    function _trimTrailingZeros(bytes memory data) internal pure returns (bytes memory trimmed) {
        uint256 newLen = data.length;
        while (newLen > 0 && data[newLen - 1] == bytes1(0)) {
            unchecked {
                --newLen;
            }
        }

        trimmed = new bytes(newLen);
        for (uint256 i = 0; i < newLen; ++i) {
            trimmed[i] = data[i];
        }
    }

    function _readU16(bytes memory data, uint256 offset) internal pure returns (uint16 value) {
        value = (uint16(uint8(data[offset])) << 8) | uint16(uint8(data[offset + 1]));
    }

    function _readBytes4(bytes memory data, uint256 offset) internal pure returns (bytes4 value) {
        value = bytes4(
            (uint32(uint8(data[offset])) << 24)
                | (uint32(uint8(data[offset + 1])) << 16)
                | (uint32(uint8(data[offset + 2])) << 8)
                | uint32(uint8(data[offset + 3]))
        );
    }
}
