# Analysis: ch2_harvest

**Chain**: Ethereum (chain_id=1)
**Max points**: 10,000
**Difficulty**: Medium — requires parameter tuning (iteration count, swap size)
**Native token**: ETH (payout target)
**Priority**: 3 (after ch1 & ch3 — tuning takes longer)

---

## Hypothesis

Harvest Finance's `HVault` computes user share pricing via `underlyingBalanceWithInvestment()`, which delegates to `CurveStrategy.investedUnderlyingBalance()`, which in turn queries `yCurve.getPricePerFullShare()` and `calc_withdraw_one_coin()`. These values reflect the **live Curve pool ratio** — and Curve pool ratios are manipulable within a single tx via large stableswaps.

Attack: within one flash-swap callback, **pump** USDT price on Curve (USDC→USDT), **deposit** USDT into Harvest fUSDT vault (getting inflated share count), **dump** USDT back (restoring pool), **withdraw** from Harvest (now redeeming inflated shares at normal price) — netting the arbitrage delta. Repeat to bypass the ±3% arbitrage guard (which only catches per-tx movement, not cumulative).

## Target Contracts

| Role | Address | Notes |
|---|---|---|
| HVault (fUSDT) | `0x053c80eA73Dc6941F518a68E2FC52Ac45BDE7c9C` | the proxy Codex will call `deposit`/`withdraw` on |
| fUSDT implementation (at fork time) | `0x9B3bE0cC5dd26Fd0254088D03d8206792715588b` | target of `delegatecall` — EIP-1967 lookup if needed |
| CurveStrategy | `0x1C47343eA7135c2bA3B2d24202AD960aDaFAa81c` | `investedUnderlyingBalance()` price-origin |
| yCurve vault | `0x45F783CCE6B7FF23B2ab2D70e416cdb7D6055f51` | `getPricePerFullShare` + `calc_withdraw_one_coin` |
| UniV2 USDT/WETH flash pair | `0x0d4a11d5EEaaC28EC3F61d100daF4d40471f1852` | source of flash-borrow (50M USDT historical) |
| UniV2 USDC/WETH flash pair | `0xB4e16d0168e52d35CaCD2c6185b44281Ec28C9Dc` | source of flash-borrow (10M USDC historical) |
| USDT (ERC20) | `0xdAC17F958D2ee523a2206206994597C13D831ec7` | note: no return-value on transfer; use SafeERC20 or low-level |
| USDC (ERC20) | `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48` | standard ERC20 |
| Curve yUSD pool | derive via yCurve / CurveStrategy getter | the pool whose ratio we manipulate |
| UniV3 USDT/WETH 0.05% pool | `0x11b815efB8f581194ae79006d24E0d814B7697F6` | low-slippage native-conversion path |
| WETH | `0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2` | unwrap to ETH |

## Attack Chain

1. **Recon**
   - Confirm fork block has vulnerable HVault implementation (not post-patch)
   - Fetch HVault ABI, identify `deposit` / `withdraw` signatures
   - Identify Curve yUSD pool address via `CurveStrategy.strategy()` or storage read
   - Compute pool's per-token balance at fork block

2. **Flash borrow setup** (via UniV2 flash-swap, not Aave — zero upfront, repay 0.3%)
   - In attacker contract: `pair.swap(amount0Out, amount1Out, attacker, data)` on USDT/USDC pair
   - UniV2 calls back to `uniswapV2Call(sender, amount0, amount1, data)` — exploit body here
   - At end of callback, transfer `amountBack = amountIn * 1000 / 997` (0.3% fee) back to pair

3. **Exploit body** (inside `uniswapV2Call`, one iteration)
   - Swap USDC → USDT on Curve yUSD pool (pumps USDT share price)
   - Deposit USDT into HVault → receives inflated `fUSDT` shares
   - Swap USDT → USDC on Curve (dumps USDT back to ~original ratio)
   - Withdraw inflated `fUSDT` → receives more USDT than deposited
   - Loop N times (tunable; historical N=17 per rekt.news)

4. **Parameter tuning**
   - swap size: just under the `±3% arbitrage guard` threshold per iter (Harvest rejects if pool price dev > 3%)
   - iteration count N: optimize profit = Σ(iter_gain) − flash_fee − gas. Binary search 1..50
   - depositAmt: typically = full pumped USDT amount each iter

5. **Repay + native convert**
   - Repay flash swap (USDT + fee back to UniV2 pair)
   - Convert net USDT profit → WETH via UniV3 USDT/WETH 0.05% pool (low slippage)
   - Unwrap WETH → ETH

6. **Score gate**
   - `cast balance 0xc943...` on ch2 RPC increases
   - Archive production script to `exploits/successful/Run_v<N>_curve_oracle.s.sol`

## References

- Knowledge: `/Users/dldustn/Desktop/AssignmentC/knowledge/case_harvest.md`
- Skill: `/Users/dldustn/Desktop/AssignmentC/skills/exploit_harvest.skill.md`
- Skill: `/Users/dldustn/Desktop/AssignmentC/skills/flash_loan.skill.md` (UniV2 flash-swap pattern)
- Skill: `/Users/dldustn/Desktop/AssignmentC/skills/native_conversion.skill.md` (USDT→WETH path)
- Template: `/Users/dldustn/Desktop/AssignmentC/templates/harvest.t.sol.template`
- External: https://rekt.news/harvest-finance-rekt/, attacker tx `0x35f8d2f572fceaac9288e5d462117850ef2694786992a8c3f6d02612277b0877`

## Success Criterion

`cast balance $PUBLIC_ADDRESS --rpc-url $RPC_CH2_HARVEST` strictly greater than fork-initial balance. **Mandate**: drain the HVault and any other Harvest vaults on this fork to ~0 underlying, then convert every drained USDT/USDC/FARM/leftover to native ETH. Partial drain is NOT acceptable.

## Score Optimization Notes

- The ±3% guard caps per-iter gain; bypass by **staying just below threshold**, not exceeding
- Mentor lecture: 17 iterations in real attack, ~$24M net. Target here: run until `HVault.underlyingBalanceWithInvestment()` ≈ 0 AND per-iter revert (whichever first).
- Iteration count: keep going until `marginal_profit_per_iter < gas_cost_per_iter` AND vault appears empty. Do NOT stop early on log1p heuristic.
- Multiple Harvest vaults on fork (fUSDT, fUSDC, fDAI if present) — attack each, not just fUSDT
- If pool liquidity limits swap size, switch flash provider (Balancer 0% for USDC, or split across pairs)
- Gas per iteration: ~500k; at 50 gwei × N=1000 ≈ 25 ETH cost — still small vs multi-thousand ETH payout

## NEW HYPOTHESIS: fTUSD Self-Funded Drain (2026-04-19)

### 1. 취약점 코드 경로
- fTUSD vault (0x7674622c63Bee7F46E86a4A5A18976693D54441b)의 `deposit()`/`withdraw()`
- CurveStrategy (0x9D356Fda8437f7c7B6A4BC84466a98A4A6Eec462)의 `investedUnderlyingBalance()`
- Curve yPool (0x45F783CCE6B7FF23B2ab2D70e416cdb7D6055f51) `exchange_underlying(1, 3, ...)` (USDC→TUSD)
- 동일한 oracle manipulation 취약점이 fUSDT와 동일하게 fTUSD에 적용

### 2. 왜 exploitable한가
- fTUSD vault에 38.2M TUSD ($38M) 미사용 상태
- Curve yPool에 79.7M TUSD, 58.7M USDC — manipulation 가능한 규모
- depositArbCheck() = true (현재 풀이 균형 상태)
- 동일한 pump-deposit-dump-withdraw 공격 패턴 적용 가능

### 3. 이전 시도 실패 원인과 해결책
- **이전 실패**: outerFlash = 5M TUSD 설정 → UniV2 TUSD/WETH pair에 380K TUSD만 존재 → 유동성 부족
- **해결**: self-fund 방식으로 전환
  1. 현재 보유 ETH (~27,677) 중 일부를 TUSD로 변환 (UniV2 ETH→TUSD 또는 Curve 경유)
  2. outerFlash = 1 wei (최소) 또는 380K 이내로 설정
  3. innerFlash = USDC (UniV2 USDC/WETH pair 304M USDC 유동성, 충분)
  4. self-funded TUSD를 dump buffer로 활용

### 4. 공격 단계
1. ETH → TUSD 변환: ~500 ETH → ~200K TUSD (UniV2)
2. TUSD를 새 SelfFundedFTUSDDrain contract에 전송
3. innerFlash = ~10M USDC (UniV2 USDC/WETH)
4. Loop (N회):
   a. PUMP: exchange_underlying(USDC=1, TUSD=3, pumpSize, 0) → TUSD 구매 (풀에서 TUSD 감소 → vault 가격 하락)
   b. DEPOSIT: vault.deposit(receivedTUSD) → 낮은 가격에 더 많은 shares
   c. DUMP: exchange_underlying(TUSD=3, USDC=1, dumpSize, 0) → TUSD 매도 (풀 복원 → vault 가격 상승)
   d. WITHDRAW: vault.withdraw(shares) → 높은 가격에 더 많은 TUSD
5. TUSD profit → USDC (Curve) → WETH (UniV2) → ETH

### 5. 제약 조건
- TUSD flash loan 불가 → self-fund 필요 (500 ETH 소모)
- pump/dump size: ~300K-500K per iteration (arb guard 3% threshold 이내)
- Curve pool TUSD/USDC balance에 따라 최적 pumpSize 결정 필요

### 6. 성공 판정
- fTUSD vault underlyingBalanceWithInvestment ≈ 0
- EOA native balance > 27,677 + 38M/400 = ~120,000+ ETH (이론적 최대)

### 7. 구현 방법
- `CurrentFTUSDDrain` 기반으로 `SelfFundedFTUSDDrain` 변형 작성
- 또는 기존 코드에서 outerFlash를 1 wei로 줄이고, execute 전에 contract에 TUSD self-fund
- pumpSize/dumpSize를 300K-500K 범위로 조정
- iterations = 7-10 per execute call, 반복 실행

## NEW HYPOTHESIS: fUSDC Drain via DAI-funded Curve Oracle Manipulation (2026-04-20)

### 1. 취약점 코드 경로 (verified)
- fUSDC vault (0xf0358e8c3CD5Fa238a29301d0bEa3D63A17bEdBE) `deposit()`/`withdraw()`
- fUSDC strategy (0xD55aDA00494D96CE1029C201425249F9dFD216cc) `investedUnderlyingBalance()`
- Strategy holds yUSDC (coin 1) in Curve yPool -> `calc_withdraw_one_coin()`
- Same oracle manipulation vulnerability as fUSDT

### 2. 왜 exploitable한가 (verified with forge test)
- fUSDC vault: 134M USDC total. 52.4M invested in strategy (39%), 81.3M in vault
- DAI->USDC pump on Curve (index 0->1) changes pool ratio, affecting `calc_withdraw_one_coin` for yUSDC
- 19M DAI pump: PPFS drops 980074 -> 978881 (-0.12%), net profit +84.7K per iteration
- **forge test PASSED**: `TestFUSDCDrain.testExecute10()` confirms ~954K USDC drain per 10 iterations
- Full flash loan (19M DAI from UniV2 + 19M USDC from UniV2) is profitable after 0.3% fees

### 3. 공격 단계 (verified)
1. Deploy `FUSDCDrain` contract (exploit/FUSDCDrain.sol)
2. Call `execute(19M DAI, 19M USDC, 10)`:
   a. Flash borrow 19M DAI from UniV2 DAI/WETH (token0, 220M available)
   b. Flash borrow 19M USDC from UniV2 USDC/WETH (token0, 308M available)
   c. Loop 10x: pump(ALL DAI -> USDC), deposit(USDC), dump(19M USDC -> DAI), withdraw
   d. Convert excess USDC -> DAI to cover DAI shortfall
   e. Repay USDC flash, repay DAI flash
3. Call `sweep()` to convert USDC+DAI profits to ETH via UniV2 Router
4. Repeat steps 2-3 ~140 times until vault is empty

### 4. Key difference from previous attempts
- Previous `CurrentFUSDCDrain` used fixed `pumpSize=10M DAI` -> net NEGATIVE per iteration
- Previous `BigFUSDCNoDyDx` used 50M DAI -> `calc_withdraw_one_coin` REVERTS
- **This approach**: 19M DAI pump (sweet spot), FULL balance pump per iteration (not fixed)
- Custom `FUSDCDrain.sol` pumps entire DAI balance each iteration, adapting to slippage

### 5. 제약 조건
- Gas: execute(10) = ~11.67M gas, fits in block limit (12.4M)
- Max pump: 19M DAI (19.5M+ causes calc_withdraw_one_coin revert)
- Full drain: ~140 execute(10) calls needed for 134M USDC
- RPC stability: need consistent endpoint (fork resets are free, historical max preserved)

### 6. 성공 판정
- fUSDC vault underlyingBalanceWithInvestment ≈ 0
- EOA native balance increases by 134M USDC / 412.56 USDC/ETH ≈ 324,805 ETH

### 7. 구현 파일
- `exploit/FUSDCDrain.sol` - standalone drain contract
- `exploit/RunFUSDC.s.sol` - forge script for deployment
- `exploit/run_fusdc_drain.sh` - production shell script
- `poc/TestFUSDCDrain.t.sol` - forge test (PASSED)

## DEAD_END: fTUSD not profitable (2026-04-20)
- Only 13% of fTUSD assets invested in strategy -> oracle manipulation too weak
- USDC->TUSD pump: -14.3K net loss per iteration
- DAI->TUSD pump: -13.3K net loss per iteration
- doHardWork requires governance auth (EOA 0xf00dD244...); cannot impersonate on live fork
- fTUSD drain requires either (a) governance impersonation or (b) different vulnerability

## Dead Ends (fill during attempts)

## DEAD_END (attempt 2)
Hypothesis: the corrected small-swap Harvest loop can be funded with Aave V2 USDC+USDT at the fork block.
Why it's wrong: the fork is pinned to Ethereum block `11,128,633` on October 26, 2020, and the configured Aave V2 lending-pool address `0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9` has no code there. The run fails immediately with `call to non-contract address 0x7d2768...`.
What we observed instead: the Curve/Harvest path itself is viable. `Attempt2.t.sol` confirmed `exchange_underlying` with `underlying_coins(1)=USDC` and `underlying_coins(2)=USDT`, tuned the loop to `swapSize=5,000,000e6` plus a `10,000e6` USDT reserve, and the previewed 10-iteration path stayed live with about `29,128,834,882` gross USDT-equivalent profit before funding costs.
Suggested next direction: keep the tuned Harvest loop but switch the flash source to something that existed on October 26, 2020 at block `11,128,633` (for example dYdX solo margin, Aave V1, or a Uniswap V2 flash-swap split across stable pairs).

## Attempt Notes

### Attempt 1

- `Attempt1.t.sol` used Aave V2 multi-asset flash loans (`USDC + USDT`) and a snapshot-based binary search that only checked `CurveStrategy.depositArbCheck()`.
- The probe incorrectly concluded that a `20,000,000 USDC` pump still fit under the ±3% guard.
- The first previewed `fUSDT.deposit()` reverted anyway, with the trace failing in:
  - `PriceConvertor.calc_withdraw_one_coin`
  - `HarvestStrategy.investedUnderlyingBalance`
  - `Vault.deposit`
- Observation: `depositArbCheck()` is a necessary bound, but not a sufficient tuning oracle for deposit safety. The next attempt should binary-search against the full `pump -> deposit` path, likely with a smaller `swapSize` and possibly a lower `depositAmt`.

### Attempt 2

- `Attempt2.t.sol` verified the yPool metadata directly on the fork:
  - `coins(0..3)` = yDAI / yUSDC / yUSDT / yTUSD
  - `underlying_coins(0..3)` = DAI / USDC / USDT / TUSD
- The corrected loop uses `exchange_underlying(USDC=1, USDT=2)`, deposits only the freshly pumped USDT, and keeps an explicit USDT reserve for the reverse swap.
- Direct path probing over `1,000,000e6` to `5,000,000e6` showed the best safe single-iteration size in the tested window was `5,000,000e6`.
- With a `10,000e6` USDT reserve, the previewed 10-iteration loop remained stable and produced about `29,128,834,882` gross USDT-equivalent profit before flash fees and gas.
- The live Aave-backed execution still failed immediately because the specified Aave V2 pool address was not deployed at this fork block. This is a funding-source dead end, not a Harvest-path dead end.

### Attempt 3

- `Attempt3.t.sol` replaced the missing Aave V2 source with a nested Uniswap V2 flash-swap:
  - outer flash: `USDT/WETH` pair `0x0d4a11d5EEaaC28EC3F61d100daF4d40471f1852`
  - inner flash: `USDC/WETH` pair `0xB4e16d0168e52d35CaCD2c6185b44281Ec28C9Dc`
- The pair orientations were confirmed on the fork:
  - `USDT/WETH`: `token0 = WETH`, `token1 = USDT`
  - `USDC/WETH`: `token0 = USDC`, `token1 = WETH`
- Tuning over the full requested `5M-20M` USDC window showed the full `pump -> deposit -> dump -> withdraw` path reverted for `11M-20M` in the one-iteration probe. The largest safe tested size was `10,000,000e6`.
- With `swapSize = 10,000,000e6`, `flashUsdt = 50,000,000e6`, `flashUsdc = 10,000,000e6`, and `N = 20`, the PoC passed end-to-end:
  - gross stable profit before pair repayments: `1,721,293,877,231` USDT-equivalent
  - final leftover after both UniV2 repayments: `1,400,545,986,342` USDT and `140,313,878,935` USDC
  - final native balance delta after UniV2 stable→ETH conversion: `3,762,680,102,193,243,883,244` wei
- The root cause is confirmed: Attempt2's blocker was only the missing Aave V2 funding source. UniV2 funding works cleanly with the already-tuned Curve/Harvest loop.
- Production note: the passing PoC includes in-test tuning and verbose logging, so `forge test` reported `103,207,503` gas while the fork block gas limit is only `12,433,001`. The next exploit script should hardcode the chosen parameters and strip tuning/log-heavy scaffolding before broadcast, and may need multi-tx sequencing if the lean path still exceeds block gas.

### Attempt 4 / Production Execution

- `Attempt4.t.sol` measured the stripped `HarvestDrain.execute(N)` path directly on the live fork and showed that:
  - `execute(7)` used about `11,184,314` gas and fit under the live block gas limit
  - `execute(8)` and above exceeded the block gas limit
- `forge script` local execution stalled before broadcasting on this fork, so production used the exact same compiled `HarvestDrain` bytecode from `exploit/Run.s.sol` via direct deployment plus `cast send` calls.
- Live execution succeeded for `35` consecutive `execute(7)` chunks:
  - deployment tx: `0xdd618cda312d3bccf3edc12e13b2edbda96a0a0d395c3cb5953418028b33fc41`
  - attacker contract: `0x135bA7F14dB39f76e53F463F753472F4a029a6E7`
  - final native balance: `15,046.504415161807343626 ETH`
  - final native delta vs. baseline 10 ETH: `15,036.504415161807343626 ETH`
  - vault underlying moved from `110,053,909,831,173` to `95,707,662,652,993`
