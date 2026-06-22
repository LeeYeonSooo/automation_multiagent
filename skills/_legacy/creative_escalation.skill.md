# creative_escalation.skill.md

Primary consumer: **Claude Code (brain)**. Triggered automatically when:
- 60 minutes pass with no score change on a challenge (see `CLAUDE.md` §6, `tools/poll_scoreboard.py`)
- Codex reports the same revert 3 times in a row
- `status.json.needs_human = true` on any challenge
- Brain self-recognizes stagnation (same hypothesis appearing twice in `dead_ends`)

The 8 steps are **mandatory** when triggered. Do not skip. "I already tried all these" is a refusal — the structure forces new angles, not new effort on old ones.

Each step: **Trigger condition** (when it applies) → **Concrete action** (exact commands and files) → **Expected output** (what you produce) → **Exit** (move to step N+1 or back to delegation).

---

## Step 1 — Constraint Reframing

**Trigger**: always the first step. Re-anchor on the math.

**Action**:
1. `./tools/score.sh` — current points per challenge, total.
2. Read `knowledge/scoring_model.md` — recall the `log1p × minmax × max_pts` shape.
3. Compute: to climb one rank on this challenge, what native-balance delta do you need vs current?
   - If you don't know competitor deltas, estimate from the rank order: if you're 5th of N with `x` wei, and 4th has `y` wei visible from the board, the delta to overtake is `y - x` (plus a margin).
4. Compute: is that delta achievable given the fork's total liquidity?
   - Pull `challenges/<ch>/recon/contracts.json`, then `cast call $VAULT 'totalAssets()(uint256)'` (or equivalent).
   - Also check the largest flash-loan provider's liquidity (see `skills/flash_loan.skill.md`).
5. If delta > available liquidity: step 1 ends with "abandon this challenge" — issue `report_draft` with status `abandoned`, move resources to other challenges.
6. Otherwise: the problem is **not** resource-bound; it's a strategy bug. Proceed to step 2.

**Expected output**: a written note in `challenges/<ch>/analysis.md` under `## Constraint reframing (stuck check)`:
```
Current delta: 0.3 ETH.
Next rank delta: +0.4 ETH.
Available liquidity (yUSD vault): ~5 ETH equivalent.
Not resource-bound. Proceed to §2.
```

**Exit**: step 2 if not abandoned.

---

## Step 2 — Cross-Challenge Synthesis

**Trigger**: constraint allows more profit but you're not finding the path.

**Action**:
1. Read **all five** `challenges/*/analysis.md` in one pass. Literal paths:
   - `challenges/ch1_uranium/analysis.md`
   - `challenges/ch2_harvest/analysis.md`
   - `challenges/ch3_feirari/analysis.md`
   - `challenges/ch4_superfluid/analysis.md`
   - `challenges/ch5_superfluid_v2/analysis.md`
2. Tag each hypothesis with its vuln category from `knowledge/vuln_db.md` §VI (Oracle manip / Reentrancy / Ctx forgery / AMM invariant / etc.).
3. Look for patterns that repeat across challenges:
   - Is the same primitive (e.g., `balanceOf(this)` accounting) used in two places with different wrappers?
   - ch4 and ch5 both have Superfluid ctx — does v2's "non-msgSender field" insight retrofit to v1 for a bigger v1 profit?
   - Does a flash-loan pattern from ch2 help ch3 (both Ethereum)?
4. If yes: port the technique. The most common win is ch5 insight → better ch4 exploit (per CLAUDE.md §4 note "v2 인사이트로 v1 점수도 재상승 가능").

**Expected output**: in the stuck challenge's `analysis.md`, add:
```
## Cross-challenge port
Pattern: <name>. Already applied in <other ch>. Adapting here by: ...
```

**Exit**: if a port is identified, go straight to step 3 to pick the actual new hypothesis. If no port: step 3 anyway.

---

## Step 3 — Multi-Hypothesis Branching

**Trigger**: you've been on one hypothesis and it's not working. This step *forces* alternatives.

