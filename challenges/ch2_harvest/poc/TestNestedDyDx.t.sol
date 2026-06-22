// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;
import "forge-std/Test.sol";

interface IUniswapV2Pair {
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
    function token0() external view returns (address);
    function token1() external view returns (address);
}

interface ISoloMargin {
    struct AccountInfo { address owner; uint256 number; }
    enum ActionType { Deposit, Withdraw, Transfer, Buy, Sell, Trade, Liquidate, Vaporize, Call }
    enum AssetDenomination { Wei, Par }
    enum AssetReference { Delta, Target }
    struct AssetAmount { bool sign; AssetDenomination denomination; AssetReference ref; uint256 value; }
    struct ActionArgs { ActionType actionType; uint256 accountId; AssetAmount amount; uint256 primaryMarketId; uint256 secondaryMarketId; address otherAddress; uint256 otherAccountId; bytes data; }
    function operate(AccountInfo[] calldata accounts, ActionArgs[] calldata actions) external;
}

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

contract TestNestedDyDx is Test {
    ISoloMargin constant SOLO = ISoloMargin(0x1E0447b19BB6EcFdAe1e4AE1694b0C3659614e4e);
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    IUniswapV2Pair constant USDT_WETH = IUniswapV2Pair(0x0d4a11d5EEaaC28EC3F61d100daF4d40471f1852);
    
    uint256 public phase;
    bool public dydxSuccess;

    // Test: USDT/WETH flash → dYdX USDC flash (this is what fails for stage4)
    function testUSDTFlashThenDyDx() public {
        deal(USDC, address(this), 100e6); // for dYdX repayment
        IERC20(USDC).approve(address(SOLO), type(uint256).max);
        
        phase = 1;
        // Flash 1000 USDT from USDT/WETH pair
        USDT_WETH.swap(1000e6, 0, address(this), hex"01"); // USDT is token0
        
        assertTrue(dydxSuccess, "dYdX should have succeeded inside USDT callback");
    }

    function uniswapV2Call(address, uint256, uint256, bytes calldata) external {
        require(phase == 1, "unexpected phase");
        emit log("Inside USDT/WETH callback, trying dYdX...");
        
        // Try dYdX flash from inside USDT/WETH callback
        ISoloMargin.AccountInfo[] memory accounts = new ISoloMargin.AccountInfo[](1);
        accounts[0] = ISoloMargin.AccountInfo(address(this), 0);
        
        ISoloMargin.ActionArgs[] memory actions = new ISoloMargin.ActionArgs[](3);
        actions[0] = ISoloMargin.ActionArgs({
            actionType: ISoloMargin.ActionType.Withdraw, accountId: 0,
            amount: ISoloMargin.AssetAmount(false, ISoloMargin.AssetDenomination.Wei, ISoloMargin.AssetReference.Delta, 100e6),
            primaryMarketId: 2, secondaryMarketId: 0, otherAddress: address(this), otherAccountId: 0, data: ""
        });
        actions[1] = ISoloMargin.ActionArgs({
            actionType: ISoloMargin.ActionType.Call, accountId: 0,
            amount: ISoloMargin.AssetAmount(false, ISoloMargin.AssetDenomination.Wei, ISoloMargin.AssetReference.Delta, 0),
            primaryMarketId: 0, secondaryMarketId: 0, otherAddress: address(this), otherAccountId: 0, data: ""
        });
        actions[2] = ISoloMargin.ActionArgs({
            actionType: ISoloMargin.ActionType.Deposit, accountId: 0,
            amount: ISoloMargin.AssetAmount(true, ISoloMargin.AssetDenomination.Wei, ISoloMargin.AssetReference.Delta, 100e6 + 2),
            primaryMarketId: 2, secondaryMarketId: 0, otherAddress: address(this), otherAccountId: 0, data: ""
        });
        
        SOLO.operate(accounts, actions);
        dydxSuccess = true;
        
        // Repay USDT flash
        uint256 repay = 1000e6 * 1003 / 1000 + 1;
        deal(USDT, address(this), repay);
        IERC20(USDT).transfer(address(USDT_WETH), repay);
    }
    
    function callFunction(address, ISoloMargin.AccountInfo calldata, bytes calldata) external {
        emit log("dYdX callback reached!");
        uint256 bal = IERC20(USDC).balanceOf(address(this));
        emit log_named_uint("USDC in dYdX callback", bal);
    }
}