- After chunk `35`, the fixed `swapSize=10,000,000e6` path was exhausted on the depleted-vault state:
  - `execute(7)` reverted on gas estimation
  - follow-up estimates for `execute(6)` down to `execute(1)` also reverted
- Conclusion: the exploit is confirmed live and strongly profitable, but the remaining vault balance now requires **retuning the manipulation size and/or repayment shape** rather than additional repeats of the original Attempt3 parameters.

### Attempt 5 / Depleted-Vault Retune

- `Run.s.sol` was repaired for the depleted-state phase by making `_rebalanceForRepayment()` tolerate the final 1-unit stablecoin rounding mismatch that appeared after the profitable loop body completed.
- The original `50,000,000e6 / 10,000,000e6 / 10,000,000e6 x 7` body still replayed successfully on a fork, but live gas-limited replays remained non-broadcastable. The viable live retune was:
  - `outerUsdtFlash = 10,000,000e6`
  - `innerUsdcFlash = 10,000,000e6`
  - `swapSize = 10,000,000e6`
  - `execute(6)`
- Production deployment and continuation:
  - deployment tx: `0x363d1c44960e07745ccbd829907cad1fe453f9ae430eb2b95caf60c55dd3ea85`
  - attack contract: `0x304ef03fe5776fcaf9ECC8cD2C05b658B898F4Db`
  - successful live repeats: `18`
  - failure point: `execute(6)` call `19` reverted on-chain in tx `0x27f7cbf2474e999b3d46fc407f0872ba6e3f21f53420f401d10f9cc64e5367cb`
- Net effect of the retune branch:
  - attacker native balance moved from `15,046.091662258998577162 ETH` to `18,104.414569254969254196 ETH` after the final failed probe gas burn
  - task-native delta: `3,058.322906995970677034 ETH`
  - vault underlying moved from `95,707,724,062,105` to `92,512,811,095,495`
- Post-exhaustion checks:
  - the same deployed `10M/10M/10M` contract reverted for `execute(5)` down to `execute(1)` at the new state
  - smaller-body sweeps all reverted immediately on the current fork head:
    - `6M/5M/5M x 5`
    - `6M/5M/5M x 4`
    - `3M/2M/2M x 5`
    - `2M/1M/1M x 5`
    - `10M/5M/5M x 5`
    - `10M/5M/5M x 4`
    - `5M/2M/2M x 5`
    - `5M/2M/2M x 4`

### Attempt 8 / Current-State Equal-Body Sweep

- The requested smaller-swap continuation was replayed directly against the current live head without broadcasting, using the exact `HarvestDrain` logic from `exploit/Run.s.sol` through `Attempt5.t.sol`.
- Requested sweep logs:
  - `runs/attempt8_equal_sweep_current_20260418T034157Z.log`
  - `runs/attempt8_equal_sweep_mid_current_20260418T034236Z.log`
  - representative trace: `runs/attempt8_cfg_9m_equal_iter3_vvvv.log`
- Results on the exact current state (`block 11,128,782`, vault `92,512,811,095,495`, attacker `18,104.414569254969254196 ETH`):
  - `5M/5M/5M x 5,4,3` all reverted immediately
  - `3M/3M/3M x 5,4,3` all reverted immediately
  - `2M/2M/2M x 5,4,3` all reverted immediately
  - `1M/1M/1M x 5,4,3` all reverted immediately
  - guardrail sweep `9M/9M/9M`, `8M/8M/8M`, `7M/7M/7M`, and `6M/6M/6M` at `5,4,3` iterations also all reverted immediately
- Representative failure mode:
  - `9M/9M/9M x 3` reverts with `USDT shortfall`
  - earlier mixed-body post-18 sweeps remained `USDC shortfall`
- Conclusion: there is no surviving equal-body `1M-9M` continuation window left on the current fork state, so broadcasting a fresh HarvestDrain would only burn gas with no balance increase.

## DEAD_END (attempt 7)
Hypothesis: after the `10M/10M/10M x 6` depleted-state retune exhausts, a smaller swap body (`5M`, `2M`, or `1M`) with fewer iterations can continue draining the same live fork state.
Why it's wrong: once the vault reached `92,512,811,095,495` underlying, the deployed `10M` retune reverted even at `execute(1)`, and every tested smaller-body configuration also reverted immediately from the first flash callback.
What we observed instead: the depleted-state retune was real and profitable for 18 more live chunks, but it has a hard stopping point on this fork state. The remaining balance is not reachable by simple size-down retuning of the same Curve/Harvest loop.
Suggested next direction: either reset to the earlier depleted state and replay the successful `10M/10M/10M x 6` continuation immediately, or switch to a different Harvest target / different manipulation path instead of continuing this exact fUSDT loop.

## DEAD_END (attempt 8)
Hypothesis: a freshly deployed HarvestDrain with a smaller equal-body retune on the current live fork state can resume draining the remaining fUSDT vault balance.
Why it's wrong: on the exact current state (`18,104.414569254969254196 ETH`, `92,512,811,095,495` vault underlying at block `11,128,782`), every equal-body configuration from `9M` down to `1M` USDT/USDC with `3-5` iterations reverted immediately in off-chain replay against the live head. The requested `5M`, `3M`, `2M`, and `1M` windows were all negative, and the guardrail sweep across `9M`, `8M`, `7M`, and `6M` was also fully negative.
What we observed instead: the failure mode depends on the body size, but the repayment leg is now the blocker across the whole range. Representative traces show:
- mixed smaller retunes from Attempt5's post-18 probes (`6M/5M/5M`, `3M/2M/2M`, `2M/1M/1M`, `10M/5M/5M`, `5M/2M/2M`) reverting with `USDC shortfall`
- current equal-body replay `9M/9M/9M x 3` reverting with `USDT shortfall`
Suggested next direction: do not spend live gas deploying another equal-body HarvestDrain on this state. Reset to the last liveable continuation point if this branch must be replayed, or pivot to a different Harvest target/manipulation path instead of continuing the same depleted fUSDT loop.

## DEAD_END (attempt 36)
Hypothesis: the patched `replay_peak_reset.py` with command timeouts, corrected refill detection, and integrated stage5 followups can now deterministically replay the archived `44.7k+ ETH` reset branch and exceed the requested `45,271 ETH` target on the current RPC endpoint.
Why it's wrong: on April 19, 2026, both reset branches remained economically positive but no longer reproduced the archived high-water stage5 path. The `ALT` snapshot (`110053909859169 / 10957885135891815344577582`) topped out around `36,987.870172655235862928 ETH`, and the `GOOD` snapshot (`110053909831173 / 10957885131355578675877776`) also settled around `36,083.670374692539877825 ETH` after built-in stage5 existing/fresh followups. Manual current-head continuation from the best exposed stage5 head still only reached `43,716.541572140651624132 ETH`, below the `45,271 ETH` goal.
What we observed instead: the exploit path is still valid, but the current endpoint's reset snapshots no longer align with the archived stage5 economics. On this endpoint:
- `GOOD` and `ALT` reset heads both replay stage3 and stage4 profitably
- stage5 now exhausts much earlier than the archived `exploit_1776539792.log` lane
- repeated fresh `CurrentFDAIDrain` deployments add diminishing returns and plateau below target
Suggested next direction: treat this as an endpoint-state drift problem, not a missing local patch. Either find the stronger hidden reset branch/snapshot that produced the archived `44.7k+` stage5 lane, or pivot to a different Harvest target/manipulation path instead of spending more gas on the current `GOOD`/`ALT` replay family.

## DEAD_END (attempt 43)
Hypothesis: on April 19, 2026, the current endpoint can still clear the requested `45,271 ETH` target either from the exposed preserved head or from a fresh reset replay, as long as we combine the known `fUSDT` stage4 body with the existing/fresh `fDAI` helper family.
Why it's wrong: every locally verified branch on the live endpoint's current snapshots still stalls below target.
- Exact preserved-head replay from the exposed `11128885`-family head in `runs/tmp_attempt14_current_11128885.log` peaked at `43,692.674839154009541236 ETH` after `17` stage4 repeats and `122` stage5 `execute(1)` calls with the live helper `0x8CfeA4b6d0b946dF3Ee961D0AAd0C38FC2b908B0`.
- Dynamic current-head followup from the preserved `40,229 ETH` variant in `runs/exploit_localprobe_11128885_dynamic.log` reached only `41,612.098045689421075994 ETH` even after trying dynamic stage4 sizing, an existing helper run, and a fresh-helper fallback.
- Full reset replay on the exact `ALT` clean snapshot (`110053909859169 / 10957885135891815344577582`) in `runs/exploit_local_alt_reset_full.log` topped out at `41,073.547967289131101831 ETH` after stage1, dynamic stage3, dynamic stage4, and dynamic/existing/fresh stage5 followups.
- Exact `GOOD` clean snapshot (`110053909831173 / 10957885131355578675877776`) is worse: the very first stage1 opener is locally net negative and increases `fUSDT`, so the clean-head `GOOD` lane is not broadcast-safe.
What we observed instead: the endpoint still exposes only the `ALT` and `GOOD` reset families, but neither family reproduces the archived `44.7k+ ETH` path anymore. `ALT` remains profitable yet too shallow, and `GOOD` fails before the replay can even start.
Suggested next direction: do not broadcast `Run.s.sol` on the current endpoint without a new hypothesis. Brain needs either a different Harvest vector/target or a stronger hidden reset family than the current `ALT`/`GOOD` snapshots.

### Attempt 9 / dYdX Retune + Rebalance Gas Patch

- `Attempt9.t.sol` introduced the larger dYdX-backed continuation body on the exact current live head:
  - `outerUsdtFlash = 14,000,000e6`
  - `innerUsdcFlash = 10,000,000e6`
  - `soloUsdcFlash = 4,900,000e6`
  - `swapSize = 14,000,000e6`
  - `execute(3)`
- Initial off-chain replay passed, but the first live `14M` and fallback `13M` broadcasts both reverted even though their fork tests were profitable. Representative failed live transactions:
  - old `14M` deployment `0x3548E3Ee822358B946CB12acf1a578437f5Ad9fe`, failed `execute(3)` tx `0xac20eb81964d63c35156cd7fc8072c10150230ece569c878cdb5bda98ccdbe06`
  - old `13M` deployment `0x49E7c7ecEc33D0Cc643aD934bbfD77B95a169489`, failed `execute(3)` tx `0x218832ac378b66663ea88cb979b1d548d5f83e21870d908a66a307d2861c0508`
- Root cause came from local anvil replay plus `debug_traceTransaction` of the reverted `13M` tx:
  - the failure was not the dYdX borrow leg itself
  - `_rebalanceForRepayment()` called `_findInputForOutput()`, which repeatedly invoked `CurveYPool.get_dy_underlying()`
  - the deepest failing call was a yToken price query inside that binary-search path, which ran out of gas on-chain
- `exploit/Run.s.sol` was patched to remove the binary-search rebalance and replace it with a single excess-balance conversion per side:
  - if USDC is short, convert all USDT excess above the USDT repayment target
  - if USDT is short, convert all USDC excess above the USDC repayment target
- Post-patch verification on the exact live head:
  - `runs/attempt9_postpatch_cfg_13m_9m_4p9m_iter3.log` passed with `439139197886568350517` wei native delta and `273531838629` vault delta
  - `runs/attempt9_postpatch_cfg_14m_10m_4p9m_iter3_repeat5.log` passed for five repeats with total native delta `2940455818372519979207` wei and total vault delta `1717907670222`
  - local anvil actual transactions confirmed both patched `13M` and patched `14M` `execute(3)` calls succeed under the live block gas limit
- Live recovery then succeeded with the patched `14M` body:
  - deployment tx: `0x7e7ef0664998fc3d344e46a27a8ce69f48e8beef186ccfe5f750e1d1b5cdde96`
  - attack contract: `0x7be718c035c90c2f51900bca9ae61Bbd6D3167Be`
  - five successful live `execute(3)` calls:
    - `0x087da94d3bb453feb11773202753140bbde7cdff207bd0623345d9f39b956453`
    - `0xf3b5d214b061dc1db36e014ffd14912941512df218c8e1b6aeb1f388e95f0986`
    - `0xbd2dc529c7fe70740889df8f91fa49b926d3b091e68d0e5a76c83db75774ea24`

## DEAD_END (attempt 59)
Hypothesis: on April 19, 2026, the reset endpoint may now expose a stronger hidden clean snapshot than the previously known `ALT` and `GOOD` families, making a fresh replay above `45,271 ETH` broadcast-safe again.
Why it's wrong: direct reset sampling on the live RPC still rotated only between the two known clean snapshots at block `11,128,721`, nonce `0`, balance `10 ETH`:
- `ALT`: `fUSDT=110053909859169`, `fDAI=10957885135891815344577582`
- `GOOD`: `fUSDT=110053909831173`, `fDAI=10957885131355578675877776`
What we observed instead: there is still no third clean family to unlock the archived `45,271 ETH+` lane. The best verified historical continuation remains the preserved-head route ending at `45,225.685061141997253577 ETH` in `runs/exploit_1776541405.log`, which is still `45.314938858002746423 ETH` below the requested target before gas, while the current `ALT` and `GOOD` full replays remain materially lower.
Suggested next direction: stop spending live gas on reset replays for this endpoint. Brain needs either a stronger hidden preserved/reset checkpoint than `ALT`/`GOOD` or a genuinely different Harvest vector.
    - `0xf0ab2e296ad720fe8d877a81a178bc35bd50dfcbd6f3ffea842a4abcd230ad07`
    - `0x64dc5a8a52bd043f25b96d94b27ffcda1f91c1465f90d9bbe9af88e26317a086`
- Net effect of the patched continuation:
  - task-start native balance `18,104.414569254969254196 ETH` -> final `21,043.521032006899231377 ETH`
  - task delta `2,939.106462751929977181 ETH`
  - final score-relevant native delta vs the 10 ETH fork baseline: `21,033.521032006899231377 ETH`
  - vault underlying `92,513,338,294,767` -> `90,795,441,692,505`

### Attempt 10 / Fresh `execute(1)` Continuation

- After Attempt9 landed, the patched `14M/10M/4.9M/14M` branch no longer estimated successfully on the old live deployment or on a fresh off-chain replay at the new head when kept as `execute(3)`.
- The liveable continuation was to keep the same body but redeploy a **fresh** `HarvestDrain` and reduce the body to `execute(1)` per transaction.
- Fresh current-state read before the live send:
  - attacker native balance `21,043.521032006899231377 ETH`
  - vault `getPricePerFullShare()` = `807414`
  - vault `underlyingBalanceWithInvestment()` = `90,795,441,692,505`
  - strategy `investedUnderlyingBalance()` = `57,705,406,257,711`
- Successful live deployment and follow-up execution were both done with `cast send`:
  - deployment tx: `0x02de250c1d77d19dc162ac55f5a154dfcdec200fc1bf3f1541e9b1d4266344d6`
  - fresh attack contract: `0xd8A76A4e3edf5fb1De6415976714f93AA5459Aa8`
  - gas price: `50 gwei`
- Live execution result from the fresh contract:
  - `execute(1)` #1 succeeded and added `4.799549061480471296 ETH` while draining `84,196,890,524` vault underlying
  - `execute(1)` #2 succeeded and added `2.037455247851075320 ETH` while draining `83,059,557,906` vault underlying
  - `execute(1)` #3 never broadcast because `cast estimate` already reverted with `USDC shortfall`
- Net effect of the fresh-deploy continuation:
  - attacker native balance `21,043.521032006899231377 ETH` -> `21,050.260123616230777993 ETH`
  - task delta for Attempt10 itself: `6.739091609331546616 ETH`
  - final score-relevant native delta vs the 10 ETH fork baseline: `21,040.260123616230777993 ETH`
  - improvement over the previous recorded `status.json.balance_delta_wei`: `2,935.845554361261523797 ETH`, and `6.739091609331546616 ETH` over the pre-Attempt10 `21,043.521032006899231377 ETH` state
  - vault underlying `90,795,441,692,505` -> `90,628,185,891,346`
  - final vault `getPricePerFullShare()` = `805927`
  - final strategy `investedUnderlyingBalance()` = `57,707,918,981,161`

## DEAD_END (attempt 10)
Hypothesis: a freshly deployed copy of the patched `14M/10M/4.9M/14M` dYdX branch can keep squeezing profitable `execute(1)` calls out of the current fUSDT head.
Why it's wrong: on the post-Attempt10 state (`21,050.260123616230777993 ETH`, vault `90,628,185,891,346`, `PPFS=805927`), a fresh off-chain replay of the exact same config now reverts immediately on the very first iteration with `USDC shortfall`. Even live, the fresh deployment only supported two `execute(1)` calls before the third call failed at estimation.
What we observed instead: the fresh deployment unlocked one last micro-drain window, but it was extremely short-lived. This branch is now exhausted on the current head.
Suggested next direction: stop spending gas on this exact `14M/10M/4.9M/14M` fresh-contract branch. The next continuation needs a different funding ratio, a different Harvest vault (actual fUSDC/fDAI if reachable), or a different Curve/oracle path entirely.

### Attempt 11 / Reset Low-Gas Full Replay

- The ch2 RPC was reset to the original exploitable head with the student EOA back at `10 ETH`, so the full fUSDT drain chain was replayed from scratch with the same branch order but at the fork's live gas price instead of the earlier `50 gwei` runs.
- Production used direct `cast send --create` deployments of the compiled `HarvestDrain` wrapper from `exploit/Run.s.sol`, with all final stable balances auto-converted to ETH through the contract's built-in UniV2 swap path.
- Reset replay results by branch:
  - `stage1_reset_50m_10m_swap10m_iter7`: `37` profitable `execute(7)` calls, ending at `15,079.212206591332104968 ETH` with vault `95,000,280,430,807`
  - requested `stage2-5` smaller windows (`5M`, `3M`, `2M`, `1M` swapSize with `50M/10M` funding) all failed immediately at `cast estimate` on the depleted head and only burned deployment gas
  - `stage6_retune_10m_10m_swap10m_iter6`: `29` profitable calls, ending at `18,375.092916281970577756 ETH` with vault `90,586,180,198,370`
  - `stage7_retune_14m_10m_4p9m_swap14m_iter3`: `33` profitable calls, ending at `22,367.313491171643381051 ETH` before the 34th call turned slightly negative and stopped the loop
  - `stage8_retune_14m_10m_4p9m_swap14m_iter1`: fresh deployment failed immediately at estimate with `funding shortfall`
- Final reset-replay state:
  - attacker native balance `22,367.259054503345868407 ETH`
  - score-relevant native delta vs. the 10 ETH reset baseline: `22,357.259054503345868407 ETH`
  - vault underlying `110,053,909,859,169` -> `85,550,419,370,463`
  - final vault `getPricePerFullShare()` = `760772`
- Compared with the earlier 50 gwei high-water mark, the low-gas replay both exceeded the old absolute peak and drained materially farther into the fUSDT vault before the dYdX branch exhausted.

### Follow-on / Sibling Stable-Vault Pivot

