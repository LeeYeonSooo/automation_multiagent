// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

/// @title  ContextUtils — mirrors Superfluid Host's internal Context encoding.
/// @notice Purely a construction / serialization helper.  The produced `bytes`
///         are byte-identical to what `Superfluid._updateContext` emits, so a
///         legitimate caller (test, off-chain signer, SuperApp author) can
///         reason about / reproduce the exact ctx payload the Host would build.
/// @dev    All layout constants are lifted verbatim from
///         `contracts/interfaces/superfluid/Definitions.sol` and
///         `contracts/superfluid/Superfluid.sol` so any drift is easy to spot.
library ContextUtils {
    // ── Context struct ───────────────────────────────────────────────────
    // Keep field order & types IDENTICAL to ISuperfluid.Context; the outer
    // encoding splits these into two abi.encode blocks (ctx1 + ctx2).
    struct Context {
        uint8   appCallbackLevel;                 // \
        uint8   callType;                         //  |
        uint256 timestamp;                        //   > ctx1 block
        address msgSender;                        //  |
        bytes4  agreementSelector;                //  |
        bytes   userData;                         // /
        uint256 appCreditGranted;                 // \
        uint256 appCreditWantedDeprecated;        //  |
        int256  appCreditUsed;                    //   > ctx2 block
        address appAddress;                       //  |
        address appCreditToken;                   // /   (ISuperfluidToken in source; address-compatible)
    }

    // ── Bit-layout constants (Definitions.sol:71–85) ─────────────────────
    uint256 internal constant CALL_INFO_APP_LEVEL_MASK  = 0xFF;
    uint256 internal constant CALL_INFO_CALL_TYPE_SHIFT = 32;
    uint256 internal constant CALL_INFO_CALL_TYPE_MASK  = 0xF << CALL_INFO_CALL_TYPE_SHIFT;

    // callType enum values (Definitions.sol:83–85)
    uint8 internal constant CALL_TYPE_AGREEMENT    = 1;
    uint8 internal constant CALL_TYPE_APP_ACTION   = 2;
    uint8 internal constant CALL_TYPE_APP_CALLBACK = 3;

    // ─────────────────────────────────────────────────────────────────────
    // Pack (appCallbackLevel, callType) → single uint256 callInfo
    // Mirror of ContextDefinitions.encodeCallInfo.
    // ─────────────────────────────────────────────────────────────────────
    function encodeCallInfo(uint8 appCallbackLevel, uint8 callType)
        internal pure
        returns (uint256 callInfo)
    {
        callInfo = uint256(appCallbackLevel) | (uint256(callType) << CALL_INFO_CALL_TYPE_SHIFT);
    }

    function decodeCallInfo(uint256 callInfo)
        internal pure
        returns (uint8 appCallbackLevel, uint8 callType)
    {
        appCallbackLevel = uint8(callInfo & CALL_INFO_APP_LEVEL_MASK);
        callType         = uint8((callInfo & CALL_INFO_CALL_TYPE_MASK) >> CALL_INFO_CALL_TYPE_SHIFT);
    }

    // ─────────────────────────────────────────────────────────────────────
    // Convenience constructor — build a fully-formed Context from the three
    // fields a regular `callAgreement` caller actually controls.  The rest
    // are left at their protocol-default zero values, exactly as
    // `Superfluid._callAgreement` does for a fresh top-level call.
    // ─────────────────────────────────────────────────────────────────────
    function buildContext(
        address msgSender,
        bytes4  agreementSelector,
        bytes memory userData
    ) internal view returns (Context memory ctx) {
        ctx.appCallbackLevel          = 0;
        ctx.callType                  = CALL_TYPE_AGREEMENT;
        ctx.timestamp                 = block.timestamp;
        ctx.msgSender                 = msgSender;
        ctx.agreementSelector         = agreementSelector;
        ctx.userData                  = userData;
        ctx.appCreditGranted          = 0;
        ctx.appCreditWantedDeprecated = 0;
        ctx.appCreditUsed             = 0;
        ctx.appAddress                = address(0);
        ctx.appCreditToken            = address(0);
    }

    // ─────────────────────────────────────────────────────────────────────
    // Pack a Context into its canonical bytes representation.
    //
    // Layout (must match Superfluid._updateContext exactly):
    //   ctx = abi.encode(
    //       abi.encode(callInfo, timestamp, msgSender, agreementSelector, userData),
    //       abi.encode(creditIO, appCreditUsed, appAddress, appCreditToken)
    //   )
    //
    // where:
    //   callInfo = encodeCallInfo(appCallbackLevel, callType)
    //   creditIO = uint128(appCreditGranted) | (uint128(appCreditWantedDeprecated) << 128)
    //
    // The resulting `bytes` are what Superfluid splices in where the caller
    // left `new bytes(0)` as the placeholder ctx.  keccak256(ctx) is what
    // gets stored as `_ctxStamp`.
    // ─────────────────────────────────────────────────────────────────────
    function encodeContext(Context memory ctx)
        internal pure
        returns (bytes memory packed)
    {
        uint256 callInfo = encodeCallInfo(ctx.appCallbackLevel, ctx.callType);

        // creditIO packs both 128-bit credit fields into one word.  Downcast
        // guard: values > uint128.max would silently alias in Superfluid's
        // SafeCast; we mirror that by reverting up front.
        require(ctx.appCreditGranted          <= type(uint128).max, "ctx: granted overflow");
        require(ctx.appCreditWantedDeprecated <= type(uint128).max, "ctx: wanted overflow");
        uint256 creditIO = ctx.appCreditGranted | (ctx.appCreditWantedDeprecated << 128);

        packed = abi.encode(
            abi.encode(
                callInfo,
                ctx.timestamp,
                ctx.msgSender,
                ctx.agreementSelector,
                ctx.userData
            ),
            abi.encode(
                creditIO,
                ctx.appCreditUsed,
                ctx.appAddress,
                ctx.appCreditToken
            )
        );
    }

    // Round-trip counterpart — mirrors Superfluid._decodeCtx.
    function decodeContext(bytes memory packed)
        internal pure
        returns (Context memory ctx)
    {
        (bytes memory ctx1, bytes memory ctx2) = abi.decode(packed, (bytes, bytes));

        uint256 callInfo;
        (callInfo, ctx.timestamp, ctx.msgSender, ctx.agreementSelector, ctx.userData) =
            abi.decode(ctx1, (uint256, uint256, address, bytes4, bytes));
        (ctx.appCallbackLevel, ctx.callType) = decodeCallInfo(callInfo);

        uint256 creditIO;
        (creditIO, ctx.appCreditUsed, ctx.appAddress, ctx.appCreditToken) =
            abi.decode(ctx2, (uint256, int256, address, address));
        ctx.appCreditGranted          = creditIO & type(uint128).max;
        ctx.appCreditWantedDeprecated = creditIO >> 128;
    }

    // Same hash the Host commits to as `_ctxStamp` after `_updateContext`.
    function stamp(bytes memory packed) internal pure returns (bytes32) {
        return keccak256(packed);
    }
}
