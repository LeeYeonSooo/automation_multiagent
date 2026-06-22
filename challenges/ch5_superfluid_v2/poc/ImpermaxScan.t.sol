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
    function totalSupply() external view returns (uint256);
}

interface IERC20 {
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
    function balanceOf(address) external view returns (uint256);
}

interface ICollateral {
    function totalBalance() external view returns (uint256);
    function underlying() external view returns (address);
    function totalSupply() external view returns (uint256);
    function safetyMarginSqrt() external view returns (uint256);
    function liquidationIncentive() external view returns (uint256);
}

contract ImpermaxScanTest is Test {
    IFactory constant factory = IFactory(0xBB92270716C8c424849F17cCc12F4F24AD4064D6);

    function test_scanPools() public view {
        uint256 len = factory.allLendingPoolsLength();
        console.log("Total pools:", len);

        for (uint256 i = 0; i < len; i++) {
            address lp = factory.allLendingPools(i);
            (bool init, uint24 id, address coll, address b0, address b1) = factory.getLendingPool(lp);
            if (!init) continue;

            uint256 bal0 = IBorrowable(b0).totalBalance();
            uint256 bal1 = IBorrowable(b1).totalBalance();

            // Only show pools with significant balance
            if (bal0 > 1e18 || bal1 > 1e6) {
                address u0 = IBorrowable(b0).underlying();
                address u1 = IBorrowable(b1).underlying();
                string memory s0 = IERC20(u0).symbol();
                string memory s1 = IERC20(u1).symbol();

                console.log("---");
                console.log("Pool", i, "LP:", lp);
                console.log(s0, bal0);
                console.log(s1, bal1);
            }
        }
    }
}