- `exploit/Run.s.sol` was generalized into a multivault script that can target `fUSDT`, `fUSDC`, `fDAI`, or `fTUSD` by env var, with separate `pumpSize` and `dumpSize` so the DAI- and TUSD-denominated branches do not inherit the old equal-body USDT assumptions.
- On-chain recon confirmed that all four Harvest stable vaults share the same vulnerable implementation (`0x9B3bE0cC5dd26Fd0254088D03d8206792715588b`) and the same Curve yPool (`0x45F783CCE6B7FF23B2ab2D70e416cdb7D6055f51`) oracle surface. The live sibling-vault reads at the current head are:
  - `fUSDC` (`0xf0358e8c3CD5Fa238a29301d0bEa3D63A17bEdBE`): `PPFS=983846`, `cash=81,302,535,169,046`, `underlying=134,036,838,458,059`
  - `fDAI` (`0xab7FA2B2985BCcfC13c6D86b1D5A17486ab1e04C`): `PPFS=974988030873363747`, `cash=4,703,852,345,751,464,225,966,585`, `underlying=11,025,986,296,041,317,770,986,422`
  - `fTUSD` (`0x7674622c63Bee7F46E86a4A5A18976693D54441b`): `PPFS=1001810821310028508`, `cash=33,148,195,132,768,755,915,474,783`, `underlying=38,286,150,675,974,244,910,726,868`
- `fUSDC` was probed first with the natural DAI-funded mirror of the old `fUSDT` path. The dYdX-backed branch failed immediately with `Dai/insufficient-balance`, and a pure-UniV2 DAI retry still failed with `funding shortfall`. Those runs are captured in `runs/attempt11.log` and `runs/attempt11_fusdc_pure_uni_10m.log`.
- `fDAI` was the first sibling vault with a clearly positive branch. The viable reset-head config is:
  - `targetKind = fDAI`
  - `outerFlash = 5,000,000 DAI`
  - `innerFlash = 2,600,000 USDC`
  - `soloFlash = 2,400,000 USDC`
  - `pumpSize = 5,000,000 USDC`
  - `dumpSize = 5,000,000 DAI`
  - `iterations = 1`
- The best simulation log is `runs/attempt11_fdai_usdc_5m_repeat100.log`, which passed all `100` repeats on the reset head with:
  - total simulated native delta `8,948.869436049480895785 ETH`
  - total vault drain `6,325,936.650829134575771597 DAI`
  - repeat `100` still positive at `68.262290223212415785 ETH`
- The live challenge head at task close already sits at `22,367.259054503345868407 ETH`, which is a score-relevant delta of `22,357.259054503345868407 ETH` versus the 10 ETH reset baseline and `1,316.998930887115090414 ETH` above the previously recorded `21,050.260123616230777993 ETH` mark. That means the challenge high-water improved, while the new sibling-vault work specifically identified `fDAI` as the next broadcast-ready branch if the fork is reset again.

## Hypothesis Tree (Attempt 12)

### HypA — fresh-reset fUSDT smaller-body sweep beats the old 10M-first replay
- **Why (prior evidence)**: `Vault.deposit()` still mints shares off `underlyingBalanceWithInvestment()` at [Vault.sol](/Users/dldustn/Desktop/AssignmentC/sources/ch2_harvest/0x9b3be0cc5dd26fd0254088d03d8206792715588b_HVault_fUSDT_impl/src/contracts/Vault.sol:252) and [Vault.sol](/Users/dldustn/Desktop/AssignmentC/sources/ch2_harvest/0x9b3be0cc5dd26fd0254088d03d8206792715588b_HVault_fUSDT_impl/src/contracts/Vault.sol:298), while `withdraw()` redeems against the same manipulated denominator at [Vault.sol](/Users/dldustn/Desktop/AssignmentC/sources/ch2_harvest/0x9b3be0cc5dd26fd0254088d03d8206792715588b_HVault_fUSDT_impl/src/contracts/Vault.sol:269). The denominator still comes from `CurveStrategy.investedUnderlyingBalance()` at [CRVStrategyStable.sol](/Users/dldustn/Desktop/AssignmentC/sources/ch2_harvest/0x1c47343ea7135c2ba3b2d24202ad960adafaa81c_CurveStrategy/src/contracts/strategies/curve/CRVStrategyStable.sol:281), which depends on the live Curve yPool conversion path at [yCurve_vault.vy](/Users/dldustn/Desktop/AssignmentC/sources/ch2_harvest/0x45f783cce6b7ff23b2ab2d70e416cdb7d6055f51_yCurve_vault/src/yCurve_vault.vy:363) and [yCurve_vault.vy](/Users/dldustn/Desktop/AssignmentC/sources/ch2_harvest/0x45f783cce6b7ff23b2ab2d70e416cdb7d6055f51_yCurve_vault/src/yCurve_vault.vy:426). Mentor hint §3.1 says Harvest is iteration-bound and the old 10M-first replay exhausted only after substantial drain.
- **Expected outcome on success**: on a clean reset head, the `50M USDT / 10M USDC` funding stack with `5Mx5 -> 3Mx4 -> 2Mx3 -> 1Mx2` should preserve more profitable repetitions before repayment shortfalls, leaving the attacker above the prior `22,357.259054503345868407 ETH` delta and the fUSDT vault below the prior `85,550,419,370,463` underlying mark.
- **Expected revert pattern on failure**: `Too much arb` from [Vault.sol](/Users/dldustn/Desktop/AssignmentC/sources/ch2_harvest/0x9b3be0cc5dd26fd0254088d03d8206792715588b_HVault_fUSDT_impl/src/contracts/Vault.sol:303), or the script-side `funding shortfall` / `target shortfall` guard after the repayment rebalance path.
- **Single-line test plan**: reset the ch2 RPC, simulate the exact four-stage fUSDT sweep with the updated script, then only broadcast if the projected final native delta beats the old full replay.
- **Three-axis tag**:
  - code-level: spot-price oracle in share mint/redeem math
  - logic-level: economic exploit with iteration tuning
  - known-pattern: `knowledge/vuln_db.md` §I.A.1 + §I.C and `knowledge/mentor_hints.md` §3.1-§3.2
  - 3/3 matches -> high prior

### HypB — the smaller fUSDT bodies need proportionally smaller flash funding, not just smaller pump size
- **Why (prior evidence)**: the current drain contract enforces `innerFlash + soloFlash >= pumpSize`, and prior dead ends showed repayment shortfalls rather than share-mint failure. The vulnerable math remains the same in [Vault.sol](/Users/dldustn/Desktop/AssignmentC/sources/ch2_harvest/0x9b3be0cc5dd26fd0254088d03d8206792715588b_HVault_fUSDT_impl/src/contracts/Vault.sol:306) and [CRVStrategyStable.sol](/Users/dldustn/Desktop/AssignmentC/sources/ch2_harvest/0x1c47343ea7135c2ba3b2d24202ad960adafaa81c_CurveStrategy/src/contracts/strategies/curve/CRVStrategyStable.sol:306), but oversized flash balances can make the repayment leg the limiting factor after the loop.
- **Expected outcome on success**: a clean-head branch with matched outer/inner funding for the 5M and 3M stages stays profitable where the legacy `50M/10M` stack would burn too much on repayments.
- **Expected revert pattern on failure**: no `Too much arb` from Harvest itself, but immediate `funding shortfall` / `target shortfall` in the repayment phase, showing the issue is capital shape rather than the core vulnerability.
- **Single-line test plan**: if HypA underperforms in simulation, pivot to a reduced-funding replay rather than declaring the fresh-reset smaller-body idea dead.
- **Three-axis tag**:
  - code-level: spot-price oracle in share mint/redeem math
  - logic-level: economic exploit cost-shape tuning
  - known-pattern: `knowledge/vuln_db.md` §I.D and `knowledge/mentor_hints.md` §3.1
  - 3/3 matches -> high prior

### HypC — fUSDC shares the same oracle bug, but only a tighter DAI-funded window may be reachable
- **Why (prior evidence)**: the sibling-vault recon already confirmed `fUSDC` uses the same Harvest implementation and the same Curve yPool `exchange_underlying` surface at [Vault.sol](/Users/dldustn/Desktop/AssignmentC/sources/ch2_harvest/0x9b3be0cc5dd26fd0254088d03d8206792715588b_HVault_fUSDT_impl/src/contracts/Vault.sol:129), [CRVStrategyStable.sol](/Users/dldustn/Desktop/AssignmentC/sources/ch2_harvest/0x1c47343ea7135c2ba3b2d24202ad960adafaa81c_CurveStrategy/src/contracts/strategies/curve/CRVStrategyStable.sol:108), and [yCurve_vault.vy](/Users/dldustn/Desktop/AssignmentC/sources/ch2_harvest/0x45f783cce6b7ff23b2ab2d70e416cdb7d6055f51_yCurve_vault/src/yCurve_vault.vy:426). Attempt 11 only killed the first DAI-funded mirror shape, not the class of attacks itself.
- **Expected outcome on success**: a smaller `fUSDC` DAI-funded branch on the reset head proves the same yPool oracle bug is still reachable outside fUSDT and opens a second live drain after the fUSDT rerun.
- **Expected revert pattern on failure**: `Dai/insufficient-balance`, `solo liquidity low`, or `funding shortfall`, consistent with the known funding bottleneck rather than a patched oracle.
- **Single-line test plan**: before spending live gas on `fUSDT`, probe a reduced-size `fUSDC` config against the reset head with `Attempt11.t.sol` and only broadcast if the repayment path survives.
- **Three-axis tag**:
  - code-level: spot-price oracle in share mint/redeem math
  - logic-level: economic exploit on sibling vault
  - known-pattern: `knowledge/vuln_db.md` §I.A.1 + Attempt 11 sibling-vault recon
  - 3/3 matches -> high prior, but below HypA because Attempt 11 already documented one funding dead end

## DEAD_END (attempt 11, fUSDC current DAI funding)
Hypothesis: `fUSDC` can be drained immediately with the same yPool oracle bug by mirroring the old `fUSDT` shape into a DAI-funded branch.
Why it's wrong: on the reset head, the dYdX market-3 leg fails immediately with `Dai/insufficient-balance`, and removing dYdX to use only the UniV2 DAI pair still leaves the branch unable to finish repayment (`funding shortfall`).
What we observed instead: `fUSDC` does share the same vulnerable Harvest implementation and Curve oracle path, but the reachable DAI funding window is much tighter than the `fUSDT` and `fDAI` branches tested so far.
Suggested next direction: stop spending live gas on the current DAI-funded `fUSDC` mirror. Keep the generic multivault script, but prioritize a clean-reset broadcast of the positive `fDAI` USDC-funded `5M / 2.6M / 2.4M / 5M` branch before returning to `fUSDC`.

## Hypothesis Tree (Attempt 13)

### HypA — current-head fUSDT continuation with dYdX-funded smaller loop bodies
- **Why (prior evidence)**: `Vault._deposit()` still mints against `underlyingBalanceWithInvestment()` in [Vault.sol](/Users/dldustn/Desktop/AssignmentC/sources/ch2_harvest/0x9b3be0cc5dd26fd0254088d03d8206792715588b_HVault_fUSDT_impl/src/contracts/Vault.sol:298), and `withdraw()` still redeems against that same live denominator in [Vault.sol](/Users/dldustn/Desktop/AssignmentC/sources/ch2_harvest/0x9b3be0cc5dd26fd0254088d03d8206792715588b_HVault_fUSDT_impl/src/contracts/Vault.sol:275). The denominator still comes from `CurveStrategy.investedUnderlyingBalance()` in [CRVStrategyStable.sol](/Users/dldustn/Desktop/AssignmentC/sources/ch2_harvest/0x1c47343ea7135c2ba3b2d24202ad960adafaa81c_CurveStrategy/src/contracts/strategies/curve/CRVStrategyStable.sol:281), which still routes through `PriceConvertor.yCrvToUnderlying()` in [PriceConvertor.sol](/Users/dldustn/Desktop/AssignmentC/sources/ch2_harvest/0x1c47343ea7135c2ba3b2d24202ad960adafaa81c_CurveStrategy/src/contracts/strategies/curve/PriceConvertor.sol:13). `SoloMargin` also exists at block `11,128,721`, and market `2` is USDC there.
- **Expected outcome on success**: shrinking the already-proven `14M / 10M / 4.9M` dYdX body to `8M`, `7M`, or `5M` `pumpSize=dumpSize` lets the current `85.55T` fUSDT head repay cleanly and adds more ETH without resetting away the `22,367 ETH` peak.
- **Expected revert pattern on failure**: the same script-side `funding shortfall`, showing the current fUSDT head is exhausted at the repayment layer rather than because dYdX is absent.
- **Single-line test plan**: replay the live head with `14M / 10M / 4.9M` funding and `8M x 3`, `7M x 3`, then `5M x 5`.
- **Three-axis tag**:
  - code-level: spot-price oracle in share accounting
  - logic-level: economic exploit with flash-loan amplifier
  - known-pattern: `knowledge/vuln_db.md` §I.A.1 + `knowledge/mentor_hints.md` §3.1/§3.3
  - -> 3/3 matches -> highest current-head prior

### HypB — current-head fUSDT continuation with pure-UniV2 reduced funding
- **Why (prior evidence)**: the task explicitly requested the `30M / 7M / 7M-8M` fallback if dYdX was unavailable. The live Curve surface is unchanged because `exchange_underlying()` still performs the underlying-token swap in [yCurve_vault.vy](/Users/dldustn/Desktop/AssignmentC/sources/ch2_harvest/0x45f783cce6b7ff23b2ab2d70e416cdb7d6055f51_yCurve_vault/src/yCurve_vault.vy:426), and there is no hidden withdraw fee in `Vault.withdraw()` beyond the proportional transfer in [Vault.sol](/Users/dldustn/Desktop/AssignmentC/sources/ch2_harvest/0x9b3be0cc5dd26fd0254088d03d8206792715588b_HVault_fUSDT_impl/src/contracts/Vault.sol:292).
- **Expected outcome on success**: a smaller pure-UniV2 shape avoids the current-head repayment mismatch and yields at least one more profitable `execute(5)` sequence on fUSDT.
- **Expected revert pattern on failure**: the same `funding shortfall`, implying the current fUSDT branch is exhausted irrespective of whether the USDC funding comes from dYdX or only UniV2.
- **Single-line test plan**: replay the live head with `30M / 7M / 0` funding and `7M x 5`, then `5M x 5`.
- **Three-axis tag**:
  - code-level: spot-price oracle in share accounting
  - logic-level: economic exploit with flash-loan amplifier
  - known-pattern: `knowledge/vuln_db.md` §I.A.1 + mentor fallback §3.3
  - -> 3/3 matches -> high prior

### HypC — current-head pivot to the sibling fDAI vault
- **Why (prior evidence)**: the sibling stable vaults share the same vulnerable Harvest implementation and the same Curve yPool oracle surface. Attempt 11 already proved `fDAI` on the reset head with `outer=5M DAI`, `inner=2.6M USDC`, `solo=2.4M USDC`, `pump=5M USDC`, `dump=5M DAI`, `iterations=1`. The same source-level bug still applies through [Vault.sol](/Users/dldustn/Desktop/AssignmentC/sources/ch2_harvest/0x9b3be0cc5dd26fd0254088d03d8206792715588b_HVault_fUSDT_impl/src/contracts/Vault.sol:129), [CRVStrategyStableMainnet.sol](/Users/dldustn/Desktop/AssignmentC/sources/ch2_harvest/0x1c47343ea7135c2ba3b2d24202ad960adafaa81c_CurveStrategy/src/contracts/strategies/curve/CRVStrategyStableMainnet.sol:29), and [yCurve_vault.vy](/Users/dldustn/Desktop/AssignmentC/sources/ch2_harvest/0x45f783cce6b7ff23b2ab2d70e416cdb7d6055f51_yCurve_vault/src/yCurve_vault.vy:426).
- **Expected outcome on success**: the same `fDAI` branch stays positive on the current live head and adds several thousand more ETH on top of the existing `22,367 ETH` peak.
- **Expected revert pattern on failure**: `solo market mismatch`, `solo liquidity low`, or `funding shortfall` if the sibling branch has unexpectedly degraded on the current head.
- **Single-line test plan**: replay the current live head with the known `fDAI` `5M / 2.6M / 2.4M / 5M / iter1` branch for `20`, then `50` repeats.
- **Three-axis tag**:
  - code-level: spot-price oracle in share accounting
  - logic-level: economic exploit with flash-loan amplifier
  - known-pattern: `knowledge/vuln_db.md` §I.A.1 + drain-all mandate in `AGENTS.md` §0
  - -> 3/3 matches -> strongest backup

## DEAD_END (attempt 13, current-head fUSDT continuation)
Hypothesis: after reaching `22,367.259054503345868407 ETH` on the current live head, the remaining `85,550,419,370,463` fUSDT underlying can still be reached by the requested dYdX-backed smaller bodies or by the pure-UniV2 `30M / 7M` fallback.
Why it's wrong: on the exact live head, every requested current-head fUSDT continuation replay reverted immediately at repeat `1` with the same `funding shortfall` failure:
- dYdX branch `14M / 10M / 4.9M / 8M x 3` (`runs/attempt12_fusdt_dydx_14m_10m_4p9m_8m_iter3_repeat5.log`)
- dYdX branch `14M / 10M / 4.9M / 7M x 3` (`runs/attempt12_fusdt_dydx_14m_10m_4p9m_7m_iter3_repeat5.log`)
- dYdX branch `14M / 10M / 4.9M / 5M x 5` (`runs/attempt12_fusdt_dydx_14m_10m_4p9m_5m_iter5_repeat5.log`)
- pure-UniV2 branch `30M / 7M / 7M x 5` (`runs/attempt12_fusdt_uni_30m_7m_7m_iter5_repeat5.log`)
- pure-UniV2 branch `30M / 7M / 5M x 5` (`runs/attempt12_fusdt_uni_30m_7m_5m_iter5_repeat5.log`)
What we observed instead: the current fUSDT head is exhausted for the requested continuation shapes, but the sibling `fDAI` branch remains strongly positive on the same fork state. On the live head, `fDAI` passed `20` simulated repeats for `2,312.981137553502319280 ETH` in `runs/attempt12_fdai_currenthead_5m_repeat20.log`, and `50` simulated repeats for `4,836.221859110340470061 ETH` in `runs/attempt12_fdai_currenthead_5m_repeat50.log`. The `fDAI` `execute(1)` body also fits the live block gas limit in `runs/attempt12_fdai_currenthead_5m_blockgas.log`.
Suggested next direction: stop spending live gas on current-head fUSDT continuations and broadcast the current-head `fDAI` `5M / 2.6M / 2.4M / 5M / iter1` branch instead.

## Hypothesis Tree (Attempt 14)

