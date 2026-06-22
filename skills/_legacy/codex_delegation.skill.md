# codex_delegation.skill.md

Primary consumer: **Claude Code (brain)**. This is the skill that teaches the brain how to hand work to Codex (executor) properly. Codex does NOT need to read this file — it already follows AGENTS.md.

If you're Claude Code and you're about to type `forge test` or `cast call` or invent Solidity in your own reply: stop, reread `CLAUDE.md` §2-3, and use `tools/delegate.sh` instead.

---

## 1. The one command you'll ever use

```bash
./tools/delegate.sh <challenge> <task_type> "<one-line goal>" [--background]
```

That's it. Never `codex exec` directly. Never hand-roll a prompt. The wrapper:
1. Loads `.env` so RPCs and PRIVATE_KEY are available.
2. Validates `<challenge>` is one of the five known IDs.
3. Determines which CONTEXT files are relevant based on `<task_type>` (and protocol, and whether it's a Superfluid challenge).
4. Computes the next attempt number for PoCs so you never overwrite.
5. Builds a structured prompt with `[TASK_TYPE]`, `[CHALLENGE]`, `[GOAL]`, `[REQUIRED_READING]`, `[DELIVERABLES]`, `[CONSTRAINTS]`, `[SUCCESS_CRITERION]`, `[OUTPUT_FORMAT]`.
6. Logs prompt + output to `logs/delegate_<timestamp>_<ch>_<tt>.log`.
7. Picks a Codex model (`CODEX_DEEP_MODEL` for poc/debug/exploit/tune; `CODEX_FAST_MODEL` for recon/victims/report).
8. Runs synchronously (default) or background (`--background`).

---

## 2. Task types — what each means and when to use

| task_type | Codex does | Use when |
|---|---|---|
| `recon` | Enumerates contracts, fetches ABIs/sources, writes `chain_info.json` + `contracts.json` | Day one of a challenge, or after a protocol-wide reset |
| `poc` | Writes `AttemptN.t.sol`, runs `forge test`, captures log | You have a hypothesis in `analysis.md` ready to test |
| `debug` | Reads last failed log + PoC, either fixes (+1 attempt) or writes DEAD_END | PoC failed and you want root-cause diagnosis before new hypothesis |
| `exploit` | Writes `Run.s.sol`, dry-runs, requests confirm, broadcasts | PoC passed and you want real native-balance delta |
| `tune` | Modifies existing `Run.s.sol` to maximize delta (iteration N, swap sizes) | Exploit works but delta is suboptimal |
| `enumerate_victims` | Scans Transfer events, sorts holders, writes `victims.json` | ch4/ch5 only, before serious exploit attempts |
| `report_draft` | Drafts `report.md` per `templates/report.md.template` | Challenge is `exploited` or `abandoned`, or ≤12h from deadline |

Wrong task_type is a common failure. "The exploit is working but I want a bit more profit" is `tune`, not `exploit`. "The PoC reverts" is `debug`, not another `poc`.

---

## 3. Writing a good `<one-line goal>` string

The goal becomes `[GOAL]` in the Codex prompt. Codex uses it to decide what to actually do when `analysis.md` has multiple hypotheses or the deliverables allow multiple paths.

**Bad**:
- `"try an attack"` — no target, no method
- `"fix the PoC"` — which PoC? what fix?
- `"make more money"` — no direction
- `"reentrancy stuff"` — handwavy

**Good**:
- `"K-invariant swap exploit on pair 0xAbc targeting amount0Out = 99% of reserve0, expect ~3 WBNB profit"`
- `"Fix Attempt3 revert in uniswapV2Call callback — trace shows InsufficientOutput at line 87; suspect wrong amountIn calc"`
- `"Increase Harvest iteration count from 10 to 17, record delta vs gas at each step, pick optimum"`
- `"Forge ctx with appCreditGranted = 2^200, call claim() via host, target victim = 0xDef (from victims.json top-1)"`

Rules of thumb:
- **Imperative verb first**: exploit, fix, increase, forge, swap, etc.
- **Target addresses or selectors when known**: Codex won't re-derive what you already know.
- **Expected magnitude** when measurable: "~3 WBNB", "delta > 0.5 ETH". Sets a sanity bar.
- **≤ 200 chars**. If you can't fit it, your hypothesis is too broad — split into two tasks.

---

## 4. CONTEXT file selection pattern

`delegate.sh` already picks CONTEXT for each task_type — you don't manually specify. But you should know what gets injected so you can pre-stage `analysis.md` with the right detail.

Invariants (always injected):
- `AGENTS.md`
- `challenges/<ch>/analysis.md` — **you** are responsible for keeping this current
- `knowledge/case_<protocol>.md`

Task-specific additions:
- `recon`: `skills/recon.skill.md`, `skills/foundry_fork.skill.md`
- `poc`: `skills/exploit_<protocol>.skill.md`, `templates/<protocol>.t.sol.template`, `skills/foundry_fork.skill.md`
  - ch4/ch5 also: `reference/IDAUsage_t.sol`, `reference/ContextUtils.sol`, `knowledge/superfluid_ctx_struct.md`
- `debug`: last log in `runs/`, `skills/foundry_fork.skill.md` (for the revert selector table)
- `exploit`: `poc/` (all attempts), `skills/exploit_<protocol>.skill.md`, `skills/native_conversion.skill.md`
- `tune`: `exploit/Run.s.sol`, latest `runs/`
- `enumerate_victims`: `recon/contracts.json`, `skills/recon.skill.md`
- `report_draft`: `runs/`, `poc/`, `exploit/`, `templates/report.md.template`, `skills/report_writing.skill.md`

Your job: **before** delegating a `poc` task, make sure `analysis.md` has:
1. **Hypothesis** (one line — Codex uses this as its objective)
2. **Target contracts** (table of role → address)
3. **Attack chain** (numbered steps)
4. **References** (which skill/knowledge sections contain the details)
5. **Success criterion** (what delta counts as a pass)

Without these, Codex makes educated guesses. With these, it follows your plan.

---

## 5. When to use `--background`

**DO** background:
- Parallel recon across the 5 challenges at session start:
  ```bash
  for ch in ch1_uranium ch2_harvest ch3_feirari ch4_superfluid ch5_superfluid_v2; do
    ./tools/delegate.sh $ch recon "initial contract enumeration" --background
  done
  wait
  ```
- Victim enumeration for ch4 and ch5 simultaneously
- Long-running gradient tuning where you want to do something else meanwhile

**DON'T** background:
- Exploit tasks — they produce real native-balance changes and should be synchronous with a human in the loop (or at least synchronous with the brain watching)
- Debug tasks — you want the answer to drive the next move right away
- Any task where you don't have something useful to do during the wait

Backgrounded tasks write their PID to `logs/bg_<ch>_<tt>.pid` and their log to `logs/delegate_<timestamp>_<ch>_<tt>.log`. Check status with:

```bash
# Is it still running?
ps -p $(cat logs/bg_ch1_uranium_recon.pid)

# What has it said?
tail -f logs/delegate_*_ch1_uranium_recon.log

# Did it finish successfully? Look for the 3-line summary at the end:
grep -E "^(STATUS|DELTA|NEXT):" logs/delegate_*_ch1_uranium_recon.log
```

Also check `challenges/<ch>/status.json` — Codex updates it on completion regardless of fg/bg.

---

## 6. Reading Codex's response

Every Codex run ends with the required 3-line summary (AGENTS.md §13):

```
STATUS: <state>
DELTA: <native balance delta in wei or N/A>
NEXT: <suggested next action>
```

Your reading loop:

1. Read those 3 lines first. They're the executive summary.
2. Read `challenges/<ch>/status.json` — the authoritative state.
3. If STATUS is `exploited`: run `./tools/score.sh` to see score change.
4. If STATUS is `stuck`: read `challenges/<ch>/analysis.md` "Dead ends" section; engage `skills/creative_escalation.skill.md`.
5. If STATUS is `poc` with a failed attempt: read the latest `runs/attemptN.log`, pick up on the specific error, issue a `debug` task.
6. If STATUS is `debug` result was DEAD_END: you need a new hypothesis. Update `analysis.md` with a new Hypothesis (removing the old one to Dead ends). Issue a fresh `poc` task.

---

## 7. Pass/fail handling patterns

### PoC fails with a specific revert
Don't re-issue `poc`. Issue `debug`:
```bash
./tools/delegate.sh ch2_harvest debug "Attempt3 reverted with INSUFFICIENT_LIQUIDITY at Curve pool; suspect wrong token index"
```
The GOAL string mentions the specific revert — Codex reads the log, confirms, fixes.

### PoC fails with "hypothesis is wrong"
Codex writes DEAD_END to `analysis.md`. Your move:
1. Read the DEAD_END note.
2. Update `analysis.md` Hypothesis to the next candidate (push old to Dead ends).
3. Issue fresh `poc`.

Never re-run the same hypothesis. If you're tempted, you're not reading the DEAD_END note carefully enough.

### Exploit succeeds but delta is lower than PoC predicted
Issue `tune`:
```bash
./tools/delegate.sh ch2_harvest tune "iteration count ran at N=10; PoC showed N=17 optimal; re-run with gradient observation between 10 and 25"
```

### Exploit fails broadcast but dry-run passed
This is always one of: gas estimation off, nonce, stale fork state. Issue `debug` with:
```bash
./tools/delegate.sh ch2_harvest debug "Run.s.sol dry-run passed but --broadcast reverted; capture actual trace, check for block number drift or stale cache"
```

---

## 8. Things to avoid (common brain mistakes)

1. **Writing Solidity in your reply.** If you catch yourself typing `function`, `vm.prank`, or `pragma` in your own message, stop and delegate.
2. **Running `forge test` via Bash.** CLAUDE.md §2 forbids this. All Foundry calls go through Codex.
3. **Re-issuing the same task.** If delegate failed, read the log first. Reissuing without changing GOAL burns tokens.
4. **Giving Codex TODO lists.** One task = one objective. Multi-step handoffs should be multiple delegations, not one mega-task.
5. **Forgetting to update `analysis.md`.** Codex reads it as the authoritative hypothesis. Stale analysis.md = Codex works on last week's plan.
6. **Parallel delegations on the same challenge.** `handoff_protocol.md` §8: same-challenge concurrency causes `status.json` races. Different challenges: fine.
7. **Ignoring the `dead_ends` array in status.json.** If `dead_ends` contains your current hypothesis, you already tried and failed. Pick another.
8. **Asking for a report too early.** `report_draft` is for `exploited` / `abandoned` or imminent deadline. Drafting mid-PoC wastes Codex cycles on incomplete data.

---

## 9. Flow diagram

```
brain: read PROGRESS.md + status.json + score.sh
   │
   ▼
brain: update challenges/<ch>/analysis.md (Hypothesis + Attack chain)
   │
   ▼
brain: ./tools/delegate.sh <ch> poc "<specific goal>"
   │
   ▼ (codex session — ephemeral)
codex: reads CONTEXT → writes AttemptN.t.sol → runs forge → updates status.json
   │
   ▼
brain: reads STATUS/DELTA/NEXT + status.json + latest run log
   │
   ├── passed ──► ./tools/delegate.sh <ch> exploit "<goal>"
   ├── failed  ──► ./tools/delegate.sh <ch> debug "<specific revert>"
   └── stuck   ──► skills/creative_escalation.skill.md
```

Keep the loop tight. Each iteration = 1 delegation + 1 decision. Don't batch.
