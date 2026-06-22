# economic_safety.skill.md

**Primary consumer**: Codex (every `exploit` / `tune` task that broadcasts a transaction) + Brain (reviewing before --broadcast is allowed).

This skill prevents **net-negative rounds** — broadcasting a transaction that burns more gas than it extracts. Mentor hint `§1.1 Reset is free` means losses are recoverable via reset, but **repeated net-negative rounds waste attempts without score progress** and can provoke a reset-cycle where another brain/task undoes the net-positive result of a parallel broadcast.

---

## §1 Mandatory pre-broadcast cost/benefit check

Before any `forge script --broadcast` or `cast send` that modifies state (not read-only `cast call`), compute and record:

| Quantity | How to compute |
|---|---|
| **Pre-broadcast balance** | `cast balance $PUBLIC_ADDRESS --rpc-url $RPC` — wei, exact |
| **Expected gain (optimistic)** | PoC's measured native delta from dry-run, OR vault's current `getCash()` / `balanceOf()` target |
| **Expected gas cost** | `cast estimate ...` or forge's `gasUsed` from the dry-run log, × current gas price |
| **Breakeven check** | Expected gain > Expected gas cost × 1.5 safety margin? |
| **Worst-case loss** | = Expected gas cost (if broadcast reverts) |

If **Expected gain ≤ Expected gas cost × 1.5**, do NOT broadcast. Instead:
- Document the unprofitable scenario in `analysis.md` Dead Ends
- Consider alternatives (batch into one tx, use different vault/victim, pivot hypothesis)
- Escalate to brain via `tools/notify.sh`

Write the pre-broadcast estimate to `challenges/<ch>/runs/exploit_<ts>_preflight.json`:
```json
{
  "ts": "2026-04-18T08:30:00Z",
  "pre_balance_wei": "171598098004012983172133",
  "expected_gain_wei": "5000000000000000000",
  "gas_estimate_wei": "200000000000000",
  "breakeven_safety": 24.5,
  "decision": "proceed"
}
```

---

## §2 Post-broadcast verification (mandatory within 30s)

Immediately after broadcast completes:

1. `cast balance $PUBLIC_ADDRESS --rpc-url $RPC` → actual_post_balance
2. Compute actual_delta = actual_post_balance - pre_balance_wei
3. If actual_delta < 0 (net loss): THIS IS A FAILURE even if tx status=1.
4. If actual_delta < expected_gain × 0.5: PARTIAL failure — investigate before next step.

Write `challenges/<ch>/runs/exploit_<ts>_postflight.json`:
```json
{
  "ts": "...",
  "tx_hash": "0x...",
  "tx_status": 1,
  "actual_delta_wei": "4800000000000000000",
  "expected_delta_wei": "5000000000000000000",
  "efficiency_pct": 96.0,
  "decision": "success"
}
```

Include this postflight in the archive.sh invocation — archive.sh reads it for the net-loss warning (§3).

---

## §3 Net-loss detection in archive.sh

When archive.sh is called with bucket=successful, it verifies:
- `actual_delta_wei > 0` OR `bucket == failed` (failed bucket is allowed to be negative — that's documentation)

If a `successful` archive has `actual_delta_wei ≤ 0`, archive.sh:
- Moves the file to `failed/` instead (misclassification correction)
- Emits `NET_LOSS_WARNING` in stdout
- Notifies via notify.sh --critical
- Brain responds per §4

---

## §4 Brain response to net-loss warning

When `NET_LOSS_WARNING` fires:

1. **Identify root cause**:
   - (a) Gas cost > gain → broadcast amount too small; batch or tune larger
   - (b) Tx reverted → PoC dry-run didn't catch a live-chain-only condition
   - (c) Concurrent reset by another brain → handoff §8 violation; kill duplicate task
   - (d) Vault depleted since PoC dry-run → recon stale; re-enumerate

2. **Do NOT retry same approach without hypothesis change**. If same net-loss 2× in a row on same challenge → §5 reset-cycle block.

3. **Document in analysis.md**:
   ```markdown
   ### NET_LOSS_EVENT (Attempt N, <ts>)
   - Pre-balance: X wei
   - Post-balance: Y wei (Δ -Z)
   - Root cause: <(a)/(b)/(c)/(d)>
   - Next action: <specific change>
   ```

---

## §5 Reset-cycle block

If two consecutive successful-but-net-negative rounds fire on the same challenge within 10 minutes:
- Create `challenges/<ch>/.reset_cycle_block` marker
- Block further exploit/tune tasks on that challenge for 30 minutes (delegate.sh checks this marker)
- Brain's required action: investigate whether two brains are fighting over the same vault state, and coordinate (or one brain stands down)

The marker is auto-cleaned by `tools/stuck_detector.sh` after 30 min OR manually by brain when the race condition is resolved.

---

## §6 Gas price awareness

On L1 forks (ch2, ch3) gas is expensive. On BSC (ch1) and Polygon (ch4, ch5) gas is cheap but still non-zero on full-vault-drain patterns.

Reference gas cost rules of thumb (adjust with `cast gas-price`):

| Chain | Typical wei per tx |
|---|---|
| ch1 BSC | ~5 × 10^15 wei per tx (0.005 BNB) |
| ch2 Ethereum | ~5 × 10^16 wei per tx (0.05 ETH) — HIGH |
| ch3 Ethereum | ~5 × 10^16 wei per tx (0.05 ETH) — HIGH |
| ch4 Polygon | ~1 × 10^14 wei per tx (0.0001 MATIC) |
| ch5 Polygon | ~1 × 10^14 wei per tx (0.0001 MATIC) |

For ch2 / ch3: a round with expected_gain < 0.1 ETH is a risky bet (50% of it goes to gas). Plan for ≥1 ETH per round or batch operations.

---

## §7 Duplicate-task detection (delegate.sh handshake)

Before spawning a Codex session for `exploit`/`tune`/`debug` on a challenge, `delegate.sh` checks:

```bash
EXISTING=$(pgrep -fc "delegate\\.sh $CH (exploit|tune|debug)")
if [ "$EXISTING" -gt 1 ]; then
    echo "REFUSE: another exploit/tune/debug task is already running on $CH (pids: $(pgrep -f \"delegate\\.sh $CH\"))"
    echo "handoff_protocol §8 forbids concurrent same-challenge tasks."
    echo "Either wait for the existing task or kill it explicitly before retrying."
    exit 1
fi
```

This is `handoff §8` enforcement. Can be bypassed by user with `FORCE_CONCURRENT=1 ./tools/delegate.sh ...` (with audit trail).

---

## §8 Anti-patterns

- ❌ Broadcasting without writing the preflight JSON first
- ❌ Treating `tx status=1` as success — always check balance delta
- ❌ Retrying a net-loss attempt without changing the hypothesis
- ❌ Spawning a second `exploit` task on the same challenge because "the first one seems stuck" — kill the first, don't race it
- ❌ Ignoring `NET_LOSS_WARNING` because "the other brain will fix it"

---

## §9 Cross-references

- `skills/deep_analysis.skill.md` §5 — "no parameter spam" rule (related: don't retry net-loss without hypothesis change)
- `orchestrator/handoff_protocol.md` §8 — no concurrent same-challenge tasks
- `tools/archive.sh` — implements §3 net-loss detection
- `tools/delegate.sh` — implements §7 duplicate-task refusal
- `tools/stuck_detector.sh` — cleans up reset_cycle_block markers
- `knowledge/mentor_hints.md` §1.1 — reset is free (but repeated loss is wasteful)