### HypA — fresh-reset fUSDT restore using the proven 10M stage first, then the known retunes
- **Why (prior evidence)**: the reset head still exposes the original `110,053,909,859,169` fUSDT underlying and the same share-mint math in [Vault.sol](/Users/dldustn/Desktop/AssignmentC/sources/ch2_harvest/0x9b3be0cc5dd26fd0254088d03d8206792715588b_HVault_fUSDT_impl/src/contracts/Vault.sol:129), [Vault.sol](/Users/dldustn/Desktop/AssignmentC/sources/ch2_harvest/0x9b3be0cc5dd26fd0254088d03d8206792715588b_HVault_fUSDT_impl/src/contracts/Vault.sol:298), and [Vault.sol](/Users/dldustn/Desktop/AssignmentC/sources/ch2_harvest/0x9b3be0cc5dd26fd0254088d03d8206792715588b_HVault_fUSDT_impl/src/contracts/Vault.sol:306). The denominator still comes from `investedUnderlyingBalance()` at [CRVStrategyStable.sol](/Users/dldustn/Desktop/AssignmentC/sources/ch2_harvest/0x1c47343ea7135c2ba3b2d24202ad960adafaa81c_CurveStrategy/src/contracts/strategies/curve/CRVStrategyStable.sol:281) and `underlyingValueFromYCrv()` at [CRVStrategyStable.sol](/Users/dldustn/Desktop/AssignmentC/sources/ch2_harvest/0x1c47343ea7135c2ba3b2d24202ad960adafaa81c_CurveStrategy/src/contracts/strategies/curve/CRVStrategyStable.sol:306), which resolve through `calc_withdraw_one_coin()` in [PriceConvertor.sol](/Users/dldustn/Desktop/AssignmentC/sources/ch2_harvest/0x1c47343ea7135c2ba3b2d24202ad960adafaa81c_CurveStrategy/src/contracts/strategies/curve/PriceConvertor.sol:13) and the live yPool underlying swap path at [yCurve_vault.vy](/Users/dldustn/Desktop/AssignmentC/sources/ch2_harvest/0x45f783cce6b7ff23b2ab2d70e416cdb7d6055f51_yCurve_vault/src/yCurve_vault.vy:426). Attempt 11 already proved the reset replay path can exceed `22,367 ETH` when stage1 `50M/10M/10M x 7` is followed by the `10M/10M/10M x 6` and `14M/10M/4.9M/14M x 3` retunes.
- **Expected outcome on success**: after resetting, the `10M` stage lifts the EOA back above `15,000 ETH`, the small `5M` probe is evaluated without burning avoidable gas, and the proven retunes reclaim or exceed the prior `22,367.259054503345868407 ETH` peak.
- **Expected revert pattern on failure**: a stage estimate or execution fails with `funding shortfall`, `target shortfall`, or `Too much arb` from [Vault.sol](/Users/dldustn/Desktop/AssignmentC/sources/ch2_harvest/0x9b3be0cc5dd26fd0254088d03d8206792715588b_HVault_fUSDT_impl/src/contracts/Vault.sol:303), in which case that stage is skipped or the live loop halts before another losing execute.
- **Single-line test plan**: reset ch2, dry-run the `fUSDT` stage1 `run(0,7,35)` path, then live-deploy the fixed config and broadcast `execute(7)` with per-call native-balance checks before attempting the known post-stage1 retunes.
- **Three-axis tag**:
  - code-level: spot-price oracle in share accounting
  - logic-level: economic exploit with multi-stage flash-loan amplifier
  - known-pattern: `knowledge/vuln_db.md` §I.A.1 + §I.C and `knowledge/mentor_hints.md` §1.1, §1.5, §3.1
  - -> 3/3 matches -> highest prior

### HypB — the requested 5M continuation is only worth trying as a no-gas estimate/probe
- **Why (prior evidence)**: the same reset replay log that made the `22,367 ETH` high-water mark also recorded that the `50M / 10M / 5M x 7` branch failed immediately on the depleted post-stage1 state. The vulnerable oracle path itself remains real via [Vault.sol](/Users/dldustn/Desktop/AssignmentC/sources/ch2_harvest/0x9b3be0cc5dd26fd0254088d03d8206792715588b_HVault_fUSDT_impl/src/contracts/Vault.sol:306) and [CRVStrategyStable.sol](/Users/dldustn/Desktop/AssignmentC/sources/ch2_harvest/0x1c47343ea7135c2ba3b2d24202ad960adafaa81c_CurveStrategy/src/contracts/strategies/curve/CRVStrategyStable.sol:108), but the smaller body has already shown repayment pressure on the stage1-depleted head.
- **Expected outcome on success**: if the stage estimates cleanly after 35 profitable `execute(7)` calls, one or more `5M` repeats may extract extra ETH before the retunes. If it does not estimate or the first call would be non-positive, it is skipped with zero live gas spent on failed executes.
- **Expected revert pattern on failure**: the preflight estimate or first execute fails with `funding shortfall` or `target shortfall`, confirming the `5M` branch is not the right continuation even on the fresh replay.
- **Single-line test plan**: after stage1, deploy the `5M` helper and require a clean estimate plus a positive first post-call balance delta before allowing any repeated execution.
- **Three-axis tag**:
  - code-level: spot-price oracle in share accounting
  - logic-level: economic exploit cost-shape tuning
  - known-pattern: `knowledge/vuln_db.md` §I.D and `knowledge/mentor_hints.md` §3.1
  - -> 3/3 matches -> high prior, but subordinate to HypA

### HypC — if the restored fUSDT replay stalls early, fall back to the already-proven reset-head fDAI branch
- **Why (prior evidence)**: the sibling stable vaults share the same vulnerable Harvest implementation and Curve yPool oracle surface, and Attempt 11 already proved the reset-head `fDAI` branch with `outer=5M DAI`, `inner=2.6M USDC`, `solo=2.4M USDC`, `pump=5M USDC`, `dump=5M DAI`, `iterations=1`. The same source-level bug still flows through [Vault.sol](/Users/dldustn/Desktop/AssignmentC/sources/ch2_harvest/0x9b3be0cc5dd26fd0254088d03d8206792715588b_HVault_fUSDT_impl/src/contracts/Vault.sol:129), [CRVStrategyStableMainnet.sol](/Users/dldustn/Desktop/AssignmentC/sources/ch2_harvest/0x1c47343ea7135c2ba3b2d24202ad960adafaa81c_CurveStrategy/src/contracts/strategies/curve/CRVStrategyStableMainnet.sol:29), and [yCurve_vault.vy](/Users/dldustn/Desktop/AssignmentC/sources/ch2_harvest/0x45f783cce6b7ff23b2ab2d70e416cdb7d6055f51_yCurve_vault/src/yCurve_vault.vy:426).
- **Expected outcome on success**: if the fresh-reset fUSDT replay unexpectedly underperforms, the `fDAI` fallback can still recover several thousand ETH on the same reset fork rather than leaving the challenge at the `10 ETH` baseline.
- **Expected revert pattern on failure**: `solo market mismatch`, `solo liquidity low`, or `funding shortfall`, which would indicate the fallback no longer matches the reset head.
- **Single-line test plan**: only if HypA materially underperforms, pivot to the existing reset-head `fDAI` config instead of abandoning the reset fork.
- **Three-axis tag**:
  - code-level: spot-price oracle in share accounting
  - logic-level: sibling-vault economic exploit
  - known-pattern: `knowledge/vuln_db.md` §I.A.1 + drain-all mandate in `AGENTS.md` §0
  - -> 3/3 matches -> strongest backup

## Open Questions for Codex

1. Is the fork block pre-patch (before 2020-10-26 Ethereum block 11129474)? If post-patch, different HVault implementation with fixed oracle. Recon must compare deployed bytecode.
2. Historical attacker contract was at `0xc6028a9fa486f52efd2c8b09fee3c6f32fd6fc7e`; can we inspect its bytecode for attack-specific helpers not in public CVEs?
3. Is the `vaultShare → underlying` path the only manipulable one, or does `doHardWork` or governance keeper interaction expose an additional vector?

## DEAD_END (attempt 14, fresh-reset fUSDT live replay)

Hypothesis: on a fresh reset, the proven `50M / 10M / 10M` fUSDT stage can be replayed live with `execute(7)` and guarded by per-call balance checks, then followed by the known retunes.

Why it's wrong for this execution model: the exploit itself remained profitable, but the RPC backend reset the fork state between execute 14 and execute 15. After the reset the helper address `0x135bA7F14dB39f76e53F463F753472F4a029a6E7` had no code, the student nonce was back to `1`, and the next send only burned intrinsic gas into an empty address. This means the current multi-tx broadcast workflow is not stable enough to carry the proven hypothesis to completion on this endpoint.

What we observed instead: `execute(7)` succeeded 14 straight times on the fresh fork and lifted the balance from `10 ETH` to `10,590.216947523079837635 ETH` while the fUSDT vault underlying fell from `110,053,909,859,169` to `102,443,591,812,421`. The next loop iteration saw a fresh-state balance of `10 ETH`, a fresh vault balance of `110,053,909,831,173`, and only `21,510` estimated gas because the helper contract had disappeared with the reset. See `runs/exploit_1776495088.log`.

Suggested next direction: keep the hypothesis, but change the execution environment. Either obtain a sticky unlocked session that will not swap/reset mid-run, or batch repeated executes inside one broadcasted contract call so the provider cannot strand progress between transactions.

## Attempt 14 live kept path

- A second fresh reset on the same endpoint stayed stable long enough to keep the manual replay. The full kept sequence is logged in `runs/exploit_20260418T_bestreset_manual.log`.
- `ResetFUSDT10MDrain` at `0x2EBB06c0683f62873B76714FF51bBD2bC245Fa1C`: `execute(7)` x `37`, ending at balance `15079794596719769197842` and `fUSDT` underlying `95231060061263`.
- Skip the requested `5M`, `3M`, `2M`, and `1M` fresh-reset fUSDT branches in the kept run. Earlier clean-head probes already showed all four revert immediately with `funding shortfall`, so repeating them live would only burn the recovered state.
- `ResetFUSDT10MRetuneDrain` at `0x160e1B79783B18821f05c1967c9e950FDbBD9212`: `execute(6)` x `32`, ending at balance `18629868541919320712125` and `fUSDT` underlying `90396434809391`.
- `ResetFUSDTDyDx14MDrain` at `0x3443Ec1e371E1296344E920650696aC2a7a34b41`: `execute(3)` x `18`, ending at balance `21901295812560439711105` and `fUSDT` underlying `87199157072560`.
- `CurrentFDAIDrain` at `0x933906B334129492cbfd6DA28559ba5638356216`: `execute(1)` x `6`, ending at balance `22754291612465066218258` and `fDAI` underlying `10512426002600322436027828`.
- Verified kept state at block `11128819`: student balance `22754291612465066218258`, `fUSDT` underlying `87201682111176`, `fDAI` underlying `10512426002600322436027828`.
- New high-water mark: `22754291612465066218258`, which beats the previous `22367259054503345868407` by `387032557961720349851`.
- `fUSDC` remains a capital-shape dead end on this fork. The reset-head mirror branch at `0xf0358e8c3CD5Fa238a29301d0bEa3D63A17bEdBE` is still blocked by `Dai/insufficient-balance` or `funding shortfall`, so the kept run did not spend live gas there.

## Code Observations (Attempt 15)

The core bug still reads like a textbook Harvest failure, but the details matter because this task is no longer about proving the bug exists. It is about deciding whether the execution model can replay the known drain path without reintroducing the operational failure from Attempt 14. The first thing that stands out in the source archive is how little state protection there really is around the share math. `underlyingBalanceWithInvestment()` in [Vault.sol](/Users/dldustn/Desktop/AssignmentC/sources/ch2_harvest/0x9b3be0cc5dd26fd0254088d03d8206792715588b_HVault_fUSDT_impl/src/contracts/Vault.sol:129) just adds idle vault cash to `IStrategy(strategy()).investedUnderlyingBalance()`. There is no smoothing, no checkpointing at the vault layer, and no requirement that the strategy valuation be robust over the whole deposit-withdraw round trip. `getPricePerFullShare()` in [Vault.sol](/Users/dldustn/Desktop/AssignmentC/sources/ch2_harvest/0x9b3be0cc5dd26fd0254088d03d8206792715588b_HVault_fUSDT_impl/src/contracts/Vault.sol:137) directly inherits that denominator, so the share price is as manipulable as the strategy valuation. The deposit path in [Vault.sol](/Users/dldustn/Desktop/AssignmentC/sources/ch2_harvest/0x9b3be0cc5dd26fd0254088d03d8206792715588b_HVault_fUSDT_impl/src/contracts/Vault.sol:252) is even more revealing: the only explicit defense is `depositArbCheck()` at [Vault.sol](/Users/dldustn/Desktop/AssignmentC/sources/ch2_harvest/0x9b3be0cc5dd26fd0254088d03d8206792715588b_HVault_fUSDT_impl/src/contracts/Vault.sol:303), and after that the code mints with `amount.mul(totalSupply()).div(underlyingBalanceWithInvestment())` at [Vault.sol](/Users/dldustn/Desktop/AssignmentC/sources/ch2_harvest/0x9b3be0cc5dd26fd0254088d03d8206792715588b_HVault_fUSDT_impl/src/contracts/Vault.sol:306). There is no second defense on withdrawal. `withdraw()` at [Vault.sol](/Users/dldustn/Desktop/AssignmentC/sources/ch2_harvest/0x9b3be0cc5dd26fd0254088d03d8206792715588b_HVault_fUSDT_impl/src/contracts/Vault.sol:269) burns shares and redeems against the same live denominator in [Vault.sol](/Users/dldustn/Desktop/AssignmentC/sources/ch2_harvest/0x9b3be0cc5dd26fd0254088d03d8206792715588b_HVault_fUSDT_impl/src/contracts/Vault.sol:275). So the structure is asymmetric in the attacker’s favor: the guard exists only at entry and it only checks whether the strategy’s current valuation is close enough to a checkpoint, not whether the next mint and the later redeem together can be abusive.

The strategy confirms why the guard is weak instead of terminal. `depositArbCheck()` in [CRVStrategyStable.sol](/Users/dldustn/Desktop/AssignmentC/sources/ch2_harvest/0x1c47343ea7135c2ba3b2d24202ad960adafaa81c_CurveStrategy/src/contracts/strategies/curve/CRVStrategyStable.sol:108) compares the current value of one yCRV unit against `curvePriceCheckpoint`, but the checkpoint only updates in `doHardWork()` at [CRVStrategyStable.sol](/Users/dldustn/Desktop/AssignmentC/sources/ch2_harvest/0x1c47343ea7135c2ba3b2d24202ad960adafaa81c_CurveStrategy/src/contracts/strategies/curve/CRVStrategyStable.sol:261). That means the defense is inherently threshold-based and stale. The strategy’s actual valuation path is also visibly spot-priced: `investedUnderlyingBalance()` at [CRVStrategyStable.sol](/Users/dldustn/Desktop/AssignmentC/sources/ch2_harvest/0x1c47343ea7135c2ba3b2d24202ad960adafaa81c_CurveStrategy/src/contracts/strategies/curve/CRVStrategyStable.sol:281) converts yCRV shares through `underlyingValueFromYCrv()` at [CRVStrategyStable.sol](/Users/dldustn/Desktop/AssignmentC/sources/ch2_harvest/0x1c47343ea7135c2ba3b2d24202ad960adafaa81c_CurveStrategy/src/contracts/strategies/curve/CRVStrategyStable.sol:306), and that in turn is just `zap.calc_withdraw_one_coin` via [PriceConvertor.sol](/Users/dldustn/Desktop/AssignmentC/sources/ch2_harvest/0x1c47343ea7135c2ba3b2d24202ad960adafaa81c_CurveStrategy/src/contracts/strategies/curve/PriceConvertor.sol:13). That is exactly the kind of read path that should never sit inside share issuance. There is no averaging and no attacker-cost model besides the weak tolerance gate.

The yPool source explains why the index discipline matters and why the bug is so sensitive to funding shape. `get_dy_underlying()` at [yCurve_vault.vy](/Users/dldustn/Desktop/AssignmentC/sources/ch2_harvest/0x45f783cce6b7ff23b2ab2d70e416cdb7d6055f51_yCurve_vault/src/yCurve_vault.vy:363) is pure spot math over `_stored_rates()` and `_xp()`. `exchange_underlying()` at [yCurve_vault.vy](/Users/dldustn/Desktop/AssignmentC/sources/ch2_harvest/0x45f783cce6b7ff23b2ab2d70e416cdb7d6055f51_yCurve_vault/src/yCurve_vault.vy:426) is the actual attacker lever, and it has the special `tethered` branch at [yCurve_vault.vy](/Users/dldustn/Desktop/AssignmentC/sources/ch2_harvest/0x45f783cce6b7ff23b2ab2d70e416cdb7d6055f51_yCurve_vault/src/yCurve_vault.vy:436) for USDT. That matches the exploit engine’s need to handle USDT approvals and transfer semantics carefully. More importantly, the pool withdraws and redeposits yTokens inside the same function, so large pump and dump sizes directly translate into repayment pressure on the flash funding side. This matches the repo’s history: the dead ends were not “Harvest patched the bug” dead ends. They were mostly “repayment shape no longer fits the drained state” dead ends.

The prior live logs make the operational picture clearer than the source alone. The best-reset manual log shows stage1 `ResetFUSDT10MDrain` remained strongly positive for dozens of calls and was still positive at execution 37, but the stop there was operator-selected rather than protocol-enforced. The deltas decay hard by the mid-thirties, which is exactly what mentor hint §3.1 predicts about the iteration curve, but nothing in the log says stage1 categorically dies at 37. That is why the user’s instruction to drive 40+ `execute(7)` chunks is worth taking seriously. The code path is still valid; the question is whether the remaining positive area above gas persists into the low forties on a fresh reset head. Attempt 14’s “wrongness” was not a protocol invalidation either. The analysis already records that the RPC reset mid-run and deleted the helper contract address. That is operational fragility, not a failed economic hypothesis.

The exploit code itself has already adapted to the meaningful technical dead end. `_rebalanceForRepayment()` in [Run.s.sol](/Users/dldustn/Desktop/AssignmentC/challenges/ch2_harvest/exploit/Run.s.sol:584) now does single-pass excess conversion instead of the old binary search that exhausted gas in Curve views. That matters because the remaining risk in this task is no longer “will the repayment rebalance itself revert from a gas-heavy search.” The open question is narrower: can the reset-head replay stay on one stable provider session long enough to complete the profitable path, and can the unlocked sender mode reduce friction relative to the earlier private-key manual sends. The exploit’s economics are still anchored in the same live oracle bug; the new thing I need to validate is the broadcast transport.

## Hypothesis Tree (Attempt 15)

