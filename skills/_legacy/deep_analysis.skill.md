# deep_analysis.skill.md

**Primary consumer**: Codex (every `poc`, `debug`, `exploit`, `tune` task).
**Secondary consumer**: Brain (when manually drafting an `analysis.md` hypothesis section).

This skill is the **mandatory pre-flight** for every code-writing task. Skipping it produces shallow attempts that burn the attempt budget without learning. The cost of following it is ~5-10 minutes of reading per task; the cost of skipping it is documented in 14+ wasted ch5 attempts.

> Mentor frame: "creativity required for ch5; surface-level retry doesn't work" — `knowledge/mentor_hints.md`. The protocol below is creativity-as-procedure: force a hypothesis tree before any solidity is written.

---

## §1 Mandatory pre-PoC reading (in this exact order)

Read all of these BEFORE writing any `.t.sol`/`.s.sol` line. If a file is missing, note it in `analysis.md` "Open Questions" and continue with what's available.

1. **`sources/<ch>/INDEX.md`** — archived verified contract source inventory + curated vuln entry-point file:line references. This is **the primary reference**, not the case knowledge file. Verified bytecode > written summaries.
2. **The 3-6 entry-point files cited in INDEX.md** — open them, read the named functions end-to-end. Quote exact line numbers in the PoC NatSpec.
3. **`knowledge/mentor_hints.md`** — find the per-challenge §, read all hints. Mentor hints are gold (only source of `max_pts` ranking direction, only source of "creativity vs procedure" guidance).
4. **`knowledge/case_<protocol>.md`** — historical post-mortem narrative for context (the rekt.news version). Useful for cross-referencing what differs in the fork vs the original incident.
5. **`knowledge/vuln_db.md`** — match candidate hypotheses against the catalog of known vuln classes. Pick the entries whose preconditions overlap with what INDEX.md showed.
6. **`skills/exploit_<protocol>.skill.md`** — challenge-specific tactical guide. Read the "Archived source references" section, then the failure-modes table.
7. **`challenges/<ch>/analysis.md` Dead Ends + Hypothesis sections** — what's already been ruled out. Do NOT re-attempt a documented dead end. Do extend a partial dead end if INDEX.md reveals a new angle the previous attempt missed.
8. **`challenges/<ch>/exploits/ARCHIVE_LOG.md`** — every prior attempt's outcome chronologically. Skim for failure patterns.
9. **`challenges/<ch>/.pending_report_notes/`** — if non-empty, brain hasn't drained the queue yet. Do not duplicate work — wait for brain or escalate via `tools/notify.sh`.