**Action**:
1. Write the current hypothesis at the top of a scratch: `[H0] <current>`.
2. Generate **exactly 3** alternative hypotheses `[H1] [H2] [H3]`. Requirements:
   - Each must use a **different primitive** from H0. If H0 is "reentrancy via callback token", H1 can't be "reentrancy via a different callback token" — too close. H1 should be "oracle manip via the same entry point".
   - Pull primitives from `knowledge/vuln_db.md` §VII signatures for help.
3. For each, estimate:
   - `P_success` ∈ {0.1, 0.3, 0.5, 0.7} (coarse; be honest)
   - `payoff_wei` (rough wei estimate of balance delta if it works)
4. Rank by `P_success × log1p(payoff_wei)` (scoring model weighting).
5. Pick the top 1. That's the new hypothesis.

**Expected output**: update `analysis.md`:
```
## Multi-hypothesis branching (stuck, step 3)
H0 (failed): <text> — moved to Dead ends
H1: <text>  | P=0.3 | payoff=0.5e18 | score = 0.3 × log1p(0.5e18) ≈ 12.3
H2: <text>  | P=0.5 | payoff=0.1e18 | score = 0.5 × log1p(0.1e18) ≈ 19.5
H3: <text>  | P=0.2 | payoff=2e18   | score = 0.2 × log1p(2e18)   ≈ 8.8
Selected: H2 (highest expected log-score).
```