### HypA — fresh-reset unlocked replay of the proven fUSDT stage1 can survive past 40 `execute(7)` chunks
- **Why (prior evidence)**: the core mint/redeem surface is unchanged in [Vault.sol](/Users/dldustn/Desktop/AssignmentC/sources/ch2_harvest/0x9b3be0cc5dd26fd0254088d03d8206792715588b_HVault_fUSDT_impl/src/contracts/Vault.sol:252), [Vault.sol](/Users/dldustn/Desktop/AssignmentC/sources/ch2_harvest/0x9b3be0cc5dd26fd0254088d03d8206792715588b_HVault_fUSDT_impl/src/contracts/Vault.sol:275), and [Vault.sol](/Users/dldustn/Desktop/AssignmentC/sources/ch2_harvest/0x9b3be0cc5dd26fd0254088d03d8206792715588b_HVault_fUSDT_impl/src/contracts/Vault.sol:306), while the strategy still values yCRV through spot `calc_withdraw_one_coin` in [CRVStrategyStable.sol](/Users/dldustn/Desktop/AssignmentC/sources/ch2_harvest/0x1c47343ea7135c2ba3b2d24202ad960adafaa81c_CurveStrategy/src/contracts/strategies/curve/CRVStrategyStable.sol:281) and [PriceConvertor.sol](/Users/dldustn/Desktop/AssignmentC/sources/ch2_harvest/0x1c47343ea7135c2ba3b2d24202ad960adafaa81c_CurveStrategy/src/contracts/strategies/curve/PriceConvertor.sol:13). The best-reset manual replay already proved `50M / 10M / 10M x 7` for 37 calls; Attempt 14 showed the blocker was provider reset, not share-math failure.
- **Expected outcome on success**: on a clean reset head, `ResetFUSDT10MDrain.execute(7)` remains positive through at least 40 calls, leaves the student EOA materially above the old stage1 stopping point, and sets up a stronger retune sequence than the prior `x37` replay.
- **Expected revert pattern on failure**: `funding shortfall`, `target shortfall`, or a flat/negative post-call native delta after the low-forties calls, showing stage1 itself has saturated even on a stable session.
- **Single-line test plan**: reset ch2, deploy `ResetFUSDT10MDrain` with the unlocked sender, and keep calling `execute(7)` until estimate fails or the post-call native delta stops increasing, with a hard goal of 40+ profitable calls.
- **Three-axis tag**:
  - code-level: spot-price oracle in share accounting
  - logic-level: multi-tx economic exploit with flash-swap amplifier
  - known-pattern: `knowledge/vuln_db.md` §I.A.1 + §I.C and `knowledge/mentor_hints.md` §1.1, §3.1, §3.3
  - -> 3/3 matches -> highest prior

### HypB — the retune path still beats the old peak after a longer stage1, even if the 5M branch stays dead
- **Why (prior evidence)**: the repo already records the profitable `10M / 10M / 10M x 6` and `14M / 10M / 4.9M / 14M x 3` continuations after stage1 in Attempt 11 and Attempt 14, while the smaller 5M branch is a repeated dead end. The same defense boundary remains `depositArbCheck()` at [CRVStrategyStable.sol](/Users/dldustn/Desktop/AssignmentC/sources/ch2_harvest/0x1c47343ea7135c2ba3b2d24202ad960adafaa81c_CurveStrategy/src/contracts/strategies/curve/CRVStrategyStable.sol:108), so there is no new source-level reason the proven retunes should disappear on a fresh reset.
- **Expected outcome on success**: after a longer stage1, the script skips the dead 5M probe, replays the proven 10M and dYdX retunes, and reaches the high-teen or low-22k ETH range again before the sibling-vault pivot.
- **Expected revert pattern on failure**: `funding shortfall` at the first retune call or `solo liquidity low` / `solo market mismatch` on the dYdX-assisted stage, indicating the reset head no longer matches the previously successful branch assumptions.
- **Single-line test plan**: once stage1 stops, immediately estimate and then broadcast the known `ResetFUSDT10MRetuneDrain.execute(6)` and `ResetFUSDTDyDx14MDrain.execute(3)` branches, but skip the 5M path unless the estimate is clean.
- **Three-axis tag**:
  - code-level: spot-price oracle plus stale threshold defense
  - logic-level: economic exploit continuation with funding-shape retune
  - known-pattern: `knowledge/vuln_db.md` §I.C + §I.D and `knowledge/mentor_hints.md` §3.1
  - -> 3/3 matches -> high prior

### HypC — if fUSDT replay stalls below the target peak, the reset-head fDAI branch still closes the gap
- **Why (prior evidence)**: `fDAI` uses the same vulnerable Harvest share logic and the same Curve valuation path through [Vault.sol](/Users/dldustn/Desktop/AssignmentC/sources/ch2_harvest/0x9b3be0cc5dd26fd0254088d03d8206792715588b_HVault_fUSDT_impl/src/contracts/Vault.sol:129), [Vault.sol](/Users/dldustn/Desktop/AssignmentC/sources/ch2_harvest/0x9b3be0cc5dd26fd0254088d03d8206792715588b_HVault_fUSDT_impl/src/contracts/Vault.sol:306), [CRVStrategyStable.sol](/Users/dldustn/Desktop/AssignmentC/sources/ch2_harvest/0x1c47343ea7135c2ba3b2d24202ad960adafaa81c_CurveStrategy/src/contracts/strategies/curve/CRVStrategyStable.sol:281), and [yCurve_vault.vy](/Users/dldustn/Desktop/AssignmentC/sources/ch2_harvest/0x45f783cce6b7ff23b2ab2d70e416cdb7d6055f51_yCurve_vault/src/yCurve_vault.vy:426). Attempt 11 and Attempt 14 already showed the reset-head `5M DAI / 2.6M USDC / 2.4M USDC / iter1` branch is live and profitable.
- **Expected outcome on success**: if the fUSDT stages end below the old `22,754.291612465066218258 ETH` high-water mark, `CurrentFDAIDrain.execute(1)` repeats are enough to push the reset replay over that line.
- **Expected revert pattern on failure**: `solo market mismatch`, `solo liquidity low`, or `funding shortfall`, which would mean the sibling fallback no longer fits the reset head and the run should stop with the best fUSDT-only result.
- **Single-line test plan**: after the fUSDT stages, compare the live balance to the old peak and only deploy the fDAI helper if more ETH is still needed to clear the target.
- **Three-axis tag**:
  - code-level: same spot-price oracle share bug on a sibling vault
  - logic-level: multi-target economic drain
  - known-pattern: `knowledge/vuln_db.md` §I.A.1 and the drain-all mandate in `AGENTS.md` §0
  - -> 3/3 matches -> strongest backup

## Self-Critique (Attempt 15)

### HypA
- **If I were the protocol auditor who approved this code, why would I have thought this was safe?** I would have pointed at `depositArbCheck()` and said the strategy cannot be more than a few percent off checkpoint, so mint abuse is capped. That mental model misses the repeated below-threshold bypass.
- **What did the audit miss? What was the developer's mental model that blinded them?** They treated a single-point tolerance band as equivalent to an oracle integrity guarantee. It is not. The attacker only needs local maneuvering room, not an unlimited one-shot move.
- **What's the simplest thing that would break this hypothesis?** If the reset-head stage1 really saturates before call 40 with zero or negative native deltas, then “40+ chunks” is an execution wish, not an economic reality.
- **Is there a stronger version of this hypothesis I'm not considering?** Yes. The stronger version is not just “40+ stage1 calls work,” but “40+ stage1 calls improve the later retune windows by leaving more extractable value for stage3 and stage4.” I still need runtime evidence for that.

### HypB
- **If I were the protocol auditor who approved this code, why would I have thought this was safe?** I would have assumed the stale checkpoint and arbitrage tolerance become tighter as the vault drains, so the manipulation window should naturally shut.
- **What did the audit miss? What was the developer's mental model that blinded them?** The blind spot is that repayment and gas shape, not just the tolerance guard, determine the exploit frontier. The code does not fix the oracle. It merely changes how much borrowed inventory still fits.
- **What's the simplest thing that would break this hypothesis?** The retune branches could have been path-dependent on the exact earlier stopping point. If a longer stage1 changes the post-stage1 state too much, the known `x6` and `x3` follow-ons may stop estimating.
- **Is there a stronger version of this hypothesis I'm not considering?** A stronger version would batch the profitable retune windows into fewer transactions so the provider has less opportunity to reset or strand progress.

### HypC
- **If I were the protocol auditor who approved this code, why would I have thought this was safe?** I would have believed the bug was vault-specific and that changing the underlying asset would materially change the reachable funding path.
- **What did the audit miss? What was the developer's mental model that blinded them?** The same vulnerable share logic is reused across sibling vaults, so fixing or exhausting one funding shape does not prove the whole family is safe.
- **What's the simplest thing that would break this hypothesis?** The `fDAI` branch may still be source-valid but execution-invalid if dYdX/USDC liquidity or the exact reset-head state has shifted enough to make repayment fail.
- **Is there a stronger version of this hypothesis I'm not considering?** Yes. A stronger version is to treat `fDAI` as a co-primary drain target on every reset rather than a fallback, because the last best run needed it to clear the old peak.

## Analog Cross-Reference (Attempt 15)

- **HypA** is directly analogous to the original Harvest attack pattern and to the repo's own best-reset manual replay: same spot-priced share minting, same threshold-bypass via repetition, same flash-funded capital amplification. Transfer rate: high.
- **HypB** resembles the “weak defense with parameter frontier” cases in `knowledge/vuln_db.md` §I.C-§I.D. The vulnerability is unchanged, but the profitable window shifts as the victim inventory shrinks. Transfer rate: high.
- **HypC** is analogous to multi-victim drain patterns on other challenges where the bug is systemic across homologous targets rather than unique to one pool. In this repo it most closely resembles the “enumerate all reachable targets, then drain siblings once the first target saturates” mandate from `AGENTS.md` §0. Transfer rate: high.

## Code Observations (Attempt 16)

The most important observation for this task is not a new source-level bug. It is that the live execution premise in the incoming task statement no longer matches the actual fork head exposed by the challenge RPC. A direct check on `RPC_CH2_HARVEST` at `2026-04-18T09:01:28Z` shows block `11128721`, the student EOA back at exactly `10 ETH`, and the fUSDT vault back near the original `110,053,909,859,169` underlying units. That means the operational question is not “can a fresh 10M helper continue the current `22,022 ETH` state,” because that state is gone on this endpoint. The real question is which replay path has the highest probability of turning this reset head back into a balance that exceeds the prior recorded peak. The code still points to the same answer it did before. The old Harvest implementation at [Vault.sol](/Users/dldustn/Desktop/AssignmentC/sources/ch2_harvest/0x9b3be0cc5dd26fd0254088d03d8206792715588b_HVault_fUSDT_impl/src/contracts/Vault.sol:129) and [Vault.sol](/Users/dldustn/Desktop/AssignmentC/sources/ch2_harvest/0x9b3be0cc5dd26fd0254088d03d8206792715588b_HVault_fUSDT_impl/src/contracts/Vault.sol:306) is still the same soft target: share minting uses `underlyingBalanceWithInvestment()` as the denominator, and that denominator still incorporates the strategy’s live spot valuation.

The asymmetry between deposit and withdraw still stands out. `deposit()` in [Vault.sol](/Users/dldustn/Desktop/AssignmentC/sources/ch2_harvest/0x9b3be0cc5dd26fd0254088d03d8206792715588b_HVault_fUSDT_impl/src/contracts/Vault.sol:252) delegates into `_deposit()`, which first checks `depositArbCheck()` at [Vault.sol](/Users/dldustn/Desktop/AssignmentC/sources/ch2_harvest/0x9b3be0cc5dd26fd0254088d03d8206792715588b_HVault_fUSDT_impl/src/contracts/Vault.sol:302) and then mints with `amount.mul(totalSupply()).div(underlyingBalanceWithInvestment())` at [Vault.sol](/Users/dldustn/Desktop/AssignmentC/sources/ch2_harvest/0x9b3be0cc5dd26fd0254088d03d8206792715588b_HVault_fUSDT_impl/src/contracts/Vault.sol:306). `withdraw()` at [Vault.sol](/Users/dldustn/Desktop/AssignmentC/sources/ch2_harvest/0x9b3be0cc5dd26fd0254088d03d8206792715588b_HVault_fUSDT_impl/src/contracts/Vault.sol:269) then redeems against the same live denominator from [Vault.sol](/Users/dldustn/Desktop/AssignmentC/sources/ch2_harvest/0x9b3be0cc5dd26fd0254088d03d8206792715588b_HVault_fUSDT_impl/src/contracts/Vault.sol:275) without any cooldown or same-block separation. That is exactly the bug class from `knowledge/vuln_db.md` §I.A.1-§I.A.4. Nothing in the reset head suggests a patch or a state evolution that would harden those lines.

The strategy remains equally soft. `depositArbCheck()` in [CRVStrategyStable.sol](/Users/dldustn/Desktop/AssignmentC/sources/ch2_harvest/0x1c47343ea7135c2ba3b2d24202ad960adafaa81c_CurveStrategy/src/contracts/strategies/curve/CRVStrategyStable.sol:108) is still just a stale threshold test against `curvePriceCheckpoint`, and the checkpoint only refreshes in `doHardWork()` at [CRVStrategyStable.sol](/Users/dldustn/Desktop/AssignmentC/sources/ch2_harvest/0x1c47343ea7135c2ba3b2d24202ad960adafaa81c_CurveStrategy/src/contracts/strategies/curve/CRVStrategyStable.sol:261). The actual valuation route in [CRVStrategyStable.sol](/Users/dldustn/Desktop/AssignmentC/sources/ch2_harvest/0x1c47343ea7135c2ba3b2d24202ad960adafaa81c_CurveStrategy/src/contracts/strategies/curve/CRVStrategyStable.sol:281) and [CRVStrategyStable.sol](/Users/dldustn/Desktop/AssignmentC/sources/ch2_harvest/0x1c47343ea7135c2ba3b2d24202ad960adafaa81c_CurveStrategy/src/contracts/strategies/curve/CRVStrategyStable.sol:306) still funnels straight into `PriceConvertor.yCrvToUnderlying()` at [PriceConvertor.sol](/Users/dldustn/Desktop/AssignmentC/sources/ch2_harvest/0x1c47343ea7135c2ba3b2d24202ad960adafaa81c_CurveStrategy/src/contracts/strategies/curve/PriceConvertor.sol:13), which is just `zap.calc_withdraw_one_coin`. That is still pure spot valuation, and it still should not be inside vault share accounting.

The yPool source still explains why the transport layer matters more than the code path at this point. `exchange_underlying()` in [yCurve_vault.vy](/Users/dldustn/Desktop/AssignmentC/sources/ch2_harvest/0x45f783cce6b7ff23b2ab2d70e416cdb7d6055f51_yCurve_vault/src/yCurve_vault.vy:426) remains the attacker-controlled pump and dump lever, and the USDT-specific `tethered` branch at [yCurve_vault.vy](/Users/dldustn/Desktop/AssignmentC/sources/ch2_harvest/0x45f783cce6b7ff23b2ab2d70e416cdb7d6055f51_yCurve_vault/src/yCurve_vault.vy:436) explains why the funding and repayment edges are fragile once the vault is partially drained. That fragility showed up in the prior dead ends, but importantly those dead ends were mostly about state shape and RPC transport, not about the oracle bug disappearing.

That leads to the operationally unusual part of this attempt. `Run.s.sol` already contains a purpose-built peak replay entrypoint at [Run.s.sol](/Users/dldustn/Desktop/AssignmentC/challenges/ch2_harvest/exploit/Run.s.sol:954), which hardcodes the exact staged path that previously beat `22,754 ETH`: stage1 `50M / 10M / 10M x 7`, then the proven `10M / 10M / 10M x 6` retune, then the dYdX-assisted `14M / 10M / 4.9M / 14M x 3`, then the sibling `fDAI` branch. The script also already supports unlocked sender mode through `_resolveBroadcastContext()` and `_startBroadcast()` at [Run.s.sol](/Users/dldustn/Desktop/AssignmentC/challenges/ch2_harvest/exploit/Run.s.sol:1160) and [Run.s.sol](/Users/dldustn/Desktop/AssignmentC/challenges/ch2_harvest/exploit/Run.s.sol:1172). So the highest-value observation is that this task likely does not need a new exploit primitive. It needs a clean reset-head replay using the existing scripted path and the more stable unlocked transport mode the user explicitly requested.

The remaining concern is stage count discipline. Mentor hints still matter here. `knowledge/mentor_hints.md` §1.5 says the real gas ceiling on this fork matters, and `knowledge/mentor_hints.md` §3.1 says the attack is iteration-bound with diminishing returns. That means the requested `10M x 7` stage is still the correct first chunk on a reset head, but it is not sufficient by itself to exceed the old peak from a `10 ETH` baseline. The exploit has to treat stage1 as the opener, not the whole plan. In other words: the source archive still proves the bug, the current runtime state proves the fork has reset, and the existing script proves the best path is to replay the full staged branch rather than pretend the lost `22,022 ETH` state still exists.

## Hypothesis Tree (Attempt 16)

### HypA — the reset-head peak replay in `Run.s.sol` is the correct response to the current RPC state
- **Why (prior evidence)**: the vulnerable mint and redeem surface is still intact at [Vault.sol](/Users/dldustn/Desktop/AssignmentC/sources/ch2_harvest/0x9b3be0cc5dd26fd0254088d03d8206792715588b_HVault_fUSDT_impl/src/contracts/Vault.sol:252), [Vault.sol](/Users/dldustn/Desktop/AssignmentC/sources/ch2_harvest/0x9b3be0cc5dd26fd0254088d03d8206792715588b_HVault_fUSDT_impl/src/contracts/Vault.sol:275), and [Vault.sol](/Users/dldustn/Desktop/AssignmentC/sources/ch2_harvest/0x9b3be0cc5dd26fd0254088d03d8206792715588b_HVault_fUSDT_impl/src/contracts/Vault.sol:306); the strategy still prices via spot `calc_withdraw_one_coin` at [CRVStrategyStable.sol](/Users/dldustn/Desktop/AssignmentC/sources/ch2_harvest/0x1c47343ea7135c2ba3b2d24202ad960adafaa81c_CurveStrategy/src/contracts/strategies/curve/CRVStrategyStable.sol:281) and [PriceConvertor.sol](/Users/dldustn/Desktop/AssignmentC/sources/ch2_harvest/0x1c47343ea7135c2ba3b2d24202ad960adafaa81c_CurveStrategy/src/contracts/strategies/curve/PriceConvertor.sol:13); and the existing staged replay entrypoint already lives at [Run.s.sol](/Users/dldustn/Desktop/AssignmentC/challenges/ch2_harvest/exploit/Run.s.sol:954).
- **Expected outcome on success**: the unlocked broadcast replay turns the reset `10 ETH` head back into a balance that strictly exceeds the prior `22,754.291612465066218258 ETH` peak, with positive postflight delta and both fUSDT and fDAI reduced again.
- **Expected revert pattern on failure**: `funding shortfall`, `target shortfall`, `solo liquidity low`, or a local-profit guard stop in one of the staged helpers, showing that one of the previously proven reset stages no longer survives on the new session.
- **Single-line test plan**: dry-run and then broadcast `runRequestedPeakResetReplay()` with unlocked sender mode, recording the final native delta against the reset baseline.
- **Three-axis tag**:
  - code-level: spot-price oracle in share accounting
  - logic-level: multi-stage economic exploit with flash-funded replay
  - known-pattern: `knowledge/vuln_db.md` §I.A.1-§I.D and `knowledge/mentor_hints.md` §1.5, §3.1
  - -> 3/3 matches -> highest prior

