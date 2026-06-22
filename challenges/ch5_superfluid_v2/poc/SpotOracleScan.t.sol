// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";

interface IFactory {
    function allLendingPoolsLength() external view returns (uint256);
    function allLendingPools(uint256) external view returns (address);
    function getLendingPool(address) external view returns (
        bool initialized,
        uint24 lendingPoolId,
        address collateral,
        address borrowable0,
        address borrowable1
    );
}

interface IBorrowable {
    function totalBalance() external view returns (uint256);
    function underlying() external view returns (address);
    function totalBorrows() external view returns (uint256);
}

interface ICollateral {
    function totalBalance() external view returns (uint256);
    function underlying() external view returns (address);
    function getPrices() external returns (uint256, uint256);
    function safetyMarginSqrt() external view returns (uint256);
    function simpleUniswapOracle() external view returns (address);
}

interface ISimpleUniswapOracle {
    function getResult(address uniswapV2Pair) external returns (uint224 price, uint32 T);
    function MIN_T() external pure returns (uint32);
}

interface IUniswapV2Pair {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves() external view returns (uint112, uint112, uint32);
    function price0CumulativeLast() external view returns (uint256);
    function price1CumulativeLast() external view returns (uint256);
}

interface IERC20 {
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
    function balanceOf(address) external view returns (uint256);
}

contract SpotOracleScanTest is Test {
    IFactory constant impermax = IFactory(0xBB92270716C8c424849F17cCc12F4F24AD4064D6);

    function test_checkImpermaxOracle() public {
        // Pool 4 has the largest TVL
        address lp4 = impermax.allLendingPools(4);
        (,, address coll,,) = impermax.getLendingPool(lp4);

        console.log("Pool 4 collateral:", coll);

        // Check if the collateral uses a simple oracle
        try ICollateral(coll).simpleUniswapOracle() returns (address oracle) {
            console.log("Oracle:", oracle);

            // Get price from oracle
            try ICollateral(coll).getPrices() returns (uint256 p0, uint256 p1) {
                console.log("Price0:", p0);
                console.log("Price1:", p1);
            } catch {
                console.log("getPrices failed");
            }

            // Check oracle MIN_T
            try ISimpleUniswapOracle(oracle).MIN_T() returns (uint32 minT) {
                console.log("MIN_T:", minT);
            } catch {
                console.log("no MIN_T");
            }
        } catch {
            console.log("No simpleUniswapOracle");
        }

        // Check Pool 16 (USDC pool, larger TVL)
        address lp16 = impermax.allLendingPools(16);
        (,, address coll16, address b0_16, address b1_16) = impermax.getLendingPool(lp16);
        console.log("Pool 16 collateral:", coll16);
        console.log("Pool 16 borrowable0:", b0_16);
        console.log("Pool 16 borrowable1:", b1_16);

        uint256 bal0 = IBorrowable(b0_16).totalBalance();
        uint256 bal1 = IBorrowable(b1_16).totalBalance();
        console.log("Pool 16 b0 balance:", bal0);
        console.log("Pool 16 b1 balance:", bal1);

        try ICollateral(coll16).simpleUniswapOracle() returns (address oracle16) {
            console.log("Pool 16 oracle:", oracle16);
        } catch {
            console.log("Pool 16 no oracle");
        }
    }

    // Check if Impermax uses TWAP that can be manipulated
    function test_impermaxOracleType() public {
        // Scan first 10 pools for oracle type
        uint256 len = impermax.allLendingPoolsLength();
        if (len > 10) len = 10;

        for (uint256 i = 0; i < len; i++) {
            address lp = impermax.allLendingPools(i);
            (bool init,, address coll,,) = impermax.getLendingPool(lp);
            if (!init) continue;

            try ICollateral(coll).simpleUniswapOracle() returns (address oracle) {
                // This uses a TWAP oracle based on Uniswap V2 pair prices
                // Check the MIN_T (minimum time between updates)
                try ISimpleUniswapOracle(oracle).MIN_T() returns (uint32 minT) {
                    try ICollateral(coll).getPrices() returns (uint256 p0, uint256 p1) {
                        if (p0 > 0 && p1 > 0) {
                            console.log("Pool", i, "TWAP oracle, MIN_T:", minT);
                            console.log("  prices:", p0, p1);
                        }
                    } catch {}
                } catch {}
            } catch {}
        }
    }
}
