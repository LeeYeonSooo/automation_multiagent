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
    function exitMarket(address) external returns (uint256);
    function getAccountLiquidity(address) external view returns (uint256, uint256, uint256);
}

/// @dev Simplified: just mint fETH, enter market, then call exitMarket directly (no reentrancy)
contract SimpleExitTest is Test {
    address constant COMPTROLLER = 0x814b02C1ebc9164972D888495927fe1697F0Fb4c;
    address constant F6_ETH = 0xF6551C22276b9Bf62FaD09f6bD6Cad0264b89789;

    function setUp() public {
        vm.createSelectFork(vm.envString("RPC_CH3_FEIRARI"));
    }

    function test_direct_exit_market() public {
        vm.deal(address(this), 100 ether);

        // Mint
        ICEther(F6_ETH).mint{value: 10 ether}();
        console.log("cBal:", ICEther(F6_ETH).balanceOf(address(this)));

        // Enter market
        address[] memory m = new address[](1);
        m[0] = F6_ETH;
        IComptroller(COMPTROLLER).enterMarkets(m);

        // Exit immediately (no borrows)
        uint256 code = IComptroller(COMPTROLLER).exitMarket(F6_ETH);
        console.log("exitMarket result:", code);

        // Redeem all
        uint256 bal = ICEther(F6_ETH).balanceOf(address(this));
        uint256 r = ICEther(F6_ETH).redeem(bal);
        console.log("Redeem result:", r);
        console.log("ETH recovered:", address(this).balance / 1e18);
    }

    receive() external payable {}
}