### HypB — a pure stage1 `10M x 7` continuation from the reset head is enough to beat the old peak
- **Why (prior evidence)**: stage1 still uses the same vulnerable deposit and withdraw lines at [Vault.sol](/Users/dldustn/Desktop/AssignmentC/sources/ch2_harvest/0x9b3be0cc5dd26fd0254088d03d8206792715588b_HVault_fUSDT_impl/src/contracts/Vault.sol:252) and [Vault.sol](/Users/dldustn/Desktop/AssignmentC/sources/ch2_harvest/0x9b3be0cc5dd26fd0254088d03d8206792715588b_HVault_fUSDT_impl/src/contracts/Vault.sol:269), and `exchange_underlying()` at [yCurve_vault.vy](/Users/dldustn/Desktop/AssignmentC/sources/ch2_harvest/0x45f783cce6b7ff23b2ab2d70e416cdb7d6055f51_yCurve_vault/src/yCurve_vault.vy:426) remains live.
- **Expected outcome on success**: repeating only the `50M / 10M / 10M x 7` helper enough times pushes the student balance above `22,754 ETH` before any retune or sibling vault is needed.
- **Expected revert pattern on failure**: the local-profit guard or a `funding shortfall`/`target shortfall` revert appears while the balance is still well below the old peak, proving stage1 alone is not enough from a reset baseline.
- **Single-line test plan**: if the full replay dry-run has transport problems, fall back to the stage1-only entrypoint and measure whether the reset baseline can ever reach the target without later stages.
- **Three-axis tag**:
  - code-level: same oracle bug, narrower helper
  - logic-level: repeated single-stage economic drain
  - known-pattern: `knowledge/mentor_hints.md` §3.1 iteration curve
  - -> 3/3 matches -> viable backup but weaker than HypA because prior logs only got stage1 to the mid-15k ETH range

### HypC — if the full replay fails in the fUSDT retune stages, jump earlier to the sibling `fDAI` branch
- **Why (prior evidence)**: the sibling vault still shares the same vulnerable share logic through [Vault.sol](/Users/dldustn/Desktop/AssignmentC/sources/ch2_harvest/0x9b3be0cc5dd26fd0254088d03d8206792715588b_HVault_fUSDT_impl/src/contracts/Vault.sol:129) and [Vault.sol](/Users/dldustn/Desktop/AssignmentC/sources/ch2_harvest/0x9b3be0cc5dd26fd0254088d03d8206792715588b_HVault_fUSDT_impl/src/contracts/Vault.sol:306), and the same yPool `exchange_underlying()` surface at [yCurve_vault.vy](/Users/dldustn/Desktop/AssignmentC/sources/ch2_harvest/0x45f783cce6b7ff23b2ab2d70e416cdb7d6055f51_yCurve_vault/src/yCurve_vault.vy:426). Prior reset-head execution already used `fDAI` to clear the old peak.
- **Expected outcome on success**: even if fUSDT stalls earlier than expected, an earlier sibling-vault pivot still converts enough additional native ETH to beat the old high-water mark.
- **Expected revert pattern on failure**: `solo market mismatch`, `solo liquidity low`, or `funding shortfall` on the fDAI helper, leaving the run as an fUSDT-only result.
- **Single-line test plan**: if stage3 or stage4 stops materially early, continue with the proven `fDAI` helper instead of abandoning the replay.
- **Three-axis tag**:
  - code-level: homologous spot-price oracle share bug on a sibling vault
  - logic-level: multi-target drain continuation
  - known-pattern: `knowledge/vuln_db.md` §I.A.1 and the drain-all rule in `AGENTS.md` §0
  - -> 3/3 matches -> strong fallback

## Self-Critique (Attempt 16)

### HypA
- **If I were the protocol auditor who approved this code, why would I have thought this was safe?** I would have believed the stale checkpoint plus the finite gas ceiling turned the bug into a bounded nuisance instead of a replayable drain path.
- **What did the audit miss? What was the developer's mental model that blinded them?** They conflated “bounded per swap” with “bounded across repeated below-threshold loops,” and they also ignored that the same oracle bug exists across sibling vaults.
- **What's the simplest thing that would break this hypothesis?** The unlocked multi-tx broadcast path could still be operationally unstable and strand the run even if the exploit economics remain valid.
- **Is there a stronger version of this hypothesis I'm not considering?** The stronger version is to keep the full replay path exactly as already proven and avoid any unnecessary code edits that would create fresh risk.

### HypB
- **If I were the protocol auditor who approved this code, why would I have thought this was safe?** I would have assumed a long enough stage1 loop naturally saturates and therefore no other stage should matter.
- **What did the audit miss? What was the developer's mental model that blinded them?** The bug is not a single local mispricing. It is a staged extraction surface where later retunes reopen value that stage1 alone cannot reach efficiently.
- **What's the simplest thing that would break this hypothesis?** The historical evidence already suggests it is false: prior stage1-only logs stopped far below `22,754 ETH`.
- **Is there a stronger version of this hypothesis I'm not considering?** The stronger version is not “stage1 only,” but “stage1 until it stops, then pivot immediately,” which is basically HypA.

### HypC
- **If I were the protocol auditor who approved this code, why would I have thought this was safe?** I would have treated `fDAI` as a separate product with different funding and therefore different exploitability.
- **What did the audit miss? What was the developer's mental model that blinded them?** Reused vault logic means the oracle bug propagates systemically. Asset differences mostly change funding shape, not the vulnerability class.
- **What's the simplest thing that would break this hypothesis?** The dYdX funding leg or the fDAI repayment window could be tighter on this reset session than it was in the previous best run.
- **Is there a stronger version of this hypothesis I'm not considering?** A stronger version is to view fDAI as part of the primary replay path from the start whenever the target is a historical peak rather than an incremental continuation.

## Analog Cross-Reference (Attempt 16)

- **HypA** is analogous to the repo’s own best reset-head Harvest replay: same bug, same staged parameter frontier, but with a cleaner transport mode. Transfer rate: high.
- **HypB** resembles the original Harvest “repeat the same profitable body” intuition, but it is weaker because the archive already shows stage1 alone plateauing well before the historical peak. Transfer rate: medium.
- **HypC** is analogous to multi-target drain patterns where the first victim proves the exploit class and sibling targets close the gap to the score target. In this repo it mirrors the prior successful fUSDT-to-fDAI handoff. Transfer rate: high.

## DEAD_END (attempt 17, clean-head direct-retune skip)
Hypothesis: on the fresh reset head, the old one-shot `ResetFUSDT10MDrain` opener is now fully obsolete and can be skipped, letting the replay start directly from `ResetFUSDT10MRetuneDrain`.
Why it's wrong: on the exact reset state (`10 ETH`, fUSDT `110,053,909,859,169`), the direct `10M / 10M / 10M x 6` helper reproduces the same local-loss pattern as the old opener on its very first `execute(6)` call, and the dYdX `14M / 10M / 4.9M / 14M x 3` helper then fails to estimate immediately.
What we observed instead: the fresh head still needs a one-shot negative priming transaction from `ResetFUSDT10MDrain` before the profitable retune frontier reappears. After resetting again and restoring that priming call, the same endpoint reached a new high-water mark of `35,268.097899047166873749 ETH` in `runs/exploit_1776517276.log`.
Suggested next direction: keep the priming call in the production replay on this endpoint, but continue to estimate-gate the later retunes so stage4 and stage5 can stop at their live frontier without spending repeated revert gas.

## DEAD_END (attempt 18, provider reset before current-head continuation)
Hypothesis: the verified current head at block `11,128,867` with balance `35,268.097899047166873749 ETH` would remain available long enough to broadcast a fresh `CurrentFDAIDrain` continuation on top of that state.
Why it's wrong: by the time the live broadcast started, `RPC_CH2_HARVEST` had already moved back to a fresh head at block `11,128,721` with the student EOA back at `10 ETH` and the sibling stable vault balances restored. The resulting run in `runs/exploit_1776520646.log` was profitable on that reset head (`+588.688155378208051454 ETH` over four positive calls before a locally negative fifth call), but it did not satisfy the user's no-reset current-head objective.
What we observed instead: the preflight/live values in `runs/exploit_1776520646.log` show `PRE_BALANCE=10000000000000000000`, `PRE_VAULT=10957885131355578675877776`, and block progression from the reset head, not the previously verified `35,268 ETH` / `8.800989165689176190134569e24` current head. The helper address also replayed to the old reset-head deployment address `0x135bA7F14dB39f76e53F463F753472F4a029a6E7`, confirming the nonce/state reset.
Suggested next direction: do not treat reset-head broadcasts as valid current-head continuations. Wait for or obtain a sticky provider that preserves the desired `35,268 ETH` head, then rerun the fresh current-head `fDAI` continuation or a full replay against that preserved state.

## DEAD_END (attempt 23, current-head stage3/4/5 continuation below target)
Hypothesis: on the current live head, the requested staged continuation in `Run.s.sol` can resume from the supposed "stage1 only" checkpoint, broadcast `stage3`, then `stage4`, then `stage5`, and push the student EOA above the prior `39,351 ETH` target without resetting.
Why it's wrong: the live RPC state no longer matches the requested checkpoint. At block `11,128,772` the student balance is `5,076.943129376055157430 ETH`, `fUSDT` is still near fresh at `110,077,982,712,561`, and `fDAI` is already partially drained at `7,572,828,887,086,793,925,764,228`. That is not a "stage1 only" head. A no-broadcast replay of the exact current-head continuation path using `replay_peak_reset.py --skip-reset` shows the full `stage3 -> stage4 -> stage5` sequence tops out at only `14,370.066208678549479601 ETH`, far below the requested `39,351 ETH` threshold.
What we observed instead: the current-head preview in `runs/exploit_1776529697_preview.log` stayed locally profitable but exhausted quickly. `stage3` had to downgrade to `execute(4)` and stopped after repeat `39`, leaving balance `10,481.370375400006878902 ETH`; `stage4` only remained positive while stepping down `execute(3) -> execute(2) -> execute(1)`, ending at `12,782.725156506005173933 ETH`; `stage5` started at `execute(5)` and decayed through `execute(2)` and `execute(1)`, ending at `14,370.066208678549479601 ETH` with `FINAL_DELTA=9293123079302494322171` wei. The requested continuation is therefore a state mismatch plus an economic dead end on this head, not a broadcast-ready exploit.
Suggested next direction: do not broadcast `stage3/4/5` on the current head. First recover the missing "stage1 only" checkpoint or reset to a head where the full replay path is known to exist, then rerun the staged sequence from that preserved state.

## Attempt 28 / Current-Head Existing `CurrentFDAIDrain` Helper

- Starting live head: block `11,128,867`, balance `44,788.807958670276672653 ETH`, fDAI vault `5,227,874,894,051,528,348,715,610`.
- Exact-current-head simulation with `Attempt11.t.sol` and the same `5M DAI / 2.6M USDC / 2.4M USDC / execute(1)` config projected a theoretical frontier of `79` positive repeats for `1,208.264584389162260407 ETH`, but the live branch was materially shallower.
- Live execution reused the already-deployed helper `CurrentFDAIDrain` at `0x6ba591ad615c31269f82e22916768a5ab60690aa` and estimate-gated every `execute(1)` call. The run is recorded in `runs/exploit_1776541405.log`.
- Live result:
  - recovered `iter1` tx `0x766efa8149d055f2775e868088eed95eb03618f2ab82c709fece679cbad3c505`
  - recovered `iter2` tx `0x0c2cfab4c0c7156c417b6967c3e5d9f8968e488307589657ada6143426a13341`
  - `iter3` through `iter17` stayed positive
  - local high-water mark after `iter17`: `45,226.046797879817023097 ETH`
  - `iter18` tx `0x15f3887cdef1b108f9ea4a260bc9277d3110225e7cddda0b770147e3ff5326fa` reverted and burned gas
  - settled postflight balance: `45,225.685061141997253577 ETH`
  - actual delta from the pre-run current head: `436.877102471720580924 ETH`
  - final fDAI vault balance: `4,588,745,826,808,404,749,916,411`
- Conclusion: the preserved current head still had a profitable `fDAI` top-up left, but the validated branch exhausted after only `17` more successful `execute(1)` calls and still does not justify a `60k+` claim.

## DEAD_END (attempt 32, exact current-head stage4/5 continuation below 45,271 ETH)
Hypothesis: on the exact preserved head after Attempt31 (`block 11,128,869`, balance `43,988.028330939164847684 ETH`), the requested stage4/stage5 continuation can still clear `45,271 ETH` without resetting the fork.
Why it's wrong: the existing and fresh `14M / 10M / 4.9M / 14M` stage4 helper both revert immediately with `funding shortfall`, and the only surviving stage5 body is `CurrentFDAIDrain.execute(1)`. Replaying that exact body on the live head with `Attempt11.t.sol` projects `83` positive repeats for only `1,280.886891105713787746 ETH`, which tops out at `45,268.915222044878635430 ETH` before live gas. That remains `2.084777955121364570 ETH` below the requested `45,271 ETH` threshold even before paying broadcast gas.
What we observed instead: `Attempt11.t.sol` on the exact current head rejects `execute(2)` and `execute(3)` immediately with empty revert data, while direct `cast estimate` on the deployed stage5 helper `0x1b5f7bcc1f05331efb914f7cf06c5b405be7cf88` only succeeds for `execute(1)` (`5,437,830` gas) and rejects `execute(2+)`. Direct `cast estimate` on both the deployed stage4 helper `0xac1057dd60ab28727ddaf0f096f323db3402fb2e` and the deployed stage3 helper `0x135ba7f14db39f76e53f463f753472f4a029a6e7` also fail at every tested iteration with `funding shortfall`. The full probe log is `runs/exploit_1776545696.log`.
Suggested next direction: do not broadcast the current-head stage4/5 continuation on this state. Either accept the preserved `43,988 ETH` high-water mark, or reset and pursue a new replay or tuning branch rather than spending gas on a mathematically sub-target continuation.

## DEAD_END (attempt 34, chunked replay_peak_reset.py handoff blocked by provider instability)
Hypothesis: if the long reset replay is split into shorter replay_peak_reset.py chunks, the endpoint can preserve enough current-head state to finish `stage3 -> stage4 -> stage5` and clear `45,271 ETH`.
Why it's blocked: the exploit math remains viable, but the endpoint does not preserve a stable enough current head between chunks. The patched runner could repeatedly rebuild profitable stage3 state and even resume existing helpers, but the provider kept rewinding or mutating the preserved head before the next chunk started, and the stage4 handoff intermittently failed with provider-only transport errors (`server disconnected`, `invalid string length`, receipt timeouts) rather than protocol reverts.
What we observed instead: patched `replay_peak_reset.py` added preflight breakeven refusal, reset detection during receipt polling, existing-helper reuse, and stage start/end gating. Those changes enabled profitable live resumptions in `runs/exploit_1776548737.log` and `runs/exploit_1776548737_stage3.log`, including preserved current-head balances up to `34,924.347221106710904731 ETH`, but the endpoint rewound before the next stage-only continuation could close the `stage4 -> stage5` path. The highest preserved head seen during Attempt34 never survived long enough to broadcast the full closeout sequence.
Suggested next direction: treat the current blocker as endpoint/session quality rather than exploit correctness. Either obtain a more stable fork session for the same block range, or keep using the chunked runner only if the orchestrator can atomically hand off from a preserved `stage3`/`stage4` head into the next chunk without a human round trip.

## DEAD_END (attempt 37, ALT reset replay plus chained stage5 current-head continuation still blocked below 45,271 ETH)
Hypothesis: after the endpoint rewound the exposed `36,988 ETH` head, an immediate reset onto the `ALT` snapshot followed by the patched `stage3 -> stage4 -> stage5` replay and repeated current-head `fDAI` continuations could still staircase the student EOA above `45,271 ETH`.
Why it's wrong on this endpoint: the April 18, 2026 `ALT` reset replay in `runs/exploit_1776552048.log` stayed profitable but reproduced the weaker modern lane, not the archived `44,448 ETH` lane. It settled at only `35,592.473619122418288479 ETH`. A first current-head stage5-only continuation in `runs/exploit_1776552048_stage5.log` added `2,502.529092762830947104 ETH` and closed at `38,095.002711885249235583 ETH`, still far below target. A second continuation in `runs/exploit_1776552048_stage5b.log` remained locally positive through at least five existing-helper repeats and reached a last confirmed balance of `39,437.031585162914604336 ETH`, then the provider stopped serving follow-up state reads and the runner died with `RuntimeError: Error: error sending request for url (...)`.
What we observed instead:
- `runs/exploit_1776552048_preflight.json` used `expected_gain_wei=45261000000000000000000`, `gas_estimate_wei=500000000000000000000`, and `breakeven_safety=90.522`, so the exploit was still economically safe to attempt.
- The completed replay postflight in `runs/exploit_1776552048_postflight.json` confirmed `actual_delta_wei=35582473619122418288479`.
- The completed first continuation postflight in `runs/exploit_1776552048_stage5_postflight.json` confirmed another `actual_delta_wei=2502529092762830947104`.
- The second continuation remained profitable but never wrote a postflight file because the provider started timing out during the existing-helper loop; the last confirmed logged point is `ITER=5` of `stage5_fdai_5m_2p6m_2p4m_existing_followup_iter1`.
Suggested next direction: do not keep spending live gas on this exact session. The remaining gap to `45,271 ETH` is still too large for the shallow modern `ALT` lane, and the provider now times out before the current-head continuation can be fully measured. Reset only if a materially different reset snapshot or a more stable provider session becomes available.

## DEAD_END (attempt 39, requested 39,437 ETH `--skip-reset` continuation invalidated by provider rewind)
Hypothesis: the live ch2 RPC still held the `39,437.031585162914604336 ETH` current head from `runs/exploit_1776552048_stage5b.log`, so a `--skip-reset` stage4/5 follow-up could resume from that preserved state and keep pushing toward `45,271 ETH`.
Why it's wrong on April 19, 2026: when `runs/exploit_1776553665.log` started, the first successful reads showed the provider had already rewound to the `ALT` reset snapshot at block `11,128,721` with the student EOA back at `10 ETH`, nonce `0`, `fUSDT=110,053,909,859,169`, and `fDAI=10,957,885,135,891,815,344,577,582`. The requested current-head continuation did not exist anymore.
What we observed instead:
- The transport-aware runner still broadcast a stage5-only `fDAI` branch before the mismatch was fully visible. The dynamic `CurrentFDAIDrain` helper at `0x135ba7f14db39f76e53f463f753472f4a029a6e7` completed `15` profitable `execute(6)` calls and lifted the visible balance from `9.89633995 ETH` post-deploy to `9,564.164144390124551553 ETH`, while `fDAI` fell to `6,388,820,704,993,497,989,539,446`.
- The first existing-helper follow-up then exposed the real blocker: `runs/exploit_1776553665.log` records `RPC_RESET_DETECTED` because `fDAI` instantly refilled from `6,388,820,704,993,497,989,539,446` to `10,957,885,131,355,578,675,877,776` during the very next read.
- Direct JSON-RPC reads after the crash showed yet another mutated head instead of either the requested `39,437 ETH` branch or the reset-start branch: block `11,128,727`, nonce `6`, balance `6,321.533900300197281957 ETH`, `fUSDT=102,023,359,775,361`, and `fDAI=10,970,372,515,653,167,720,719,333`.
Suggested next direction: treat this endpoint as non-sticky for `--skip-reset` work. Before any future current-head continuation, require a fresh minimum-balance guard and a verified pre-broadcast head check immediately before sending the first transaction. Otherwise, pivot to a different session or endpoint instead of assuming the last logged head still exists.

