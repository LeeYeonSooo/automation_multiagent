# reset_rpc.skill.md

Primary consumer: Both Brain and Codex. Read when a challenge fork has accumulated unwanted state (failed attempts, stale storage) and you need to rewind to the initial snapshot.

---

## 1. What Reset does

Each of the 5 challenge RPCs is a dedicated Anvil-style mainnet fork, isolated per student. The course provides a Reset endpoint that wipes ephemeral state and returns the fork to its original block (same chain state as fork-initial).

**Critical consequence**: Reset **wipes your native balance delta**. Whatever score you earned on that challenge goes back to zero. Only Reset when you are going to immediately re-exploit (or have already captured the score externally via `cast balance` snapshot).

---

## 2. How to invoke

```bash
./tools/reset.sh ch1            # one challenge
./tools/reset.sh all            # all 5 (prompts for confirmation)
```

`tools/reset.sh` attempts three patterns in sequence until one succeeds:
1. POST to RPC URL with `{"jsonrpc":"2.0","method":"anvil_reset","params":[]}`
2. POST to URL with `/rpc/` → `/reset/` substitution (matches the assignment announcement's parallel URL structure)
3. Falls back to human-triggered reset via scoreboard UI

---

## 3. Decision policy — when to Reset

| Situation | Reset? | Why |
|---|---|---|
| PoC `forge test` reverts — did NOT broadcast | NO | Fork unchanged; no state pollution |
| Broadcast attempt reverted mid-tx | **YES** | Aave/Balancer flashloans that reverted can leave dust; victim SuperTokens may have partial approvals |
| Broadcast succeeded, balance increased, but suboptimal | **CASE-BY-CASE** | If you think you can extract more without Reset: try tuning. If the index/market/pool was materially consumed: Reset and re-exploit with better params |
| Hypothesis proven wrong | NO | Reset doesn't help — rewrite hypothesis first |
| Running out of victims (Superfluid) after drain | NO | Victims re-appear only at fork-initial; Reset erases your score too |
| Lost track of intermediate storage state | **YES** | Clean slate eliminates uncertainty |
| Want to try a fundamentally different approach | **YES** | Previous attempts' storage/allowance residue could block the new path |

**Rule of thumb**: Reset is cheap (one HTTP call), but the score erase is not. Always `cast balance` first, note the wei value, then decide.

---

## 4. Reset + re-exploit pattern (for tuning loops)

When binary-searching iteration count (Harvest) or swap size (any oracle-manip challenge):

```bash
# 1. Record pre-iteration baseline
BASELINE=$(cast balance $PUBLIC_ADDRESS --rpc-url $RPC_CH2_HARVEST)

# 2. Try N=10
forge script ... --broadcast --rpc-url ch2
BAL_10=$(cast balance $PUBLIC_ADDRESS --rpc-url $RPC_CH2_HARVEST)

# 3. Reset
./tools/reset.sh ch2

# 4. Try N=50
forge script ... --broadcast --rpc-url ch2
BAL_50=$(cast balance $PUBLIC_ADDRESS --rpc-url $RPC_CH2_HARVEST)

# 5. Reset
./tools/reset.sh ch2

# 6. Try N=30 (bisect)
# ...

# 7. Final: Reset once more, run with best N, do NOT Reset after
./tools/reset.sh ch2
forge script ... --broadcast
# this final balance stays; it's the scored state
```

Never leave the fork in a Reset'd state at end of session — the final "kept" exploit must be the last broadcast.

---

## 5. Multi-challenge Reset caveats

`./tools/reset.sh all` resets all 5. Use only when:
- You've just completed a major harness change and want a clean E2E verification from scratch
- All 5 challenges were in broken intermediate state (rare)
- Pre-final-submission cleanup — BUT this erases all scores; use only if you plan to immediately re-broadcast all 5 final scripts

The script prompts `yes` confirmation because this is destructive across the board.

---

## 6. What Reset does NOT do

- Does NOT reset your `PUBLIC_ADDRESS` EOA nonce counters client-side — nothing to reset there
- Does NOT invalidate Foundry's `.forge-cache/` — you may need `forge clean` separately
- Does NOT re-fund victim addresses on Superfluid challenges beyond the fork-initial amount
- Does NOT reset PROGRESS.md / status.json / the archive logs — those are your working history and must be preserved

After Reset, `status.json` for the challenge should be set by Brain back to `"state": "recon_done"` (or further back if redoing recon). Poller will pick up the balance reset at the next 300s poll and update `balance_delta_wei = 0`.

---

## 7. Status.json update after Reset

Brain updates the challenge's status.json minimally:
```json
{
  "state": "poc",
  "balance_delta_wei": "0",
  "score_estimate": 0,
  "last_update": "<NOW UTC>",
  "notes": "reset at <timestamp> before tuning run with N=30"
}
```

The `notes` field is append-only in spirit — preserve prior notes where possible (document the history).
