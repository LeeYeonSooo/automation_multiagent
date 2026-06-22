pragma solidity 0.8.23;
import "forge-std/Test.sol";
interface I20 { function balanceOf(address) external view returns(uint256); function approve(address,uint256) external returns(bool); }
interface IEx { struct I { bool a; address p; bytes d; } function batchDispatch(I[] calldata,address[] calldata) external; }
interface IET { function balanceOf(address) external view returns(uint256); function transfer(address,uint256) external returns(bool); }
interface IDT { function balanceOf(address) external view returns(uint256); }

contract TestEulerTransfer is Test {
    address constant eDAI = 0xe025E3ca2bE02316033184551D4d3Aa22024D9DC;
    address constant dDAI = 0x6085Bc95F506c326DCBCD7A6dd6c79FBc18d4686;
    
    function testTransferToSub1() public {
        deal(0x6B175474E89094C44Da98b954EedeAC495271d0F, address(this), 30e24);
        I20(0x6B175474E89094C44Da98b954EedeAC495271d0F).approve(0x27182842E098f60e3D576794A5bFFb0777E025d3, type(uint256).max);
        
        address sub1 = address(uint160(uint160(address(this)) ^ 1));
        
        // Batch: enter + deposit + mint + transfer eTokens to sub1
        IEx.I[] memory it = new IEx.I[](4);
        it[0] = IEx.I(false, 0x3520d5a913427E6F0D6A83E07ccD4A4da316e4d3, 
            abi.encodeWithSignature("enterMarket(uint256,address)",0,0x6B175474E89094C44Da98b954EedeAC495271d0F));
        it[1] = IEx.I(false, eDAI, abi.encodeWithSignature("deposit(uint256,uint256)",0,20e24));
        it[2] = IEx.I(false, eDAI, abi.encodeWithSignature("mint(uint256,uint256)",0,180e24));
        // Transfer ALL eTokens to sub-account 1
        // This SHOULD fail at the deferred check because sub0 will be underwater
        // But let's see if transfer itself checks health
        it[3] = IEx.I(false, eDAI, abi.encodeWithSignature("transfer(address,uint256)", sub1, type(uint256).max));
        
        address[] memory df = new address[](2);
        df[0] = address(this);
        df[1] = sub1;
        
        try IEx(0x59828FdF7ee634AaaD3f58B19fDBa3b03E2D9d80).batchDispatch(it, df) {
            uint256 eSub0 = IET(eDAI).balanceOf(address(this));
            uint256 eSub1 = IET(eDAI).balanceOf(sub1);
            uint256 dSub0 = IDT(dDAI).balanceOf(address(this));
            emit log_named_uint("sub0 eDAI", eSub0);
            emit log_named_uint("sub1 eDAI", eSub1);
            emit log_named_uint("sub0 dDAI", dSub0);
            emit log("TRANSFER SUCCEEDED - sub0 is underwater!");
        } catch (bytes memory reason) {
            emit log_named_bytes("Transfer batch reverted", reason);
            // Try with partial transfer
            emit log("Trying partial transfer...");
        }
    }
    receive() external payable {}
}
