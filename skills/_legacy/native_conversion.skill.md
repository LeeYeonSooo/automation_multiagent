# native_conversion.skill.md

Primary consumer: Codex. Read during every `exploit` task — the success metric is **native token balance only**.

`knowledge/scoring_model.md` is explicit: ERC20 profits count zero. A 10 M USDC stash earns zero score unless you convert it to ETH/POL/BNB and leave it on your EOA.

---

## 1. Why this matters (and why it's often where score is lost)

Score formula:
```
score = minmax_scale(log1p(attacker_native_balance_delta), 0.01, 1) × max_pts
```

Two observations from `knowledge/scoring_model.md`:
1. `log1p` means 100× raw profit is only ~2× score. **The first order-of-magnitude jump matters most.** Always convert — even an inefficient conversion that keeps 50% of theoretical profit still dominates "keep it in USDC".
2. `minmax` means relative. If your competitor converted 0.9 ETH and you converted 1.0 ETH, you get max_pts × 1.0, they get barely above 0.01. So squeeze slippage down; don't leave 10% on the table.

The common mistake: PoC shows 500k USDC profit, exploit Run.s.sol ends by `console.log(USDC.balanceOf(attacker))` and celebrates. The `cast balance $ATTACKER` check at the end of the flow is flat. Score: near zero.

---

## 2. Per-chain conversion recipe

### 2.1 Ethereum (chain_id 1) — ch2_harvest, ch3_feirari

**WETH wrap/unwrap**:
- Address: `0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2`
- Unwrap: `WETH.withdraw(uint256 amount)` — sends ETH to `msg.sender`
- Wrap: `WETH.deposit{value: amount}()` (you rarely need this in our exploits)

**Uniswap V2 Router02** (`0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D`):
- Deepest liquidity for stablecoin → WETH on-chain (most of our ERC20 profits are USDC/USDT/DAI).
- Function: `swapExactTokensForETH(amountIn, amountOutMin, path, to, deadline)` — this already unwraps WETH to ETH at the end. No manual `withdraw` needed.
- Path examples: `[USDC, WETH]`, `[USDT, WETH]`, `[DAI, WETH]`.

**Uniswap V3 Router** (`0xE592427A0AEce92De3Edee1F18E0157C05861564`):
- Sometimes better pricing on large USDC→ETH swaps (0.05% fee tier).
- Function: `exactInputSingle((tokenIn, tokenOut, fee, recipient, deadline, amountIn, amountOutMinimum, sqrtPriceLimitX96))`
- Plus `WETH.withdraw()` afterward since V3 doesn't auto-unwrap — OR use `unwrapWETH9` via the multicall pattern.

Sample (Ethereum, USDC → ETH via Uniswap V2):

```solidity
IERC20   constant USDC   = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
IUniRouter constant ROUTER = IUniRouter(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D);
address  constant WETH   = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

uint256 amt = USDC.balanceOf(address(this));
USDC.approve(address(ROUTER), amt);
address[] memory path = new address[](2);
path[0] = address(USDC); path[1] = WETH;
uint256[] memory out = ROUTER.swapExactTokensForETH(
    amt,
    0,                         // amountOutMin — see slippage section below
    path,
    ATTACKER_EOA,              // ETH arrives here, already unwrapped
    block.timestamp + 300
);
```

### 2.2 Polygon (chain_id 137) — ch4_superfluid, ch5_superfluid_v2

Native token: **POL** (previously branded MATIC, same thing on-chain).

**WMATIC** (`0x0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270`):
- Unwrap: `WMATIC.withdraw(amount)` — sends MATIC/POL to caller.

