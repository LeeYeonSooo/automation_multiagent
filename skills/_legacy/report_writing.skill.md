# report_writing.skill.md

Primary consumer: Codex (draft author) + Claude Code (finalization reviewer).

This skill is loaded when a `report_draft` task fires, or when the brain is finalizing the deliverable markdown file in `challenges/<ch>/report.md`. Also relevant while writing `analysis.md` dead-ends, since those become section 4 material.

Critical: the "Failed Attempts" section is explicitly graded by the course staff. It is NOT optional. Every dead-end hypothesis — even embarrassing ones — is included. The mentor's framing: documenting failure demonstrates understanding of the problem space.

---

## 1. Output paths

Draft path: `challenges/<ch>/report.md` — Codex writes here.
Final path: `reports/<ch>.md` — brain copies the finalized version after review.

Follow `templates/report.md.template` when the template file exists. If not yet created, the structure in section 2 IS the working spec. Be consistent across all five challenges so the course staff sees a coherent deliverable.

Format constraints: GitHub-Flavored Markdown. No emoji. No fluff. Code in fenced blocks with language tags. Addresses in backticks.

---

## 2. Five-section skeleton

Top-level layout. Copy this shape as the starting skeleton for every challenge.

```
# <Challenge Name> — Exploit Report

## 1. TL;DR
- one-row summary table (score, delta, attempts, tx hash, technique one-liner)
- 2-3 sentence narrative summary

## 2. Root Cause
### 2.1 Code-level bug
- quote the exact lines from source with line numbers
- explain what the line does, what it should do, and the numeric consequence
### 2.2 Architectural antipattern
- why this kind of bug slipped through (fork without audit, incomplete patch, etc.)
- cross-reference knowledge/vuln_db.md relevant section

## 3. Attack Reproduction
### 3.1 Full chain (numbered steps with exact inputs)
### 3.2 Exact inputs (table: fork block, flash loan, primary call, iteration count)
### 3.3 Transaction hashes (on fork)
### 3.4 Gas and cost (gas used, flash fees, net profit)

## 4. Failed Attempts
- one subsection per dead-end hypothesis
- each entry: Hypothesis / What was tried / Result / Why it failed / Lesson
- minimum 3 entries; 5-15 is typical with escalation
- end with a "Dead-end patterns observed" cross-cutting analysis

## 5. Better Patch Suggestion
### 5.1 Minimal diff (compile-ready)
### 5.2 Why the obvious patch is insufficient
### 5.3 Recommended redesign (architectural)
### 5.4 Defense in depth (caps, pause, rate limits)

## Appendix
- A. Contracts in scope (from recon/contracts.json)
- B. References (knowledge/case_*, skills/exploit_*, external post-mortems)
- C. PoC / exploit files (paths to .t.sol, .s.sol, run logs)
```

---

## 3. Section guidance

### Section 1 — TL;DR

Lead with a metrics table. Rows:
- Final score, shown as `<earned> / <max_pts>`
- Starting native balance (typically 0)
- Ending native balance
- Delta in wei AND human-readable
- Attempts made (N PoC, M exploit runs)
- Final exploit tx hash
- Technique in one line (precise enough that staff can map it to a lecture module)

Then 2-3 sentences of narrative. Do NOT cram analysis into TL;DR.

### Section 2 — Root Cause

Section 2.1 quotes source directly. Use a fenced `solidity` block with a comment indicating path and line range, then one paragraph: what the line does, what it should do, numeric impact.

Section 2.2 is the architectural story. Not "they had a bug" — it's "this class of bug existed because <systemic reason>". For the five challenges:

- ch1 Uranium: UniV2 fork modified fee math, didn't rederive invariant, no invariant fuzz testing
- ch2 Harvest: spot-price oracle used for share math; threshold guard not cumulative across iterations
- ch3 Fei-Rari: fork of Compound changed `transfer` to `call.value`, did not re-review reentrancy model; missing cross-function nonReentrant
- ch4 Superfluid v1: trusted fields transported in untrusted calldata; length-only placeholder check
- ch5 Superfluid v2: incomplete patch — `claim()` missing `authorizeTokenAccess`, non-`msgSender` ctx fields still spoofable

### Section 3 — Attack Reproduction

Every numeric input must appear in this section. A staff grader should be able to replay from just section 3 + source tree.