**Exit**: update `analysis.md` Hypothesis section to H2. Delegate fresh `poc` task. Monitor. If H2 also fails, continue to step 4 (don't loop back to step 3 immediately — step 4 offers a genuinely different angle).

---

## Step 4 — Combine Attack Vectors

**Trigger**: several single-vector hypotheses failed. The win might be a chain of two bugs.

**Action**:
1. List every A-category finding in `knowledge/case_<protocol>.md` or observed during recon. Some may have been classified as "not exploitable alone" — revisit.
2. For each pair (A_i, A_j), ask: does A_i enable A_j, or vice versa?
   - Example: oracle manip (A_i) doesn't drain much alone due to 3% guard; but if combined with a reentrancy on the guard-check function (A_j), the guard can be skipped → full drain. Together, much bigger.
   - Example: ctx forgery (A_i) sets `appAddress` to a contract that, via a callback (A_j), re-enters the host's sub-operation.
3. Score the top 3 combinations by plausibility.
4. Write the chain as a numbered sequence in `analysis.md` under `## Combined vector`.

**Expected output**: concrete attack chain. Each step must name a function call and the expected state change.

**Exit**: new `poc` task with the chain. If still fails: step 5.

---

## Step 5 — Victim Enumeration Deepening

**Trigger**: applies mostly to ch4/ch5 (Superfluid). Your profit is bounded by a specific victim's balance.

**Action**:
1. Read `challenges/<ch>/recon/victims.json`. You're probably targeting top-1.
2. Re-run enumeration with:
   - Wider block range (go back to token deployment block — Genesis whales rarely appear in recent Transfer events).
   - Include `Minted` / `Upgraded` events, not just `Transfer`.
   - Include underlying token holders who could have upgraded but didn't — they may hold SuperToken via a different path (e.g., wrapped via a third-party aggregator).
3. Update `victims.json` to top 100.
4. Consider hitting multiple victims per tx (loop over top 10) — attacker EOA accumulates all deltas.

**Expected output**: enriched `victims.json`; refined `analysis.md` attack chain with multi-victim loop.

**Exit**: new `exploit` task (not `poc` — by this point the technique works, you're scaling). If still bounded: step 6.

---

## Step 6 — Iteration Curve Re-fit

**Trigger**: applies mostly to ch2 (Harvest) and any iterative oracle-manip attack.

**Action**:
1. Read `challenges/<ch>/runs/` for attempts at different iteration counts (N=1, 10, 100, etc.).
2. Plot (or tabulate) `delta_wei vs N` — you should see a bell curve. Profit rises with N up to a point, then falls as cumulative fees swamp extraction.
3. The optimum is where `d(profit)/dN = 0`. Interpolate from observed points. If only 2-3 data points, instruct Codex via `tune` task to fill in between.
4. Also: re-check `gas_per_iteration × iterations` vs block gas limit. You may be leaving points on the table because you capped N too low.

**Expected output**: a table in `analysis.md`:
```
N=1:   delta = 0.01 ETH, gas = 500k
N=10:  delta = 0.15 ETH, gas = 5M
N=17:  delta = 0.23 ETH, gas = 8.5M  ← current max
N=25:  delta = 0.19 ETH, gas = 12.5M (declining)
Optimum ~ N=17. Already there.
```

If you're already at the optimum: step 7.

**Exit**: `tune` task to apply optimum. If already optimal: step 7.

---

## Step 7 — Asset Path Optimization

**Trigger**: PoC/exploit shows big ERC20 profit but native delta is much smaller. 10-30% loss in conversion is the usual culprit.

**Action**:
1. Read the last exploit's log. Compare ERC20 profit (mid-tx) to native delta (end).
2. Ratio < 95%: slippage is the problem. Actions:
   - Split the swap across multiple hops: `[X, USDC, WNATIVE]` instead of `[X, WNATIVE]` if X-WNATIVE pool is thin.
   - Use a different DEX (Uniswap V3 0.05% tier for stables; QuickSwap vs SushiSwap on Polygon).
   - Split across N txs if a single swap moves price > 2%.
3. Ratio 95-99%: optimize `amountOutMin` (set it high enough that you can see whether slippage is hitting, but not so high that it reverts).
4. Ratio > 99%: skip this step, the problem is elsewhere.

**Expected output**: modified `Run.s.sol` conversion block; updated `skills/native_conversion.skill.md` reference in `analysis.md`.

**Exit**: `tune` task with "optimize conversion slippage, expected +X% delta". If still flat: step 8.

---

## Step 8 — Read the Source Twice

**Trigger**: the mentor's "insight" step. Last resort before asking a human.

**Action**:
1. Open the core contract you're attacking in `challenges/<ch>/recon/src/<addr>.sol`.
2. Read it line by line, asking at each non-trivial line: **what assumption am I making here?**
   - "msg.sender is the user" → is it? Could be a proxy, multicall, flashbot bundle.
   - "ctx is validated" → is it? Look at every callsite, not just the one you're focusing on. (This is exactly the ch5 pattern — v2 added validation to most entry points but missed `claim`.)
   - "this function is reentrancy-guarded" → is the guard shared? per-function? applied on the callback target too?
   - "the oracle is safe" → is the actual price-fetching function what you think? Check for wrapper functions that tamper.
   - "`balanceOf(this)` reflects the pool" → could an attacker donate/transfer to inflate it outside of expected deposit paths?
3. Specifically, re-read the **patch diff** if the challenge is a patched version (ch5). The patch is what the devs thought was dangerous; the bug is what they missed. Look at every function the patch modifies — and every function that parallels those but wasn't modified.
4. Write the new observation as `BONUS` or new `H` in `analysis.md`.

**Expected output**: one specific line of source that reveals a new angle. Cite it by path + line number.

**Exit**: if found, back to step 3 (hypothesis branching with the new finding included). If step 8 genuinely yields nothing, notify the human per `CLAUDE.md` §12.

---

## Meta: running the escalation

Run the whole 8 steps in order. Don't jump around. Each step produces written artifacts — the trace is intentional so that (a) the brain sees its own reasoning in `analysis.md` on the next session, (b) the report's "Failed Attempts" section auto-populates.

Timing:
- Steps 1-3: 15-30 minutes of brain time combined. Mostly reading + one delegation.
- Steps 4-6: 30-60 minutes each including Codex turnarounds.
- Step 7: 15 minutes, usually.
- Step 8: 30-60 minutes of careful reading. Don't rush.

Total: ~3 hours max per full escalation cycle. If you've done a full cycle without a breakthrough, notify the user (`tools/notify.sh`) and pick a different challenge to keep progressing.

---

## Anti-patterns (what not to do during escalation)

- **Ignore the structure**: "I'll think about it" is not step 3. Write the 3 branches with numbers.
- **Skip writing to analysis.md**: the written artifacts exist so you don't re-derive them next session.
- **Keep the current hypothesis after steps fail**: if step 3 says H2 has higher expected log-score than H0, *switch*.
- **Delegate before finishing a step**: each step is decided in-brain, then delegated. Don't send Codex to "help brainstorm" — that's what this file is for.
- **Treat "mentor said it's possible" as proof**: mentor says the vuln is exploitable, not that your current approach works. Keep branching.