**SuperToken → underlying → native** chain (Superfluid-specific):
- SuperTokens like `USDCx` / `MATICx` must first be "downgraded" to their underlying.
- `MATICx.downgradeToETH(wad)` → sends native MATIC directly (it's the SETH-style wrapper, see `reference/IDAUsage_t.sol`).
- `USDCx.downgrade(wad)` → gives plain `USDC`, then swap to MATIC.

**QuickSwap V2 Router** (`0xa5E0829CaCEd8fFDD4De3c43696c57F7D7A678ff`):
- Uniswap V2 fork. Deepest POS liquidity. Use like UniV2.
- Function: `swapExactTokensForETH(amountIn, amountOutMin, path, to, deadline)`.

**SushiSwap Polygon Router** (`0x1b02dA8Cb0d097eB8D57A175b88c7D8b47997506`):
- Backup if QuickSwap path is thin.

Sample (Polygon, USDCx → MATIC):

```solidity
ISuperToken constant USDCX = ISuperToken(0xCAa7349CEA390F89641fe306D93591f87595dc1F);
IERC20      constant USDC  = IERC20(0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174);
IUniRouter  constant QUICK = IUniRouter(0xa5E0829CaCEd8fFDD4De3c43696c57F7D7A678ff);
address     constant WMATIC= 0x0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270;

uint256 xBal = USDCX.balanceOf(address(this));
USDCX.downgrade(xBal);
uint256 uBal = USDC.balanceOf(address(this));
USDC.approve(address(QUICK), uBal);
address[] memory path = new address[](2);
path[0] = address(USDC); path[1] = WMATIC;
QUICK.swapExactTokensForETH(uBal, 0, path, ATTACKER_EOA, block.timestamp + 300);
```

For the Superfluid IDA win path (ch4/ch5): if you drain MATICx itself, downgrade directly to MATIC and you're done:

```solidity
ISETH MATICX = ISETH(0x3aD736904E9e65189c3000c7DD2c8AC8bB7cD4e3);
MATICX.downgradeToETH(MATICX.balanceOf(address(this)));
// native MATIC is now in address(this); forward to ATTACKER_EOA
```

### 2.3 BSC (chain_id 56) — ch1_uranium

Native token: **BNB**.

**WBNB** (`0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c`):
- Unwrap: `WBNB.withdraw(amount)`.

**PancakeSwap V2 Router** (`0x10ED43C718714eb63d5aA57B78B54704E256024E`):
- Deepest BSC liquidity. Uniswap V2 fork with 0.25% fee.
- Function: `swapExactTokensForETH(...)` — same interface.

Note that Uranium Finance is itself a UniV2 fork on BSC. After draining Uranium's pair you'll already hold WBNB and/or BUSD/USDT/ETH(BSC). WBNB → unwrap, everything else → PancakeSwap to WBNB → unwrap.

Sample (BSC, BUSD → BNB):

```solidity
IERC20     constant BUSD = IERC20(0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56);
IUniRouter constant PANCAKE = IUniRouter(0x10ED43C718714eb63d5aA57B78B54704E256024E);
address    constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;

uint256 bal = BUSD.balanceOf(address(this));
BUSD.approve(address(PANCAKE), bal);
address[] memory path = new address[](2);
path[0] = address(BUSD); path[1] = WBNB;
PANCAKE.swapExactTokensForETH(bal, 0, path, ATTACKER_EOA, block.timestamp + 300);
```

---

## 3. Best-path heuristic

Algorithm for choosing how to convert a token X to native N on chain C:

1. **Is X the wrapped native (WETH/WMATIC/WBNB)?** Call `X.withdraw(amount)`. Done.
2. **Is X a SuperToken?** Call `X.downgrade` (or `downgradeToETH` if SETH-type). Recurse on the underlying.
3. **Is there a direct `[X, WNATIVE]` pair on the chain's primary UniV2 router?** Check `router.factory().getPair(X, WNATIVE)` returns non-zero. If pair reserves > `5 × amountIn`, use it.
4. **Is X a stablecoin (USDC/USDT/DAI)?** Use `[X, WNATIVE]` directly on primary router.
5. **Two-hop via USDC or common quote:** `[X, USDC, WNATIVE]`. Works for most long-tail tokens.
6. **Three-hop:** `[X, someMajor, USDC, WNATIVE]`. Rare. Profile slippage first.

Reserve check helper:

```solidity
function _reserves(IUniRouter router, address a, address b) internal view returns (uint112 r0, uint112 r1) {
    address pair = IUniFactory(router.factory()).getPair(a, b);
    require(pair != address(0), "no pair");
    (r0, r1, ) = IUniPair(pair).getReserves();
    if (a > b) (r0, r1) = (r1, r0);  // canonical order
}
```

If `amountIn > reserves[X] / 5`, your swap will cost >15% to slippage. Split: swap in chunks of `reserves[X] / 10` across multiple txs, or switch routers.

---

## 4. Slippage, `amountOutMin`, and when to fake it to zero

`swapExactTokensForETH(..., amountOutMin, ...)` reverts if output < `amountOutMin`.

For a fork exploit, you **can** set `amountOutMin = 0` because:
- No one else sees the mempool (isolated fork).
- Failed attempts cost nothing (reset available).

For the **production exploit** where you want maximum native balance:

```solidity
// Read expected output from router
uint256[] memory amounts = ROUTER.getAmountsOut(amtIn, path);
uint256 expected = amounts[amounts.length - 1];
// Allow 2% slippage
uint256 amountOutMin = (expected * 98) / 100;
```

Setting `amountOutMin = 0` in production isn't risky here (isolated fork, no sandwich bots) but it masks bugs — if your path is wrong, a 0-min call silently gives you 1 wei. Always log the ratio:

```solidity
require(out[out.length-1] * 100 / amtIn >= expectedRatio, "slippage too high");
```

---

## 5. Pitfalls

### 5.1 Fee-on-transfer tokens
Some BSC tokens (reflection tokens) charge 1-5% on transfer. Uniswap V2 `swapExactTokens...` reverts with `INSUFFICIENT_OUTPUT_AMOUNT` because the router's balance-delta accounting breaks.

Fix: use the `supportingFeeOnTransferTokens` variant:

```solidity
ROUTER.swapExactTokensForETHSupportingFeeOnTransferTokens(
    amtIn, 0, path, to, block.timestamp + 300
);
```

You generally don't see these in our challenge protocols but if a swap reverts with exactly `INSUFFICIENT_OUTPUT_AMOUNT` and input is a long-tail token — try this variant.

### 5.2 USDT approve quirk (Ethereum)
`USDT.approve` reverts if current allowance is non-zero. Always reset first:

```solidity
USDT.approve(spender, 0);
USDT.approve(spender, amount);
```

### 5.3 ETH stuck inside a contract
If your exploit contract receives ETH but never forwards it, `cast balance $ATTACKER_EOA` is flat. Always end exploits with:

```solidity
// in your attacker contract
function sweep() external {
    (bool ok, ) = ATTACKER_EOA.call{value: address(this).balance}("");
    require(ok, "sweep failed");
}
```

And call `attacker.sweep()` from the Run.s.sol script before exit. Also implement `receive() external payable {}` so the contract can accept ETH from `WETH.withdraw` and router `swapExactTokensForETH`.

### 5.4 SuperToken `downgradeTo` rounding
Superfluid's internal math uses 18 decimals. If the underlying has 6 decimals (USDC), you lose 12 decimal places of rounding each downgrade. Call `downgrade` with a round number or accept dust.

### 5.5 Dust
After the conversion, ERC20 balances should be near zero. `cast balance $ATTACKER --rpc-url chN` is what scores. Log it at the end of Run.s.sol:

```solidity
console.log("Final attacker native balance:", ATTACKER_EOA.balance);
```

---

## 6. End-of-exploit checklist

- [ ] Every ERC20 profit path ends with a swap to WNATIVE or direct to native
- [ ] WNATIVE balance is unwrapped (`.withdraw`) before script exit
- [ ] ETH/POL/BNB sits on the attacker EOA, not on any intermediate contract
- [ ] `console.log` prints the final native balance delta
- [ ] `cast balance $PUBLIC_ADDRESS --rpc-url ch<N>` confirms the delta post-broadcast
- [ ] `status.json.balance_delta_wei` is set to the exact delta in wei
