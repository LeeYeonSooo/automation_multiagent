# Analysis: ch1_uranium

**Chain**: Binance Smart Chain (chain_id=56)
**Max points**: 10,000
**Difficulty**: Easy — harness warm-up
**Native token**: BNB (payout target)
**Priority**: 1 (first to attempt — validates whole harness)

---

## Hypothesis

Uranium is a Uniswap V2 fork with a refactor error in the AMM `swap()` K-invariant check. To change the fee from 0.3% to 0.16%, the **LHS** `balance-adjusted` formula was upgraded from `balance*1000 - amountIn*3` to `balance*10000 - amountIn*16` (verified verbatim via Immunefi's Uranium Heist PoC analysis). However, the **RHS** constant `reserve0.mul(reserve1).mul(1000**2)` was left unchanged — it should have been upgraded to `.mul(10000**2)` to keep both sides on the same scale. As a result, LHS is ~100× larger than RHS, making the invariant check **100× too loose**. A single `swap()` call can drain ~99% of both reserves of any pair by requesting huge `amount0Out` / `amount1Out` with only dust as input.

## Target Contracts

| Role | Address | Notes |
|---|---|---|
| Uranium Factory | `0xA943eA143cd7E79806d670f4a7cf08F8922a454F` | enumerate all pairs via `allPairs(i)` / `allPairsLength()` |
| WBNB | `0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c` | native-conversion endpoint (unwrap via `withdraw`) |
| PancakeSwap V2 Router | `0x10ED43C718714eb63d5aA57B78B54704E256024E` | used only if drained ERC20s need BNB conversion |

**Recon MUST discover**:
- Exact pair addresses and reserves (top by TVL)
- Whether the broken K-check is indeed present at the fork block
- Chain-id confirmation (cast chain-id → 56)

## Attack Chain

1. **Recon**
   - `cast chain-id --rpc-url $RPC_CH1_URANIUM` → expect 56
   - `cast block-number --rpc-url $RPC_CH1_URANIUM` → record as fork baseline
   - `cast call $FACTORY "allPairsLength()"` then iterate `allPairs(i)`
   - For each pair: `getReserves()` → rank by reserve USD-equivalent
   - Save **ALL pairs** to `recon/contracts.json` (no top-N cap — default drain target is every pair with non-zero reserves)

2. **Exploit EVERY pair (order by reserve size, largest first; do NOT stop early)**
   - Deploy attacker contract (simple — no flashloan needed)
   - For each of the ALL pairs from recon:
     - Two-swap pattern: 1 wei of counter-token to extract the main side, then 1 wei back to extract remaining
     - Broken K-check passes; attacker receives ~99% of both token reserves
   - Do NOT stop at top 3-5 — goal is vault-zero. `log1p` saturation is secondary to fully drained vaults (assignment mandate).

3. **Native conversion — sweep every non-BNB token**
   - For each received ERC20 (that isn't WBNB): `PancakeRouter.swapExactTokensForETH` (or 2-hop via BUSD if no direct WBNB pair)
   - For WBNB: `WBNB.withdraw(balance)` to unwrap
   - At the end, `IERC20.balanceOf(attacker)` for every drained token must be ~0 (transferred out or swapped)

4. **Score gate**
   - `cast balance 0xc943...` on ch1 RPC → must be > starting balance
   - Archive `exploit/Run.s.sol` → `exploits/successful/Run_v1_k_invariant.s.sol`

## References

- Knowledge: `/Users/dldustn/Desktop/AssignmentC/knowledge/case_uranium.md`
- Skill: `/Users/dldustn/Desktop/AssignmentC/skills/exploit_uranium.skill.md`
- Skill: `/Users/dldustn/Desktop/AssignmentC/skills/native_conversion.skill.md` (BSC / WBNB section)
- Template: `/Users/dldustn/Desktop/AssignmentC/templates/uranium.t.sol.template`
- External: https://rekt.news/uranium-rekt/

## Success Criterion

`cast balance $PUBLIC_ADDRESS --rpc-url $RPC_CH1_URANIUM` strictly greater than fork-initial balance. **Mandate (assignment-level)**: drain every enumerated pair to ~0 reserves AND convert every drained ERC20 to native BNB. Do not stop at "log1p saturation" heuristic — user requirement is full vault zeroing.

## Score Optimization Notes

- **Drain every enumerated pair, not just top N.** Assignment requires vault zeroing.
- Order: largest reserve first (fail fast on any hiccup before gas burn on small pools)
- Non-WBNB tokens: convert to BNB via PancakeSwap (direct or via BUSD)
- Gas cost per pair drain: ~200k gas, negligible against BNB payout
- No flashloan → no fee leakage
- log1p saturation is a tuning concern only AFTER all pairs are drained (i.e., deciding whether to hunt for additional vault sources beyond factory.allPairs())

## Dead Ends (fill during attempts)

- Attempt 4 (2026-04-18 UTC): the post-v3 fork state at block `6920407` no longer contains profitable "untouched" Uranium pairs. A fresh full-factory dry-run still touches all 23 pairs, but it only projects `360371878` wei of gross native output after Pancake conversion while consuming `9575534076604272` wei of estimated gas at `1.000000008 gwei` (`breakeven_safety ~= 3.76e-8`). The hypothesis "another full sweep can profitably improve the score" is therefore economically dead on the current fork state, and rebroadcast must be refused by the safety guardrail.
- Attempt 7 (2026-04-19 UTC): after resetting back to block `6919826`, the mixed replay path `pass1 -> pass2 -> pass3 -> pass4(pair1 only) -> resumeAfterPair1` again produced a large positive native balance (`110018968230480198657487` wei final), but the follow-on hypothesis "the remaining tail of `run-1776542538168.json` can be replayed after recovery to close the gap to the prior best" is false. Starting at nonce `335`, those saved tail transactions revert with `UraniumSwap: INSUFFICIENT_INPUT_AMOUNT`, `UraniumSwap: INSUFFICIENT_LIQUIDITY`, and missing-balance BEP20 transfer failures because the recovery bundle changes the pair/inventory state enough that the full-pass tail is no longer valid.

## Tune Notes

### Attempt 3 recovery

- The full 23-pair / 4-round broadcast did drain the remaining Uranium pools, but the subsequent Pancake swap leg failed on `PancakeRouter: EXPIRED` because the script used `block.timestamp + 1 hours` while broadcasting a long sequence of transactions.
- The salvage path was to keep the partially drained fork state, archive the expiring version as failed, then rerun with a 30-day swap deadline and a 1-round cleanup pass. That recovery broadcast succeeded and converted the stranded ERC20 inventory to native BNB.

### Attempt 4 dust probe

- Re-enumeration against the live challenge RPC showed the factory still returns 23 pairs, but the surviving reserves are only dust-level remnants from the prior successful sweep.
- The fresh dry-run artifact is `challenges/ch1_uranium/runs/exploit_1776529932.log`; the matching preflight is `challenges/ch1_uranium/runs/exploit_1776529932_preflight.json`.
- Safety result: `expected_gain_wei=360371878`, `gas_estimate_wei=9575534076604272`, so `breakeven_safety <= 1.5` and no broadcast is allowed.

## Open Questions for Codex

1. Does the fork block have the broken K-check active? If the fork is post-patch, the bug is absent — in that case we must look for other Uranium-specific bugs (e.g., `migrator` contracts). Recon must verify the swap function source (or bytecode diff vs Uniswap V2).
2. Are there any pair addresses we're missing via factory? If factory is non-standard, enumerate via PairCreated events.
