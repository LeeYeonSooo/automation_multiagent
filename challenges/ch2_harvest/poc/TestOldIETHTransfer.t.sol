// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import "forge-std/console.sol";

interface IOldIETH {
    function mintWithEther(address) external payable returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

contract TestOldIETHTransfer is Test {
    IOldIETH constant iETH = IOldIETH(0x77f973FCaF871459aa58cd81881Ce453759281bC);
    
    function test_transferToSelf() public {
        address user = makeAddr("user");
        vm.deal(user, 10 ether);
        
        vm.startPrank(user);
        
        // Mint
        iETH.mintWithEther{value: 1 ether}(user);
        uint256 bal = iETH.balanceOf(user);
        console.log("Balance after mint:", bal);
        
        // Try transfer to self
        bool success = iETH.transfer(user, bal);
        console.log("Transfer success:", success);
        
        uint256 balAfter = iETH.balanceOf(user);
        console.log("Balance after transfer:", balAfter);
        console.log("Duplicated?", balAfter > bal);
        
        vm.stopPrank();
    }
    
    function test_transferFromToSelf() public {
        address user = makeAddr("user");
        vm.deal(user, 10 ether);
        
        vm.startPrank(user);
        
        // Mint
        iETH.mintWithEther{value: 1 ether}(user);
        uint256 bal = iETH.balanceOf(user);
        console.log("Balance after mint:", bal);
        
        // Approve self
        iETH.approve(user, bal);
        
        // Try transferFrom self to self
        bool success = iETH.transferFrom(user, user, bal);
        console.log("TransferFrom success:", success);
        
        uint256 balAfter = iETH.balanceOf(user);
        console.log("Balance after transferFrom:", balAfter);
        console.log("Duplicated?", balAfter > bal);
        
        vm.stopPrank();
    }
}