If after this reading the path forward is obvious (e.g., the hypothesis was already proven and you're writing the broadcast script), proceed to §4. Otherwise §1.5.

---

## §1.5 Bytecode-diff analysis (mandatory when sources/ contains both verified AND unverified impl)

When `sources/<ch>/INDEX.md` shows BOTH a verified impl and an unverified (fork-deployed) impl — typical for ch5 where the fork-era IDA `0x848497...` is unverified but adjacent verified versions exist — the **diff between them is the attack surface**. The unverified version = verified version minus some patch lines (or plus some regression). Finding those lines is the critical step.

**Procedure** (before any hypothesis):

1. Disassemble the unverified impl:
   ```bash
   heimdall decompile <unverified_addr> --rpc-url <challenge_RPC> --output /tmp/unverified_pseudo.sol
   ```
   If heimdall fails, fall back to `cast code <addr>` + manual 4byte selector enumeration (`cast 4byte <selector>` for each). Attempt13-style selector list gives you the public surface.
2. Extract the verified impl equivalent from `sources/<ch>/<verified_addr>/src/.../*.sol`.
3. Write to `analysis.md`:
   ```markdown
   ## Bytecode Diff (Attempt N)

   | Feature | Fork impl (unverified) | Verified impl | Diff significance |
   |---|---|---|---|
   | <function>.<check> | absent / present / subset | present | ≤1-line absence → likely the patched bug |
   | <selector list> | 19 selectors | 21 selectors | 2 missing selectors may be pre-patch-only, dropped on fork, or post-patch-only |
   ```
4. **Hypotheses must reference specific diff lines.** A hypothesis that says "try ctx forgery" without citing which diff line enables it is auto-rejected under §11 quality gate.

For ch5 specifically, the known diff is `InstantDistributionAgreementV1.claim()` line 823 (`AgreementLibrary.authorizeTokenAccess(token, ctx)`) — present in verified 0x85eb/0x86e8, absent in fork 0x8484. Any new ch5 hypothesis must account for this OR propose a diff-finding not yet documented (run heimdall + compare).

---

## §2 Hypothesis tree — minimum 3 candidates (+ stream-of-consciousness first)

**Pre-hypothesis stream-of-consciousness (mandatory, before any hypothesis)**:

Before listing candidates, write in `analysis.md` under `## Code Observations (Attempt N)` a **500-1000 word stream-of-consciousness** of everything unusual you notice in the source archive. NOT structured hypotheses — just observations:

- "Why is this variable signed int256 when it should be uint?"
- "This function takes 5 arguments but only uses 4 — what's the 5th for?"
- "This state variable is declared but I don't see it read anywhere in this file"
- "These two functions look like they could interact, but nothing ties them together"
- "The verified impl has this modifier, the unverified bytecode has fewer opcodes in the function prologue — maybe the modifier is absent there"
- "This comment says 'TODO: revisit' — left in production"
- "Error strings have typos — suggests rushed patch"

The point: **force yourself to look at the code as an adversary looking for anything weird, before committing to any specific theory.** This is how real auditors find bugs — not by matching patterns but by noticing oddities and pulling on loose threads.

Only AFTER writing 500+ words of observations, proceed to hypothesis tree.

**Hypothesis tree**:

Write a numbered list of **at least 3 candidate attack vectors** in `analysis.md` under `## Hypothesis Tree (Attempt N)`. For each candidate:

```markdown
### HypA — <one-line name>
- **Why (prior evidence)**: which file:line in sources/<ch>/ or which mentor hint led to this. 1-3 sentences.
- **Expected outcome on success**: what state change happens (tokens move where, which storage slot mutates, what tx hash emits which event).
- **Expected revert pattern on failure**: which require() / custom error / panic code would block this. Be specific.
- **Single-line test plan**: the minimum solidity to verify or falsify this in one PoC function.
- **Three-axis tag**: see §3.

### HypB — ...
### HypC — ...
```

If you cannot generate 3 candidates from the reading in §1, that is a signal that §1 was incomplete — go back and re-read INDEX.md and `knowledge/mentor_hints.md` carefully, or read the `creative_escalation.skill.md` 8-step protocol for hypothesis generation prompts.

Pick the candidate with the highest prior (most three-axis matches in §3) to implement first. The other 2 are documented in `analysis.md` as `BACKUP/HypB`, `BACKUP/HypC` for fast pivot if HypA fails.

---

## §3 Three-axis pattern check (mandatory tag per hypothesis)

Tag each hypothesis on three orthogonal axes. A hypothesis matching ≥2 axes has high prior and goes first. A hypothesis matching 0 axes is dropped (likely magical thinking).

| Axis | Categories |
|---|---|
| **Code-level** | constant typo / CEI violation / missing access control / spot-price oracle / ABI quirk (trailing bytes, encoding) / unchecked external call / signed-int wraparound / proxy storage collision |
| **Logic-level** | state-machine ordering bug / cross-function reentrancy / economic exploit (flash-loan amplifier) / governance/migration race / approval frontrun / callback chain abuse |
| **Known-pattern** | matches a `knowledge/vuln_db.md` entry id (cite the id) / matches a documented mentor hint (cite the §) / matches a published audit finding |

Format inside the hypothesis block:
```
- **Three-axis tag**:
  - code-level: ABI quirk (trailing bytes)
  - logic-level: callback chain abuse
  - known-pattern: vuln_db.md §A-3 (host-controlled callback identity)
  → 3/3 matches → high prior
```

---

## §4 Source-archive primacy

When writing the PoC:

- **Quote exact file:line for every assumption.** Example NatSpec header:
  ```solidity
  /// @notice Hypothesis: K-invariant uses 10000^2 RHS but 1000-scale LHS
  /// @dev Verified at sources/ch1_uranium/0x9b9bad..._uraniumpair_wbnb_busd/src/.../UraniumV2Pair.sol:165-170
  /// @dev Mentor hint: knowledge/mentor_hints.md §2.1
  ```
- **Never guess function signatures.** If the archive has the source, read it. If unverified (only bytecode), use Heimdall (`heimdall decompile <addr> --rpc-url <RPC>`) before writing PoC.
- **Cross-reference Patch differences.** When the archive contains multiple impl versions (e.g., `_fork_patch1`, `_public_previous`, `_public_current`), diff them — the diff is often the exact attack surface.

---

## §5 Failure → next hypothesis (no parameter spam)

If PoC reverts or produces 0 delta:

1. **Document the revert** in `analysis.md` Dead Ends as `### DEAD_END (Attempt N, HypA): <one line>` with the exact revert reason quoted from the run log.
2. **Diagnose root cause** of the failure — which §3 axis was wrong? Was the prior evidence misread? Did INDEX.md mislead?
3. **Pivot to BACKUP/HypB** (the 2nd candidate from §2) and write a new `Attempt(N+1).t.sol`. Do NOT modify constants in `AttemptN.t.sol` and re-run; that's parameter spam, which §5 forbids.
4. **Parameter tuning is `tune` task only** — only after a hypothesis is confirmed working (PoC produces positive delta), the `tune` task may sweep constants to maximize drain.

Exception: a single revert pattern caused by a wrong constant (e.g., wrong index in Curve `exchange_underlying`, wrong fee tier in Uniswap V3) that is verifiable from the source archive — fix it once and re-run. If still reverting, treat as DEAD_END for this hypothesis.

---

## §6 Output requirements (what the task must leave behind)

Every task must end with:

- New entry in `analysis.md` "Hypothesis Tree (Attempt N)" §
- New `poc/AttemptN.t.sol` (or new `exploit/Run.s.sol` for exploit task) with NatSpec citing source archive paths
- New `runs/attemptN.log`
- `tools/archive.sh` call (this auto-triggers `report_increment`-equivalent — see `skills/auto_report.skill.md`)
- 3-line stdout: `STATUS:`, `DELTA:`, `NEXT:` lines (see `tools/delegate.sh` `[OUTPUT_FORMAT]`)

If the task is `debug` or `tune` and the existing PoC didn't change name (same `AttemptN.t.sol`), still archive it again so the archive log preserves the iteration history.

---

## §7 Cross-references

- `skills/auto_report.skill.md` — narrative report appended automatically after archive (brain's job)
- `skills/creative_escalation.skill.md` — 8-step escalation when 3+ hypotheses fail
- `skills/exploit_uranium.skill.md`, `_harvest.skill.md`, `_feirari.skill.md`, `_superfluid_v1.skill.md`, `_superfluid_v2.skill.md` — per-challenge tactics (each now has an "Archived source references" section, read it)
- `knowledge/mentor_hints.md` — consolidated mentor lecture quotes per challenge
- `knowledge/vuln_db.md` — known vuln class catalog with §-id labels for §3 matching
- `tools/delegate.sh` — every poc/debug/exploit/tune task injects `skills/deep_analysis.skill.md` + `sources/<ch>/INDEX.md` + `knowledge/mentor_hints.md` into REQUIRED_READING

---

## §8 Adversarial self-critique (mandatory after writing hypothesis tree)

After writing 3+ hypotheses, take the adversary's perspective and critique each. In `analysis.md` under `## Self-Critique (Attempt N)`:

For each hypothesis:
- "If I were the protocol auditor who approved this code, **why would I have thought this was safe**?"
- "What did the audit miss? What was the developer's mental model that blinded them?"
- "What's the simplest thing that would break this hypothesis (make it a dead end)?"
- "Is there a stronger version of this hypothesis I'm not considering?"

If a hypothesis survives this critique (you can't find simple reasons it fails), it graduates to "high-confidence" and goes first. If a hypothesis collapses under critique, demote it to backup or drop.

This is the single most important step for ch5-class problems. Mentor's framing "1 of 5 cohorts solved it" means 4 cohorts stopped at the first plausible hypothesis without self-criticism.

---

## §9 Analog reasoning (mandatory for ch5, recommended for all)

After hypothesis tree + self-critique, cross-reference against similar attacks:

- **Which of these hypotheses resembles a known attack on another protocol?** Search `knowledge/vuln_db.md`, `knowledge/case_*.md`, `knowledge/external_refs.md` for analogs.
- **Which resembles the already-working exploit on a SIBLING challenge?** For ch5, this is ch4 (v1 ctx forge). The mechanism transfers — see `knowledge/mentor_hints.md` §6.4 ("v2 technique applies to v1").
- **Which is unique to this challenge with no analog?** Novel-appearance hypotheses are highest-risk/highest-reward. For these, write ≥3 variants (same hypothesis with different parameters) to explore the space.

Write to `analysis.md` under `## Analog Cross-Reference (Attempt N)`:
```markdown
- HypA: analogous to <prior exploit / vuln class> because <specific mechanism overlap>. Transfer rate: high/medium/low.
- HypB: novel, no direct analog. High risk, high reward. Variants: HypB.1 (with X), HypB.2 (with Y).
- HypC: weakly analogous to <X>. If HypA fails, HypC probably fails too.
```

---

## §10 Cross-challenge synthesis (mandatory when stuck on ch4/ch5)

Before declaring DEAD_END on ch5, check if the hypothesis can be re-applied to ch4. Mentor hint §6.4: "v2 technique applies to v1, boosts v1 score too."

Similarly, before declaring DEAD_END on ch4, check if a ch5 attempt's intermediate finding (e.g., callback frame introspection, registerApp bypass) applies to ch4.

Write to `analysis.md` under `## Cross-Challenge Check`:
- "Does this technique apply to ch<other>?" Yes/No with justification.
- If Yes, create a new hypothesis for ch<other> and delegate a parallel task.

---

## §11 Hypothesis quality gate (self-check before submitting)

Before running `forge test` / `cast send`, verify your `analysis.md` additions satisfy:

- [ ] `## Code Observations (Attempt N)` section exists and ≥500 words
- [ ] `## Hypothesis Tree (Attempt N)` has ≥3 candidates
- [ ] Each hypothesis cites specific file:line from `sources/<ch>/` (not generic "the IDA contract")
- [ ] Each hypothesis has three-axis tag with explicit category per axis
- [ ] Each hypothesis has expected-revert-pattern (specific require() message / custom error name / panic code)
- [ ] `## Self-Critique (Attempt N)` section exists — for each hypothesis, at least 3 adversarial questions answered
- [ ] `## Analog Cross-Reference (Attempt N)` section exists
- [ ] If bytecode diff applies (§1.5), `## Bytecode Diff (Attempt N)` section exists

If any checkbox fails → STOP, do not proceed to solidity. Fix the missing section first. Codex prompt explicitly forbids skipping these for the sake of "getting to code faster" — the code itself is cheap, the analysis is the work.

`tools/hyp_validator.sh` automatically checks #1-#4 after task completion; failing validation blocks the task from being marked success.

---

## §12 Anti-patterns (do not do these)

- ❌ Writing `Attempt1.t.sol` without first reading `sources/<ch>/INDEX.md` and running §1.5 bytecode diff
- ❌ Generating only 1 hypothesis and committing the rest of the budget to it
- ❌ Writing hypotheses without 500+ word §2 stream-of-consciousness first (bypasses insight generation)
- ❌ Re-running `AttemptN.t.sol` with adjusted constants (parameter spam — §5 violation)
- ❌ Quoting function signatures from external memory rather than the archive
- ❌ Skipping `knowledge/mentor_hints.md` because "I already know the challenge"
- ❌ Treating "the PoC compiled" as success — success is `cast balance` increase
- ❌ Leaving `analysis.md` Dead Ends section without documenting why the revert happened
- ❌ Skipping §8 self-critique — a hypothesis that can't survive adversarial questioning is a waste of implementation effort
- ❌ Skipping §9 analog reasoning on ch5 — the cross-challenge mentor hint (§6.4) is the shortest path to ch4 point boost too
- ❌ Skipping §11 quality gate — tools/hyp_validator.sh will catch this but you shouldn't need it to
- ❌ For ch5: declaring DEAD_END without re-checking if the hypothesis works on ch4 (cross-challenge synthesis §10)