Section 3.1: numbered steps. Each step names a function call and its expected state change.
Section 3.2: table of exact inputs — fork block, flash loan amount/token/provider, primary call selector+args, iteration count if applicable.
Section 3.3: tx hashes. PoC reference is `see runs/attemptN.log`. Production broadcast has a real tx hash on the fork. Include both.
Section 3.4: gas used, flash fees, net profit. All in wei, with human-readable parenthetical.

### Section 4 — Failed Attempts — most important section

Pull from `challenges/<ch>/analysis.md` "Dead ends" list. Normalize each entry to:

```
### Attempt N — <one-line name>

- Hypothesis: <full sentence>
- What was tried: <which AttemptN.t.sol, key changes>
- Result: <revert with selector / wrong-sign delta / no effect>
- Why it failed: <root cause, not surface error>
- Lesson: <one-liner, reusable for other challenges>
```

Common mistakes to avoid:
- Hiding embarrassing fails (e.g., "wrong address for 2 hours"). Include them.
- Only listing compile errors — focus on semantic fails.
- Skipping the lesson line — each failure must produce one reusable insight.

End section 4 with a "Dead-end patterns observed" subsection — cross-cutting observations (example: "all `Error(string)` reverts were parameter typos; all `Panic(0x11)` pointed to guarded arithmetic in `calcShares`"). Pattern-match fodder for graders.

### Section 5 — Better Patch Suggestion

Section 5.1: compile-ready minimal diff. Codex's draft usually produces this correctly by comparing the buggy version against the known patched version.

Section 5.2: what a lazy reviewer would miss. Brain fills this. Ask: "if I applied only 5.1, what's still exploitable?" For ch4/ch5 this is mandatory — must discuss the "incomplete patch" antipattern explicitly.

Section 5.3: architectural recommendation — library invariants, interface-level invariants, runtime assertions, CI invariant tests.

Section 5.4: defense in depth — TVL caps, circuit breakers, admin pause, rate limits.

---

## 4. Style rules

- Code blocks: fenced with language tags (`solidity`, `diff`, `bash`).
- Addresses: backticks, full 40-char + `0x` prefix, no ellipsis unless in inline narrative.
- Amounts: show wei and human-readable — `150_000_000_000000 (150M USDC)` or equivalent.
- Line numbers when citing source: `Contract.sol line 142-146`.
- Diagrams: ASCII boxes or numbered flows. No image files unless strictly necessary.
- No emoji anywhere.
- Tense: past tense for reproduction narrative, present tense for code behavior.
- Voice: third person ("the attacker called..."), not first person.

---

## 5. Division of labor

Codex (draft):
- Section 1 table populated from `status.json` + latest logs
- Section 2.1 source excerpt extraction
- Section 3 reproduction from PoC + exploit scripts + run logs
- Section 4 literal transcription of analysis.md Dead ends, with format normalization
- Section 5.1 obvious minimal diff by comparing vulnerable vs patched version
- Leaves 2.2, 5.2, 5.3, 5.4 as stubs marked with `<TODO brain>`

Brain (finalization):
- Verifies every fact in sections 1 through 3 against run logs
- Writes 2.2 architectural analysis
- Expands 4 with cross-cutting pattern subsection
- Writes 5.2 through 5.4 (highest-value analysis sections)
- Adds Appendix references
- Copies final to `reports/<ch>.md`

---

## 6. Completion checklist

- All five sections present and non-stub
- TL;DR table populated with concrete numbers
- At least 3 entries in section 4 Failed Attempts (more if escalation was invoked)
- Section 5 includes 5.1 diff AND 5.2 "why obvious patch insufficient"
- Every tx hash / file path referenced actually exists
- No TODOs or placeholders remaining (grep for `TODO`, `XXX`, `FIXME`, `<place`)
- Addresses are full, not abbreviated
- Code blocks have language tags
- No emoji anywhere
- Copied to `reports/<ch>.md`
- `status.json.state = "report_drafted"` (then `"completed"` after brain review)

---

## 7. Cross-references

- `templates/report.md.template` — the authoritative template if/when it exists
- `challenges/<ch>/analysis.md` — source material for 2.2 and 4
- `challenges/<ch>/runs/*.log` — source material for 3 numerics
- `challenges/<ch>/status.json` — source for the TL;DR metrics table
- `knowledge/vuln_db.md` — cite the applicable section in 2.2
- `knowledge/scoring_model.md` — useful for TL;DR score context
- `skills/creative_escalation.skill.md` — if the challenge went through escalation, section 4 entries may mirror escalation steps
