pragma solidity 0.8.23;
import "forge-std/Test.sol";
interface I20 { function balanceOf(address) external view returns(uint256); function approve(address,uint256) external returns(bool); }
interface IEx { struct I { bool a; address p; bytes d; } function batchDispatch(I[] calldata,address[] calldata) external; }
contract TestDonateStrict is Test {
    function testDonateStrictFalse() public {
        deal(0x6B175474E89094C44Da98b954EedeAC495271d0F, address(this), 30e24);
        I20(0x6B175474E89094C44Da98b954EedeAC495271d0F).approve(0x27182842E098f60e3D576794A5bFFb0777E025d3, type(uint256).max);
        IEx.I[] memory it = new IEx.I[](4);
        it[0] = IEx.I(false, 0x3520d5a913427E6F0D6A83E07ccD4A4da316e4d3, abi.encodeWithSignature("enterMarket(uint256,address)",0,0x6B175474E89094C44Da98b954EedeAC495271d0F));
        it[1] = IEx.I(false, 0xe025E3ca2bE02316033184551D4d3Aa22024D9DC, abi.encodeWithSignature("deposit(uint256,uint256)",0,20e24));
        it[2] = IEx.I(false, 0xe025E3ca2bE02316033184551D4d3Aa22024D9DC, abi.encodeWithSignature("mint(uint256,uint256)",0,180e24));
        // donateToReserves with allowError=FALSE - will revert if doesn't exist
        it[3] = IEx.I(false, 0xe025E3ca2bE02316033184551D4d3Aa22024D9DC, abi.encodeWithSignature("donateToReserves(uint256,uint256)",0,100e24));
        address[] memory df = new address[](1); df[0]=address(this);
        IEx(0x59828FdF7ee634AaaD3f58B19fDBa3b03E2D9d80).batchDispatch(it,df);
        emit log("DONATE SUCCEEDED WITH STRICT=FALSE!");
    }
    receive() external payable {}
}
