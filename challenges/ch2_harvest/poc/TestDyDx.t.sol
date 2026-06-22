// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;
import "forge-std/Test.sol";

interface ISoloMargin {
    struct AccountInfo { address owner; uint256 number; }
    enum ActionType { Deposit, Withdraw, Transfer, Buy, Sell, Trade, Liquidate, Vaporize, Call }
    enum AssetDenomination { Wei, Par }
    enum AssetReference { Delta, Target }
    struct AssetAmount { bool sign; AssetDenomination denomination; AssetReference ref; uint256 value; }
    struct ActionArgs {
        ActionType actionType; uint256 accountId; AssetAmount amount;
        uint256 primaryMarketId; uint256 secondaryMarketId;
        address otherAddress; uint256 otherAccountId; bytes data;
    }
    function operate(AccountInfo[] calldata accounts, ActionArgs[] calldata actions) external;
    function getMarketTokenAddress(uint256 marketId) external view returns (address);
}

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

contract DyDxFlashTest is Test {
    ISoloMargin constant SOLO = ISoloMargin(0x1E0447b19BB6EcFdAe1e4AE1694b0C3659614e4e);
    
    bool public called;
    
    function testFlashLoan() public {
        address usdc = SOLO.getMarketTokenAddress(2);
        emit log_named_address("USDC market token", usdc);
        
        uint256 balance = IERC20(usdc).balanceOf(address(SOLO));
        emit log_named_uint("USDC in dYdX", balance);
        
        // Approve repayment
        IERC20(usdc).approve(address(SOLO), type(uint256).max);
        deal(usdc, address(this), 100e6); // Give ourselves repayment amount
        
        // Setup flash
        ISoloMargin.AccountInfo[] memory accounts = new ISoloMargin.AccountInfo[](1);
        accounts[0] = ISoloMargin.AccountInfo(address(this), 0);
        
        ISoloMargin.ActionArgs[] memory actions = new ISoloMargin.ActionArgs[](3);
        
        // Withdraw
        actions[0] = ISoloMargin.ActionArgs({
            actionType: ISoloMargin.ActionType.Withdraw,
            accountId: 0,
            amount: ISoloMargin.AssetAmount(false, ISoloMargin.AssetDenomination.Wei, ISoloMargin.AssetReference.Delta, 1_000_000e6),
            primaryMarketId: 2,
            secondaryMarketId: 0,
            otherAddress: address(this),
            otherAccountId: 0,
            data: ""
        });
        
        // Call (triggers callFunction callback)
        actions[1] = ISoloMargin.ActionArgs({
            actionType: ISoloMargin.ActionType.Call,
            accountId: 0,
            amount: ISoloMargin.AssetAmount(false, ISoloMargin.AssetDenomination.Wei, ISoloMargin.AssetReference.Delta, 0),
            primaryMarketId: 0,
            secondaryMarketId: 0,
            otherAddress: address(this),
            otherAccountId: 0,
            data: ""
        });
        
        // Deposit (repay + 2 wei)
        actions[2] = ISoloMargin.ActionArgs({
            actionType: ISoloMargin.ActionType.Deposit,
            accountId: 0,
            amount: ISoloMargin.AssetAmount(true, ISoloMargin.AssetDenomination.Wei, ISoloMargin.AssetReference.Delta, 1_000_000e6 + 2),
            primaryMarketId: 2,
            secondaryMarketId: 0,
            otherAddress: address(this),
            otherAccountId: 0,
            data: ""
        });
        
        SOLO.operate(accounts, actions);
        assertTrue(called, "callback not called");
        emit log("dYdX flash loan successful!");
    }
    
    function callFunction(address sender, ISoloMargin.AccountInfo calldata, bytes calldata) external {
        require(msg.sender == address(SOLO));
        called = true;
        uint256 bal = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48).balanceOf(address(this));
        emit log_named_uint("USDC received in callback", bal);
    }
}