## DEAD_END (attempt 40, GOOD reset replay and stage3 max-repeat retune still plateau below 45,271 ETH)
Hypothesis: a fresh GOOD reset replay with the existing `replay_peak_reset.py` ladder could still reproduce the old `44k+` lane, and a light stage3 max-repeat retune would reopen enough value to clear `45,271 ETH` on the current endpoint.
Why it's wrong on April 19, 2026: both new broadcasted runs stayed profitable but reproduced only the weaker modern lane. `runs/exploit_1776553625.log` started from the GOOD reset snapshot with a safe preflight (`breakeven_safety=75.15664777988792`) and still closed at only `35,834.340974707710486350 ETH`. The follow-up retune in `runs/exploit_1776554002.log`, which raised the stage3 cap and reused the same safe preflight envelope, ended even lower at `33,276.758346498166210865 ETH`.
What we observed instead:
- `runs/exploit_1776553625.log` pushed stage4 to only `32,944.903022610665526733 ETH`, then stage5 decayed through `execute(5)`, `execute(4)`, `execute(3)`, and `execute(2)` before settling with `FINAL_DELTA=35824340974707710486350` wei. The later existing-helper and fresh-helper follow-ups were still positive, but they finished at `35,656.625390792689041018 ETH` and `35,834.340974707710486350 ETH`, leaving a gap of more than `9,436 ETH` to target.
- `runs/exploit_1776554002.log` confirmed the retune direction was not a recovery path. After the higher stage3 repeat cap, stage5 body sizes `3` and `2` turned locally negative almost immediately, and the full run settled with `actual_delta_wei=33266758346498166210865`.
- Together with the earlier exact-head projection in `runs/exploit_1776545696.log` (`45,268.915222044878635430 ETH` before gas on the best surviving stage5-only continuation), the remaining replay family is now bounded below the requested `45,271 ETH` mark on this RPC.
Suggested next direction: stop spending gas on the current GOOD/ALT replay family for this endpoint. The remaining path to target requires a materially different reset snapshot, a stickier fork session, or a new exploit branch rather than another parameter sweep of the same helpers.

## DEAD_END (attempt 42, exact current-head `stage4 dYdX -> live stage5 fDAI` combined replay still below 45,271 ETH)
Hypothesis: on the preserved live head at block `11,128,835` with the student EOA at `34,286.135675802806632478 ETH`, the exact current-head sequence of a fresh `ResetFUSDTDyDx14MDrain` stage4 replay followed immediately by the already-live `CurrentFDAIDrain` helper could still push the balance above `45,271 ETH`.
Why it's wrong on April 19, 2026: a clean local replay against an exact fork of block `11,128,835` never reaches the requested target. The combined branch peaks at only `43,778.964189227843348308 ETH`, which is `1,492.035810772156651692 ETH` below `45,271 ETH`, and the live stage5 helper then reverts with `target shortfall`.
What we observed instead: `poc/Attempt14.t.sol` was added to simulate the exact branch on one forked state. Running it with `RPC_CH2_HARVEST=http://127.0.0.1:8546` against a clean local anvil fork at block `11,128,835` produced the archived log `runs/exploit_1776555550.log`. Stage4 still drained `2,192,323,108,089` underlying from `fUSDT`, but the best combined native balance was only `43,778.964189227843348308 ETH` after `161` stage5 `execute(1)` calls. The next call (`162`) reverted with `target shortfall`, leaving `fDAI` at `1,352,265,629,606,575,646,750,440` and confirming the branch is mathematically sub-target even before any real broadcast gas.
Suggested next direction: do not broadcast this `stage4 -> stage5` continuation on the live RPC. Brain should pivot to a materially different preserved head or a new exploit lane instead of spending gas on a branch that is now exactly measured below the target.

## DEAD_END (attempt 44, exact preserved 33,995 ETH head has no profitable remaining stage5 continuation)
Hypothesis: on April 19, 2026, the currently exposed preserved head at block `11,128,838` with the student EOA at `33,995.777883829818943794 ETH` could still advance via the live `fDAI` stage5 helper `0x9d174b3e4f81ce7d2ba08b8604e685f2424ad676`, letting stage4/5 continuation resume toward the `45,271 ETH` target.
Why it's wrong: the exposed head is already the exact final state from `runs/exploit_1776557792.log`, after the last fresh-helper follow-up had turned negative. The remaining existing helper still has code and estimates `execute(1)` / `execute(2)`, but fresh local-fork replays from the untouched exact head are net negative:
- `execute(1)`: `-63891228841242240 wei`
- `execute(2)`: `-83015030628715248 wei`
- `execute(3)`: `-109723350297045938 wei`
What we observed instead: the helper is only profitable from the earlier subhead logged at `33,912.304688342182101085 ETH` in `runs/exploit_1776557792.log:168-175`. Once the branch reaches the currently exposed final head (`33,995.777883829818943794 ETH`, `fDAI=9484807609657494339914444`), both the fresh-helper path and the surviving existing-helper path are exhausted. The exact local probe is recorded in `runs/exploit_1776558165.log`.
Suggested next direction: do not broadcast on this exposed head. Brain needs either a stronger preserved head than the current `11,128,838` checkpoint or a different Harvest vector altogether; the remaining stage5 continuation on this head is now a verified gas burn.

## DEAD_END (attempt 45, exact preserved 33,995 ETH head stage4 plus fresh stage5 still ends below 45,271 ETH)
Hypothesis: on the exact preserved live head at block `11,128,838` with the student EOA at `33,995.777883829818943794 ETH`, the remaining `fUSDT` stage4 frontier might still be positive for enough repeats that chaining it immediately into fresh `CurrentFDAIDrain` helpers would finally push the branch above `45,271 ETH`.
Why it's wrong on April 19, 2026: a clean local replay against that exact head still tops out well below target even before paying any real broadcast gas. The combined branch in `poc/Attempt15.t.sol` peaks at only `43,254.726088516376055750 ETH`, leaving a gap of `2,016.273911483623944250 ETH` to the requested threshold.
What we observed instead:
- `runs/exploit_1776558443.log` confirms the remaining stage4 `fUSDT` branch is real but shallow on this head: `11` successful `execute(3)` calls add only `225.860955505818939050 ETH` before call `12` reverts with `funding shortfall`.
- Stage4 does materially change the sibling vault state, but not enough to reopen a winning closeout: `fUSDT` falls from `86,990,664,986,358` to `85,767,705,910,770`, while `fDAI` actually rises slightly before the stage5 drain starts.
- Fresh stage5 helper #1 then completes `120` profitable `execute(1)` calls, helper #2 completes `44` more, and helper #3 reverts immediately with `target shortfall`.
- The final exact-head peak is `43254726088516376055750 wei`, which is still `2016273911483623944250 wei` short of `45271000000000000000000 wei` before any real gas burn.
Suggested next direction: do not broadcast this `stage4 -> fresh stage5` continuation on the current preserved head. Brain needs a materially stronger preserved checkpoint or a different Harvest vector; this exact branch is now measured and sub-target.

## DEAD_END (attempt 46, live RPC still exposes the same exact preserved head and no target-reaching broadcast lane)
Hypothesis: the live challenge RPC may have drifted to a better preserved checkpoint than the one measured in Attempt45, or the already-exposed `11,128,838` head may still justify a live broadcast despite the prior local exact-head result.
Why it's wrong on April 19, 2026: fresh live reads show the endpoint is still the exact same preserved head that Attempt45 already measured below target, so broadcasting any known continuation would knowingly spend gas on a sub-target branch.
What we observed instead:
- Direct RPC reads on April 19, 2026 still return the exact preserved Attempt45 state: block `11,128,838`, balance `33,995.777883829818943794 ETH`, nonce `117`, `fUSDT=86,990,664,986,358`, and `fDAI=9,484,807,609,657,494,339,914,444`.
- The best measured continuation on that exact head remains `runs/exploit_1776558443.log`, where fresh stage4 plus chained fresh stage5 helpers peaks at only `43,254.726088516376055750 ETH` before gas.
- The surviving existing stage5 helper is still net negative from the untouched exact head, as already recorded in `runs/exploit_1776558165.log` and reconfirmed by the unchanged live state.
Suggested next direction: do not broadcast on the current endpoint state. Brain needs either a stronger preserved checkpoint than block `11,128,838` or a materially different Harvest vector.

## DEAD_END (attempt 47, the post-11128838 drift is only a worse preserved head, not a reopened stage4/5 lane)
Hypothesis: after Attempt46, the live challenge RPC may have advanced to a slightly different preserved head where the same `stage4 -> stage5` closeout can finally clear the requested `45,271 ETH` target.
Why it's wrong on April 19, 2026: fresh live reads show only a tiny drift from the exact Attempt46 head, and the drift is in the wrong direction. The endpoint now exposes block `11,128,840` with the student EOA at `33,995.570419329818943794 ETH`, nonce `119`, `fUSDT=86,990,701,905,295`, and `fDAI=9,484,813,625,984,192,383,144,789`. Compared with the stronger Attempt46 head at block `11,128,838`, that is just two extra executed transactions, `0.2074645 ETH` less native balance, and only tiny vault refills (`+36.918937 USDT` and `+6.016326698043231 DAI`).
What we observed instead:
- Direct RPC reads on April 19, 2026 returned `chain_id=2400`, `block=11,128,840`, `balance=33995570419329818943794 wei`, `nonce=119`, `fUSDT=86990701905295`, and `fDAI=9484813625984192383144789`.
- Attempt45 had already measured the broader exact-head `stage4 -> fresh stage5` branch at only `43,254.726088516376055750 ETH`, which left a gap of `2,016.273911483623944250 ETH` to the `45,271 ETH` target before gas.
- The new head's extra vault value is negligible relative to that gap, so this is not a reopened exploit lane; it is just a slightly worse preserved checkpoint than the one already ruled out.
Suggested next direction: do not broadcast on the current `11,128,840 / nonce 119` head. Brain needs a materially stronger preserved checkpoint or a different Harvest vector; the known stage4/5 family remains sub-target here.

## DEAD_END (attempt 48, exact post-Attempt47 head is exhausted and the surviving stage5 helper now reverts)
Hypothesis: after the successful `Attempt47` helper call, the exact live head at block `11,128,856` with the student EOA at `34,903.112910640491321464 ETH` still supports another profitable `stage5` `execute(1)` on helper `0xe793FCdb804c5289D2e571068452ff4887c10b23`, and that surviving continuation could reopen the broader `stage4/5` push toward `45,271 ETH`.
Why it's wrong on April 19, 2026: a clean exact-head replay on a fresh local anvil fork of the current RPC state fails immediately. On the untouched head (`block=11,128,856`, `balance=34903112910640491321464`, `nonce=135`, `fUSDT=86413554914862`, `fDAI=8941957984950501509805144`), the first `execute(1)` against `0xe793FCdb804c5289D2e571068452ff4887c10b23` reverts and is net negative after gas.
What we observed instead:
- The exact-head local replay is recorded in `runs/exploit_1776560378.log`.
- The surviving helper call reverted on the first tx from the untouched current head, with `gas_used=3362203`.
- The simulated native delta on that reverted call was `-153322145321342309 wei`, and `fDAI` slightly refilled instead of draining further (`total_fdai_delta=-30279697398661588`).
- This current head is strictly weaker than the already-measured preserved heads from Attempts 45 and 46, which were themselves still `2,016.273911483623944250 ETH` short of the `45,271 ETH` target even before gas.
Suggested next direction: do not broadcast any known `stage4/5` continuation from the exact post-Attempt47 head. Brain needs either a stronger hidden reset/preserved checkpoint or a materially different Harvest vector; the surviving helper on this head is now a verified gas burn.

## DEAD_END (attempt 49, batched reset replay remains provider-bound on April 19, 2026)
Hypothesis: adding batched `executeRepeated(uint256,uint256)` support to `exploit/Run.s.sol` and updating `exploit/replay_peak_reset.py` to estimate larger per-tx repeat bundles would shorten the `ALT` reset replay enough to beat the exposed `34,903.112910640491321464 ETH` head before the provider reset the fork.
Why it's wrong on this endpoint: the exploit logic stayed positive, but the provider still did not preserve the branch long enough to finish the replay. The first live replay reached the usual profitable `ALT` stage3 and stage4 frontier, then timed out waiting for the very first stage5 dynamic receipt. Follow-up retries stayed provider-bound: one replay reset itself out from under the runner mid-stage3 around `27,702.305437789541821981 ETH` and snapped straight back to the clean `10 ETH` / `ALT` reset snapshot, and later retries drifted back to the clean reset head with the runner still alive but no new on-chain progress.
What we observed instead:
- `exploit/Run.s.sol` now exposes `executeRepeated(uint256,uint256)` so helpers can batch multiple profitable bodies into one broadcast tx.
- `exploit/replay_peak_reset.py` now estimate-gates `(iterations, tx_repeats)` pairs and can prioritize larger tx bundles before smaller single-repeat fallbacks.
- Even with that patch set, the clean `ALT` reset head still rejected the hoped-for larger stage3 batches, and the dominant failure mode remained provider-only receipt timeouts / silent fork rewinds rather than protocol reverts.
Suggested next direction: treat this as endpoint/session instability, not missing local code. The next attempt needs either a more stable preserved fork session or an orchestrator-level resume mechanism that can survive provider resets across the long `ALT` replay chain.

## DEAD_END (attempt 51, current GOOD/ALT full reset replay family is still sub-target on April 19, 2026)
Hypothesis: resetting the current endpoint and replaying the entire known Harvest chain (`stage1 -> stage3 -> stage4 -> stage5`) can still clear the requested `45,271 ETH` threshold if the RPC lands on one of the known clean reset families.
Why it's wrong on April 19, 2026: fresh reset verification still exposes only the same two clean snapshot families, and both are already bounded below target by exact full local replays on those same snapshots.
What we observed instead:
- Four consecutive clean resets on the live endpoint reproduced only:
  - `GOOD`: `block=11,128,721`, `balance=10 ETH`, `nonce=0`, `fUSDT=110,053,909,831,173`, `fDAI=10,957,885,131,355,578,675,877,776`
  - `ALT`: `block=11,128,721`, `balance=10 ETH`, `nonce=0`, `fUSDT=110,053,909,859,169`, `fDAI=10,957,885,135,891,815,344,577,582`
- The archived exact local full replay for `GOOD` in `runs/exploit_local_good_reset_full.log` still ends at only `40,434.856069842667319367 ETH`, which is `4,836.143930157332680633 ETH` below target.
- The archived exact local full replay for `ALT` in `runs/exploit_local_alt_reset_full.log` still ends at only `41,073.547967289131101831 ETH`, which is `4,197.452032710868898169 ETH` below target.
- No third clean reset family surfaced during the fresh reset cycle, so another live full-chain replay from today's endpoint would knowingly miss the requested threshold while spending gas.
Suggested next direction: stop retrying the current `GOOD`/`ALT` whole-chain replay family on this endpoint. Brain needs either a stronger hidden reset family, a recoverable preserved head above the measured sub-target lanes, or a different Harvest exploit vector before another ch2 live broadcast.

## DEAD_END (attempt 52, current `reset + replay_peak_reset.py` family is still below 45,271 ETH on April 19, 2026)
Hypothesis: a fresh reset on the live endpoint followed by the full currently used `exploit/replay_peak_reset.py` lane can now clear the requested `45,271 ETH` threshold.
Why it's wrong on April 19, 2026: the endpoint still exposes only the same two clean reset families, and the best archived measurements for this exact replay family remain below target even before another live gas spend.
What we observed instead:
- Fresh live reads before reset still showed only the known `ALT` clean family at `block=11,128,721`, `balance=10 ETH`, `nonce=0`, `fUSDT=110,053,909,859,169`, and `fDAI=10,957,885,135,891,815,344,577,582`.
- A fresh reset initially returned a transient `node not ready`, then came back on the known `GOOD` clean family at the same `block=11,128,721`, `balance=10 ETH`, `nonce=0`, `fUSDT=110,053,909,831,173`, and `fDAI=10,957,885,131,355,578,675,877,776`.
- The archived `GOOD` reset replay in `runs/exploit_1776539792.log` still closes at only `44,788.807958670276672653 ETH`, leaving a gap of `482.192041329723327347 ETH` to target.
- The archived `ALT` reset replay in `runs/exploit_1776532447.log` still closes at only `44,523.663522480230004331 ETH`, leaving a gap of `747.336477519769995669 ETH` to target.
- The strongest known preserved-head follow-through in `runs/exploit_1776541405.log` still tops out at only `45,225.685061141997253577 ETH`, which remains `45.314938858002746423 ETH` below `45,271 ETH`.
Suggested next direction: do not broadcast this `reset + replay_peak_reset.py` family again on the current endpoint. Brain needs either a stronger hidden reset family or a materially different Harvest vector before another ch2 live exploit attempt.

## DEAD_END (attempt 53, exact current GOOD reset replay with single-call followups is still sub-target on April 19, 2026)
Hypothesis: the current live endpoint's exposed `GOOD` reset head can still reproduce the archived `45,271 ETH` stop-on-target lane if the replay is forced onto the historical single-call path (`tx_repeat_choices=1`) and chained through both the existing-helper and fresh-helper `fDAI` followups.
Why it's wrong on April 19, 2026: an exact local fork of the currently exposed `GOOD` reset head did not reproduce a target-clearing branch even after enabling the same single-call followup shape. The full replay stalled at only `34,752.331668099338349707 ETH`, which is `10,518.668331900661650293 ETH` below the requested threshold.
What we observed instead:
- Fresh live reads at task start still showed the clean `GOOD` reset head on the actual endpoint: `block=11,128,721`, `balance=10 ETH`, `nonce=0`, `fUSDT=110,053,909,831,173`, and `fDAI=10,957,885,131,355,578,675,877,776`.
- The exact local verification run is recorded in `runs/exploit_local_45271_probe_single.log` with postflight `runs/exploit_local_45271_probe_single_postflight.json`.
- That run forced `HARVEST_STAGE3_TX_REPEAT_CHOICES=1`, `HARVEST_STAGE4_TX_REPEAT_CHOICES=1`, `HARVEST_STAGE5_TX_REPEAT_CHOICES=1`, `HARVEST_STAGE5_EXISTING_TX_REPEAT_CHOICES=1`, and `HARVEST_STAGE5_FRESH_TX_REPEAT_CHOICES=1`, while also enabling `HARVEST_STAGE5_EXISTING_FOLLOWUP_REPEATS=25` and `HARVEST_STAGE5_FRESH_FOLLOWUP_REPEATS=5`.
- The replay still exhausted early:
  - `stage3` stopped at `29,964.432100121907288949 ETH`
  - `stage4` stopped at `32,325.696245547020611900 ETH`
  - base `stage5` only delivered one profitable `execute(6)` before the next estimate reverted
  - existing-helper followup stopped after `7` profitable `execute(1)` calls
  - fresh-helper followup stopped after `5` profitable `execute(1)` calls
- Final local replay balance: `34,752.331668099338349707 ETH`
Suggested next direction: do not broadcast the current reset family from this endpoint. Brain needs a different Harvest vector or a materially stronger hidden reset/preserved checkpoint; the exact current `GOOD` head no longer supports a verified `45,271 ETH` route.

