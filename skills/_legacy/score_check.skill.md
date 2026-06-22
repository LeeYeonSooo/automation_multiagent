# score_check.skill.md

Primary consumer: Both Brain and Codex. Read whenever you need to decide "have I scored on this challenge yet?" or "is more tuning worth it?".

This file is a thin policy wrapper over the mechanic tools `tools/balance.sh` and `tools/poll_scoreboard.py`.

---

## 1. The scoring model (canonical)

```
score(chN) = minmax_scale(log1p(native_balance_delta), 0.01, 1) × max_pts[chN]
```

- `native_balance_delta` = `cast balance $PUBLIC_ADDRESS --rpc-url $RPC_CH<N>` after your broadcast minus the fork-baseline balance.
- `log1p` → diminishing returns; doubling wei at the top of the curve barely moves the score.
- `minmax_scale(x, 0.01, 1)` — **relative** across all students. 1st place → 1.0, last → 0.01, linear in log-space between.
- `max_pts`: ch1/2/3 = 10,000; ch4 = 15,000; ch5 = 25,000. Total = 70,000.

**Assignment-level mandate** (AGENTS.md §0, CLAUDE.md §4.5): drain the vault entirely regardless of log1p saturation. Relative ranking is the real scoring axis — another team that drains 100% while you stop at "log1p flat" will outrank you. The ONLY valid stop condition is: every enumerated target has been drained to ~0 OR a specific target has a documented DEAD_END.

Stop iterations ONLY when: (a) marginal_profit_per_iter ≤ gas_cost_per_iter AND further iters revert (vault empty), OR (b) an uncovered target exists and should be pursued instead.

---

## 2. How to check

### 2.1 Point-in-time (one shot)
```bash
./tools/balance.sh ch1          # one challenge
./tools/balance.sh all          # all 5
./tools/score.sh                # score-table view (parsed from status.json)
```

Direct cast for Codex inside a Foundry script:
```solidity
uint256 finalNative = $PUBLIC_ADDRESS.balance;
console.log("FINAL_NATIVE_WEI:", finalNative);
```
Brain reads this value out of `runs/exploit_<ts>.log`.

### 2.2 Continuous monitoring
`tools/poll_scoreboard.py` runs in background, polls every `SCORE_POLL_INTERVAL` seconds (default 300s), and:
- Updates each `challenges/<ch>/status.json` `balance_delta_wei` + `score_estimate`
- Notifies (Discord + macOS) on balance change
- Marks `needs_human: true` in status.json after `STUCK_THRESHOLD_MIN` minutes of no change (default 60)

Brain starts it once per session:
```bash
nohup python3 tools/poll_scoreboard.py > logs/scoreboard.log 2>&1 &
```

---

## 3. Decision policy — "score check" triggers

| Observation | Required action |
|---|---|
| After any broadcast in §3.4 of AGENTS.md | `cast balance` before and after; assertGt in script; ALSO run `./tools/balance.sh chN` externally to cross-check |
| Brain planning next delegate call | `./tools/score.sh` first; pick challenge with lowest `score_est × dev_hours` |
| Codex tuning iteration N | Run `forge test` with 3 values (N, 2N, 5N); pick inflection point where delta/N derivative flattens |
| 60-min no-change stuck signal from poller | Brain invokes `skills/creative_escalation.skill.md` |
| After Reset (tools/reset.sh) | `balance.sh` should show fork-initial value; if not, the reset endpoint did not work — investigate, don't retry blindly |

---

## 4. Common anti-patterns

- **Checking ERC20 balance instead of native**: the score is native only. `attacker.balance` (EOA) is what matters. Running `USDC.balanceOf(attacker)` tells you nothing about score.
- **Checking balance from inside a contract address**: the student EOA is `$PUBLIC_ADDRESS = 0xc943...e910b14`, not your attacker contract. Always transfer final native to the EOA at the end of your script.
- **Forgetting to unwrap WETH/WMATIC/WBNB**: WETH.balanceOf counts as ERC20, not native. You must `withdraw(balance)` to unwrap. See `skills/native_conversion.skill.md`.
- **Under-draining due to log1p**: stopping because "the score is nearly flat" is WRONG for this assignment. Relative ranking punishes partial drain — the team that drains 100% wins the minmax factor 1.0. Drain to ~0, then stop. See AGENTS.md §0 mandate.

---

## 5. Score-to-dollar intuition (rough)

Because the exact distribution of other teams' deltas is unknown, the minmax factor is uncertain. Rough mental model:
- You held no native before the exploit → delta == final balance.
- If you beat every other team's delta: minmax factor = 1.0 → full `max_pts`.
- If you tie the median: minmax factor ≈ 0.5 → half `max_pts` — because log1p of similar deltas compresses.
- If you barely score (dust): factor → 0.01 → 1% of `max_pts`, effectively nothing.

Thus: **the marginal gain from being #1 vs #2 is small in log1p space**, but the marginal gain from "scored anything at all" vs "0" is huge. Always prioritize getting SOMETHING on the scoreboard before tuning.

---

## 6. When the scoreboard URL matters

The external scoreboard at `https://upside.chainlight.io/` is the authoritative comparator (what the minmax normalizes against). It requires a wallet signature to view; the harness does not automate this — the human checks occasionally.

Brain does NOT need the external scoreboard to decide task priority. Internal `status.json.score_estimate` is sufficient; the absolute minmax factor is a common multiplier across all challenges at the end.