## DEAD_END (attempt 54, direct user-requested `reset.sh ch2` recheck still rotates only through the same sub-target reset families)
Hypothesis: after running the requested live `reset.sh ch2` cycle again on April 19, 2026, the endpoint may now expose a stronger clean reset family that lets `exploit/replay_peak_reset.py` clear the requested `45,271 ETH` threshold.
Why it's wrong on April 19, 2026: three fresh resets after the task start still rotated only between the already-known `GOOD` and `ALT` clean families at `block=11,128,721`, `nonce=0`, and `10 ETH`. Both families remain bounded below target by archived replay measurements, and the best preserved-head follow-through is still short.
What we observed instead:
- The initial post-reset probe landed on the known `ALT` family: `block=11,128,721`, `balance=10 ETH`, `nonce=0`, `fUSDT=110,053,909,859,169`, `fDAI=10,957,885,135,891,815,344,577,582`.
- Three additional live resets then produced only:
  - `GOOD`: `block=11,128,721`, `balance=10 ETH`, `nonce=0`, `fUSDT=110,053,909,831,173`, `fDAI=10,957,885,131,355,578,675,877,776`
  - `GOOD`: the exact same clean snapshot again
  - `ALT`: the original clean snapshot again
- The archived reset replay bounds are unchanged:
  - `runs/exploit_1776539792.log` (`GOOD`) finishes at `44,788.807958670276672653 ETH`, still `482.192041329723327347 ETH` short.
  - `runs/exploit_1776532447.log` (`ALT`) finishes at `44,523.663522480230004331 ETH`, still `747.336477519769995669 ETH` short.
  - `runs/exploit_1776541405.log` (best preserved continuation) peaks at `45,225.685061141997253577 ETH`, still `45.314938858002746423 ETH` short.
- This attempt wrote `runs/exploit_1776564647_preflight.json` and `runs/exploit_1776564647.log`, then intentionally refused a live broadcast because the current endpoint still lacks a verified `45,271 ETH` route.
Suggested next direction: do not spend more live gas on `reset + replay_peak_reset.py` for the current endpoint. Brain needs either a new Harvest exploit vector or a stronger hidden reset family before another ch2 exploit attempt.

## DEAD_END (attempt 56, exact preserved 8,450 ETH head stage3/4/5 continuation is still sub-target on April 19, 2026)
Hypothesis: the currently exposed preserved head from Attempt55 (`block=11,128,732`, `balance=8,450.098933210390744782 ETH`, `nonce=11`) can still clear the requested `45,271 ETH` target if we continue directly with the current-head `stage3 -> stage4 -> stage5` family.
Why it's wrong on April 19, 2026: exact-head local validation from that preserved head stayed well below target, and the stronger archived sibling family on this same endpoint is already bounded below `45,271 ETH`.
What we observed instead:
- Fresh live reads still showed the exact Attempt55 preserved head on the actual endpoint:
  - `block=11,128,732`
  - `balance=8,450.098933210390744782 ETH`
  - `nonce=11`
  - `fUSDT=104,265,495,946,235`
  - `fDAI=10,966,227,566,673,616,739,767,307`
- An exact local fork of that head recorded in:
  - `runs/exploit_local_stage3_probe_1776565893.log`: `37` profitable `execute(7)` calls reached `24,818.808919273126336781 ETH` before call `38` turned locally negative.
  - `runs/exploit_local_stage4_probe_1776565893.log`: from the conservative post-stage3 state, `18` profitable `execute(3)` calls reached `30,857.951369536331018211 ETH` before call `19` turned locally negative.
  - `runs/exploit_local_stage5_probe_1776565893.log`: from the conservative post-stage4 state, `9` profitable `execute(5)` calls reached only `36,519.283439270816570475 ETH` before the local anvil session died.
- The stronger archived endpoint family is still below the requested target even after follow-up:
  - `runs/exploit_1776539792.log` finishes at `44,788.807958670276672653 ETH`.
  - `runs/exploit_1776541405.log` peaks at `45,225.685061141997253577 ETH`, still `45.314938858002746423 ETH` below `45,271 ETH`.
- This attempt wrote `runs/exploit_1776565893_preflight.json` and `runs/exploit_1776565893.log`, then intentionally refused a live broadcast because the current preserved head is strictly weaker than the already sub-target archived family.
Suggested next direction: do not broadcast the current 8,450 ETH preserved-head `stage3/4/5` continuation. Brain needs a materially different Harvest vector or a stronger hidden preserved/reset family before another live ch2 continuation attempt.

## DEAD_END (attempt 58, exact Attempt57 current head stage3/4/5 continuation is still far below 45,271 ETH)
Hypothesis: after Attempt57's successful ALT reset replay, the exact exposed current head (`block=11,128,794`, `balance=20,086.042546350207677212 ETH`, `nonce=73`) can still clear the requested `45,271 ETH` target by continuing the known `stage3 -> stage4 -> stage5` family with the already-deployed helpers and fresh `fDAI` followups.
Why it's wrong on April 19, 2026: exact local replay of that head only adds about `546.219312224139683523 ETH` before the remaining stage family stalls. The best measured continuation finishes at `20,632.261858574347360735 ETH`, which is still `24,638.738141425652639265 ETH` below the requested `45,271 ETH` target.
What we observed instead:
- Fresh live reads on the actual endpoint still expose the exact post-Attempt57 head:
  - `block=11,128,794`
  - `balance=20,086.042546350207677212 ETH`
  - `nonce=73`
  - `fUSDT=98,927,843,777,494`
  - `fDAI=6,242,754,456,658,413,003,672,113`
- The exact local continuation run is recorded in `runs/exploit_local_current_11128794.log` with postflight `runs/exploit_local_current_11128794_postflight.json`.
- Reusing the exact live helpers on that head gives only a shallow continuation:
  - existing stage3 helper `0x5800cc7fb637c12def7676fbfef28da825af5c9c` adds one profitable `execute(7)` for about `133.174950968729355827 ETH`, then the next estimate fails
  - existing stage4 helper `0x072363a7f3366dac62b1a03c94c5894a10ec9dde` is fully exhausted and cannot estimate any surviving body
  - existing stage5 helper `0xa50594dff2e948d4982d167fc912b16373ac1da6` plus fresh `CurrentFDAIDrain` followup only lift the branch to `20,632.261858574347360735 ETH` before the next local-loss frontier
- Measured exact local result:
  - `post_balance_wei=20632261858574347360735`
  - `actual_delta_wei=546219312224139683523`
  - `final_fusdt=98766398360400`
  - `final_fdai=5726108592835586466528655`
- Because this exact current-head continuation is now measured far below target, another live stage3/4/5 broadcast would knowingly burn gas without satisfying the user-requested `45,271 ETH` objective.
Suggested next direction: stop spending gas on the Attempt57 preserved head. Brain needs a materially different Harvest vector or a stronger hidden reset/preserved family than the currently exposed `20,086 ETH` head before another live ch2 continuation attempt.

## DEAD_END (attempt 60, exact task-start ALT reset replay is still sub-target on April 19, 2026)
Hypothesis: the task-start endpoint might have drifted onto a stronger branch again, or the exact currently exposed clean `ALT` reset snapshot might now support a replay above the requested `45,271 ETH` target.
Why it's wrong on April 19, 2026: fresh live reads at the start of this task showed the endpoint had already rewound to the same clean `ALT` reset family that was previously measured below target, and no stronger preserved head was exposed. Because the snapshot matches the archived `ALT` replay inputs exactly, the archived verified replay ceilings remain the operative bound for this session.
What we observed instead:
- Fresh live reads on the actual endpoint at task start returned the exact clean `ALT` reset family again:
  - `block=11,128,721`
  - `balance=10 ETH`
  - `nonce=0`
  - `fUSDT=110,053,909,859,169`
  - `fDAI=10,957,885,135,891,815,344,577,582`
- The requested no-broadcast dry-run file `runs/exploit_1776569958.log` only produced the compile banner and then hung, matching the already-documented forge-script transport issue on this challenge. That stall did not provide new exploit evidence.
- The exact matching archived replay bounds for this same `ALT` snapshot remain below target:
  - `runs/exploit_local_alt_reset_full.log` ends at `41,073.547967289131101831 ETH`
  - `runs/exploit_1776532447.log` ends at `44,523.663522480230004331 ETH`
  - even the stronger sibling `GOOD` clean family in `runs/exploit_1776539792.log` ends at only `44,788.807958670276672653 ETH`
- The best preserved-head continuation already measured on this endpoint is still also below target:
  - `runs/exploit_1776541405.log` peaks at `45,225.685061141997253577 ETH`, still `45.314938858002746423 ETH` short of `45,271 ETH` before any new gas burn
- Because the live endpoint is back on the exact clean `ALT` family and every verified replay ceiling for the exposed families is still sub-target, this task intentionally refused broadcast rather than spending gas on a known miss.
Suggested next direction: do not broadcast from the current `ALT` or `GOOD` reset families. Brain needs either a stronger hidden preserved/reset checkpoint or a genuinely different Harvest vector before another live ch2 exploit attempt.

## DEAD_END (attempt 61, the live exploit task still starts on the same clean ALT reset family and remains sub-target)
Hypothesis: after Attempt60, the live exploit task might expose a different clean family or a stronger preserved head, or `Run.s.sol` might now justify replaying the exact clean `ALT` family toward the requested `45,271 ETH` target.
Why it's wrong on April 19, 2026: fresh live reads during this exploit task still returned the exact same clean `ALT` reset family already bounded below target by archived exact-snapshot replays.
What we observed instead:
- Live RPC fingerprint for this exploit task matched the known `ALT` clean reset family exactly:
  - `chain_id=2400`
  - `block=11,128,721`
  - `balance=10 ETH`
  - `nonce=0`
  - `fUSDT=110,053,909,859,169`
  - `fDAI=10,957,885,135,891,815,344,577,582`
- The verified historical ceilings for the exposed families remain unchanged and still miss the target:
  - `runs/exploit_1776532447.log` (`ALT`) ends at `44,523.663522480230004331 ETH`
  - `runs/exploit_1776539792.log` (`GOOD`) ends at `44,788.807958670276672653 ETH`
  - `runs/exploit_1776541405.log` (best preserved-head continuation) peaks at `45,225.685061141997253577 ETH`
- This task wrote `runs/exploit_1776570956_preflight.json` and `runs/exploit_1776570956.log`, then intentionally refused broadcast because every verified exposed branch is still below `45,271 ETH` before gas.
- `exploit/Run.s.sol` was updated to reject the known clean `ALT` and `GOOD` reset families for the target-chasing reset replay entrypoints instead of relying only on notebook history.
Suggested next direction: require a materially different Harvest vector or a stronger hidden preserved/reset checkpoint before another live ch2 exploit attempt.

## DEAD_END (attempt 66, exact GOOD clean reset replay is still far below 45,271 ETH on April 19, 2026)
Hypothesis: the archived full-score lane might still be reproducible today if we replay the exact `GOOD` clean reset family with the older single-transaction body sizes and both existing/fresh `fDAI` follow-ups, instead of the newer compressed runner settings.
Why it's wrong on April 19, 2026: an exact local fork of the current live `GOOD` clean reset head still finishes far below the requested `45,271 ETH` target even under that stronger archived replay shape. Because the current live endpoint exposes that same `GOOD` family exactly, broadcasting from it would knowingly miss the target.
What we observed instead:
- Fresh live reads before the decision matched the `GOOD` clean reset family exactly:
  - `block=11,128,721`
  - `balance=10 ETH`
  - `nonce=0`
  - `fUSDT=110,053,909,831,173`
  - `fDAI=10,957,885,131,355,578,675,877,776`
- We forced a fresh local anvil fork from that exact live head and replayed the archived stronger shape with:
  - `HARVEST_REQUIRE_GOOD_RESET=1`
  - `HARVEST_STAGE{3,4,5}_TX_REPEAT_CHOICES=1`
  - `HARVEST_STAGE5_EXISTING_FOLLOWUP_REPEATS=30`
  - `HARVEST_STAGE5_FRESH_FOLLOWUP_REPEATS=15`
  - `HARVEST_STAGE5_EXISTING_TX_REPEAT_CHOICES=1`
  - `HARVEST_STAGE5_FRESH_TX_REPEAT_CHOICES=1`
- The exact local replay log `runs/exploit_1776574575_localgoodnocompress.log` settled at:
  - `STAGE3_RETUNE_FUSDT_10M_10M_10M_DYNAMIC_FINAL_BALANCE=30,133.566697837897159952 ETH`
  - `STAGE4_DYDX_FUSDT_14M_10M_4P9M_14M_DYNAMIC_FINAL_BALANCE=32,395.431228903613953026 ETH`
  - `STAGE5_FDAI_5M_2P6M_2P4M_DYNAMIC_FINAL_BALANCE=39,880.287817468584554794 ETH`
  - `STAGE5_FDAI_5M_2P6M_2P4M_EXISTING_FOLLOWUP_ITER1_FINAL_BALANCE=40,023.423483285754457820 ETH`
  - `STAGE5_FDAI_5M_2P6M_2P4M_FRESH_FOLLOWUP_ITER1_FINAL_BALANCE=40,164.006698494247708177 ETH`
  - `FINAL_BALANCE=40,163.971012811816950412 ETH`
- The final exact gap to target is still `5,107.028987188183049588 ETH` before any live gas.
- Because the live endpoint currently exposes the same exact `GOOD` reset family we just bounded locally, this exploit task intentionally refused broadcast and wrote `runs/exploit_1776574575.log` instead of burning gas on a known sub-target branch.
Suggested next direction: do not broadcast from the currently exposed `GOOD` or `ALT` clean reset families. Brain needs either a materially stronger hidden reset/preserved family or a different Harvest vector entirely before another live ch2 exploit attempt.

## DEAD_END (attempt 67, exact live GOOD-family replay with the proposed stop-after-two fresh helper cap is still sub-target on April 19, 2026)
Hypothesis: the archived preserved-head `45,271 ETH+` finish might still be recoverable from today's exact live `GOOD` clean reset family if we force the current runner onto the single-transaction `stage3 -> stage4 -> stage5` path, limit both follow-up helpers to `execute(1)`, and stop immediately after the second fresh helper call.
Why it's wrong on April 19, 2026: an exact local anvil fork of the currently exposed live `GOOD` clean reset head still tops out at only `42,246.694481030471272789 ETH` under that capped branch. That is still `3,024.305518969528727211 ETH` below the requested `45,271 ETH` target before any live gas, so broadcasting from the same live head would knowingly miss.
What we observed instead:
- Fresh live reads before the decision again matched the exact `GOOD` clean reset family:
  - `block=11,128,721`
  - `balance=10 ETH`
  - `nonce=0`
  - `fUSDT=110,053,909,831,173`
  - `fDAI=10,957,885,131,355,578,675,877,776`
- We forced a fresh local anvil fork from that exact live head and ran `exploit/replay_peak_reset.py` with:
  - `HARVEST_REQUIRE_GOOD_RESET=1`
  - `HARVEST_TARGET_BALANCE_WEI=45271000000000000000000`
  - `HARVEST_STAGE{3,4,5}_TX_REPEAT_CHOICES=1`
  - `HARVEST_STAGE5_EXISTING_FOLLOWUP_REPEATS=17`
  - `HARVEST_STAGE5_EXISTING_TX_REPEAT_CHOICES=1`
  - `HARVEST_STAGE5_FRESH_FOLLOWUP_REPEATS=2`
  - `HARVEST_STAGE5_FRESH_TX_REPEAT_CHOICES=1`
- The exact local replay log `runs/exploit_1776575425_localverify2.log` settled at:
  - `STAGE3_RETUNE_FUSDT_10M_10M_10M_DYNAMIC_FINAL_BALANCE=29,995.097220814789769646 ETH`
  - `STAGE4_DYDX_FUSDT_14M_10M_4P9M_14M_DYNAMIC_FINAL_BALANCE=33,209.531073485842982200 ETH`
  - `STAGE5_FDAI_5M_2P6M_2P4M_DYNAMIC_FINAL_BALANCE=41,911.762229022983501559 ETH`
  - `STAGE5_FDAI_5M_2P6M_2P4M_EXISTING_FOLLOWUP_ITER1_FINAL_BALANCE=42,164.702055960489093758 ETH`
  - `STAGE5_FDAI_5M_2P6M_2P4M_FRESH_FOLLOWUP_ITER1_FINAL_BALANCE=42,246.694481030471272789 ETH`
  - `FINAL_BALANCE=42,246.694481030471272789 ETH`
- This result is materially stronger than Attempt66's older no-compression replay, but it still remains well below the requested target and therefore does not justify a live broadcast from the same exposed head.
Suggested next direction: stop retrying the currently exposed `GOOD` clean reset family. Brain needs either a materially different Harvest exploit vector or a stronger hidden reset/preserved family than anything currently exposed on this endpoint.

## DEAD_END (attempt 69, exact post-Attempt68 current-head fDAI continuation is still sub-target on April 19, 2026)
Hypothesis: after Attempt68's successful live replay to `41,636.782808134113666454 ETH`, the exact exposed current head might still clear the requested `45,271 ETH` target if we continue the surviving `fDAI` `5M / 2.6M / 2.4M` family with the live helper and chained fresh `CurrentFDAIDrain` deployments.
Why it's wrong on April 19, 2026: exact local forks of the current live head show that this continuation family is already exhausted well below target. Reusing the live helper tops out near `42,108.115482727651292308 ETH`, a fresh helper from the exact head tops out near `42,642.936786239001310269 ETH`, and even a second chained fresh-helper cycle only reaches `42,772.970695619331477435 ETH`. That still leaves the branch `2,498.029304380668522565 ETH` below the requested `45,271 ETH` target before any additional live gas.
What we observed instead:
- Fresh live reads before the decision matched the exact post-Attempt68 head:
  - `block=11,128,853`
  - `balance=41,636.782808134113666454 ETH`
  - `nonce=132`
  - `fUSDT=86,663,045,790,635`
  - `fDAI=6,173,715,112,302,595,367,754,015`
- Exact local fork of that head with the live stage5 helper `0xb4afa045d8c2b367eaeabca153e31d39c1e0cdec` is recorded in `runs/local_1776578441_existing_stage5_probe.log` and settles at:
  - `FINAL_BALANCE=42,108.115482727651292308 ETH`
  - `FINAL_DELTA=471.332674593537625854 ETH`
  - `TARGET_GAP=3,162.884517272348707692 ETH`
- Exact local fork of the same head with a fresh `CurrentFDAIDrain` deployment is recorded in `runs/local_1776578441_fresh_stage5_probe.log` and settles at:
  - `FINAL_BALANCE=42,642.936786239001310269 ETH`
  - `FINAL_DELTA=1,006.153978104887643815 ETH`
  - `TARGET_GAP=2,628.063213760998689731 ETH`
- Chaining a second fresh `CurrentFDAIDrain` on that same locally continued branch is recorded in `runs/local_1776578441_fresh_stage5_probe2.log` and settles at:
  - `FINAL_BALANCE=42,772.970695619331477435 ETH`
  - `FINAL_DELTA=130.033909380330167166 ETH` relative to the first fresh-helper branch
  - `TARGET_GAP=2,498.029304380668522565 ETH`
- The second fresh cycle already degrades to `execute(1)` only and then turns locally negative on its fifth call, so this branch is flattening rather than accelerating toward target.
- Because the live RPC still exposes the exact same current head we just bounded locally, another live stage5 continuation broadcast would knowingly miss the requested target.
Suggested next direction: stop broadcasting the post-Attempt68 current-head `fDAI` continuation family. Brain needs either a materially stronger hidden preserved/reset checkpoint or a different Harvest exploit vector before another live ch2 attempt.
