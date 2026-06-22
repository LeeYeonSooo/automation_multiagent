# auto_report.skill.md

**Primary consumer: Claude (brain). NOT Codex.**

Narrative report entries are written by Claude personally — Codex writes exploit code, Claude writes the analysis story. This skill governs how Claude turns each archived attempt into a `report.md` entry.

---

## 1. Trigger

A trigger is the appearance of a new file in `challenges/<ch>/.pending_report_notes/`. Each `.note` file represents one attempt that was just archived (`tools/archive.sh` writes it).

Claude must drain this queue **before doing the next strategic action**. Specifically:

- §0 self-check (every session start) includes "process all `.pending_report_notes/*.note` files".
- After receiving any task notification (delegated `poc`/`exploit`/`debug`/`tune` returning), check for new pending notes and process them.
- When stuck and pivoting strategies, drain the queue first so the report stays in sync with what was tried.

---

## 2. Note file format (input)

`tools/archive.sh` produces one `.note` file per archive call:

```
# pending report note — process via skills/auto_report.skill.md
ts: <UTC ISO8601>
challenge: <ch>
bucket: successful | in_progress | failed
desc: <short slug>
src_original: <path/to/source/before/archive>
archived: <path/to/exploits/<bucket>/file>

# auto-collected hints:
latest_runs:
  - challenges/<ch>/runs/...
status_snapshot:
  { ... status.json contents ... }
```

Filename: `<UTC>_<bucket>_<desc>.note`. Drain in chronological filename order.

---

## 3. Processing one note

For each `.note` Claude does:

1. **Read** the note + the actual archived file (`archived:` path) + the most recent matching `runs/*.log`.
2. **Triage** (see §3.5): judge Meaningful / Minor / Skip.
3. **Open** `challenges/<ch>/report.md` (create from §4 skeleton if missing). Skip-tier doesn't need report.md touched.
4. **Append** per tier:
   - Meaningful → one timeline row (§5) + one §4 entry with **all 5 subsections** (§6).
   - Minor → one timeline row (§5) + one §4 entry with **Why + Result** mandatory, ThoughtProcess optional, How/WhySucceededFailed omitted unless one sentence helps.
   - Skip → ARCHIVE_LOG.md skip one-liner (§3.6). No report.md change.
5. **Delete** the `.note` file (`rm <note_path>`).
6. **Verify**: the markers `<!-- AUTO-TIMELINE-INSERT -->` and `<!-- AUTO-ATTEMPTS-INSERT -->` are still present at the bottom of their sections.

Do NOT delegate this work to Codex. Do NOT batch-rewrite the file. One note → one append (or skip log) → one delete.

---

## 3.5 Triage judgment (per-note, mandatory before §3 step 3)

For each note, classify into exactly one tier.

**Meaningful** (full 5-subsection entry — §6 default): choose this when at least one is true:
- Bucket is `successful` AND the run produced a non-trivial native delta (new max balance or strategy-first).
- Bucket is `in_progress` AND the PoC proves a new surface (not repeat).
- Bucket is `failed` AND the failure *closes a hypothesis* for the first time (DEAD_END confirmation for a major path, not parameter noise). These are the ones mentors grade: "왜 실패했는가" is the learning.
- The attempt generated an unexpected observation (bytecode / log / balance anomaly) worth preserving for later hypotheses.

**Minor** (2-3 subsection entry): choose when:
- Same hypothesis as a prior Meaningful entry but with parameter nudge or reset-retry.
- Partial drain mop-up that repeats a proven pattern.
- Incremental victim enumeration that neither succeeds new nor closes new ground.
- A narrower confirmation of a prior DEAD_END (same reason, different target).

**Skip** (ARCHIVE_LOG.md one-liner only): choose when:
- Duplicate archive of a file already entered under an earlier note (rare — archive.sh shouldn't dupe, but safety).
- Infrastructure noise: RPC timeout mid-run, transient broadcast revert that was retried and Recovered in a later attempt, stale artifact moved to the wrong bucket.
- Zero new information beyond what earlier entries already contain.

Rule: **when in doubt, lean Meaningful.** Triage is not for hiding effort — skipping a genuinely failed hypothesis removes the learning the mentor wants to see. Skip only for demonstrably redundant or infrastructure-only events.

---

## 3.6 Skip one-liner (ARCHIVE_LOG.md append)

For a Skip-tier note, do NOT touch report.md. Append one row to `challenges/<ch>/exploits/ARCHIVE_LOG.md` (same table the archive.sh uses — schema is `| Time | Bucket | Source | Destination | Description |`). Use this shape:

```markdown
| <note_ts> | skipped | `<note_path>` | — | <reason, e.g., "infra: rpc reset mid-run; superseded by <ts2>"> |
```

Delete the `.note` file after the append. The skip is auditable via ARCHIVE_LOG.md; no report.md row appears.

---

## 4. Skeleton (only if `report.md` does not exist)

```markdown
# <Challenge Name> — Exploit Report (incremental)

> Built up one entry per attempt. Brain writes the narrative; Codex writes the exploit code. §1, §2, §5–§8 are filled by brain on final review.

## 1. TL;DR
<TODO brain — final summary table after all attempts archived>

## 2. Vulnerability Summary
<TODO brain — single paragraph root-cause overview>

## 3. Attack Timeline (auto-updated by brain)

| # | Time (UTC) | Bucket | Source | Native Δ | Hypothesis (one line) |
|---|---|---|---|---|---|
<!-- AUTO-TIMELINE-INSERT -->

## 4. Attempts (one entry per archive)
<!-- AUTO-ATTEMPTS-INSERT -->

### Patterns observed across attempts
<TODO brain — cross-cutting analysis after all attempts in>

## 5. Final Successful Exploit (Reproduction)
<TODO brain — last successful/ entry, step-by-step reproduction>

## 6. Root Cause Analysis (Deep)
<TODO brain — systemic, not surface-level>

## 7. Better Patch Proposal
<TODO brain — minimal diff + why obvious fix insufficient + architectural redesign + defense-in-depth>

## 8. Lessons Learned
<TODO brain — attacker / defender / auditor perspectives>

## Appendix A. Contracts
<auto-link to recon/contracts.json>

## Appendix B. References
<TODO brain — knowledge files, external post-mortems, patch commits>
```

---

## 5. Timeline row format (§3 — append above marker)

```markdown
| <N> | <ts> | <bucket> | `<basename(archived)>` | <wei or n/a> | <one-line hypothesis> |
```

`<N>` = count of existing rows + 1. Determine by reading the table, not by guessing.

---

## 6. Attempts entry format (§4 — append above marker)

**Tier marker**: begin the entry header with `[Meaningful]` or `[Minor]`. Skip-tier does not reach this section.

### 6.1 Meaningful entry (full 5 subsections — mandatory)

```markdown
### [Meaningful] Attempt <N> — <bucket>:<desc> — <ts>

**File:** `<archived path>`
**Run log:** `<latest matching runs/*.log>`
**Outcome:** <pass | fail | broadcast-success | broadcast-fail>
**Native delta:** <wei>  (<human> <token>)

**Why** — Why this hypothesis was tried.
- 2-4 sentences. Reference the previous Attempt # if applicable. Connect to recon findings or a prior failure.

**How** — What was actually executed.
- 3-6 sentences plain language.
- Code excerpt 3-10 lines, fenced ` ```solidity ` (or appropriate lang), with a header comment giving the file path and line range.

**Result** — Concrete outcome.
- Exact revert reason quoted from the log (if failed).
- Exact native balance change (if broadcast).
- Exact tx hash (if broadcast).

**Why succeeded / Why failed** — Root cause.
- For success: which line / which condition was decisive — not "the bug worked", but WHY it worked at this exact point.
- For failure: where exactly it broke and why — NOT just the surface error message; the underlying reason.

**Thought process** — What brain decided next.
- "Given this result, the next step was X because Y."
- 1-3 sentences. This connects to the next Attempt's Why.
```

All five subsection headers (**Why** / **How** / **Result** / **Why succeeded/failed** / **Thought process**) are mandatory for Meaningful entries. Body prose plus optional code blocks.

### 6.2 Minor entry (2-3 subsections)

```markdown
### [Minor] Attempt <N> — <bucket>:<desc> — <ts>

**File:** `<archived path>`
**Run log:** `<latest matching runs/*.log>`
**Outcome:** <pass | fail | broadcast-success | broadcast-fail>
**Native delta:** <wei>  (<human> <token>)

**Why** — 1-2 sentences. Reference the Meaningful entry this builds on (e.g., "Attempt 4 param tune: iter 7→12").

**Result** — 1 sentence with the concrete delta or revert reason. Optional 1-2 line log quote.

**Thought process** — (optional) 1 sentence on whether this changed direction or just confirmed the prior plan.
```

Why/How/WhySucceededFailed collapsed on purpose — Minor entries exist because the Meaningful entry they ride on already carries the reasoning.

### 6.3 Skip-tier has NO §4 entry

It only gets the ARCHIVE_LOG.md one-liner from §3.6. Do not create a stub §4 entry for skipped notes — that defeats the point of skipping.

---

## 7. Numbering

`<N>` is sequential across the entire challenge timeline — count rows in §3 timeline table and add 1. Don't skip even if a previous append failed. If you find a numbering gap (e.g., timeline has 1, 2, 4 but no 3), backfill the missing one from `ARCHIVE_LOG.md` row 3 before adding new entries.

---

## 8. Source extraction

When excerpting from the archived file in §4 **How**:
- Pick the function or block embodying the hypothesis (not boilerplate).
- 3-10 lines max. Use `// ... elided ...` if compressing.
- Preserve original formatting.
- Header comment with path + line range:
  ```solidity
  // <archived_path>:<startLine>-<endLine>
  function exploit() ... { ... }
  ```

When excerpting from run log for **Result**:
- Pick the line(s) showing the actual revert / balance change.
- Quote inside fenced ```text block.

---

## 9. What this skill does NOT do

- Does not write §1, §2, §5, §6, §7, §8 — those are brain's finalization sections (TODO markers preserved until then).
- Does not rewrite or merge earlier entries.
- Does not delete entries on subsequent runs — append-only.
- Does not deduplicate — if archive.sh ran twice on the same file, two entries appear; brain dedupes on final review.
- Does NOT delegate any part to Codex. The narrative is brain's job.
- **Triage (§3.5) is NOT a tool for hiding effort.** Skipping a genuinely failed hypothesis erases the learning the mentor wants to see. Skip only for demonstrably redundant or infrastructure-only events; otherwise pick Meaningful or Minor.

---

## 10. Failure modes

| Symptom | Cause | Fix |
|---|---|---|
| Marker missing | Earlier hand-edit removed it | Re-add marker at section bottom, then append |
| `report.md` exists but no skeleton headers | Old format stub | Backup to `report.md.bak`, recreate skeleton, paste old content into §4 as legacy entries |
| Two entries with same N | Race between concurrent task notifications | Renumber chronologically by ts on the spot |
| `archived:` file missing | Race with cleanup | Note `<source no longer accessible>` in entry, use `git log` if available |
| Pending notes pile up because brain forgot | §0 violation | Drain ALL of them now before any other action |

---

## 11. Bulk legacy backfill

If `.pending_report_notes/` is empty but `exploits/ARCHIVE_LOG.md` shows N entries with no corresponding `report.md` rows: backfill mode.

For each row in `ARCHIVE_LOG.md`:
1. Extract ts/bucket/source/destination/desc from the row.
2. Synthesize a virtual note with the same fields.
3. Process per §3 above (append timeline row + attempts entry).

For backfill, the `runs/*.log` matching may be approximate — pick the log with closest timestamp to the archive ts. Note the uncertainty in the entry's **Result** subsection if exact log can't be located.

---

## 12. Cross-references

- `tools/archive.sh` — emits `.pending_report_notes/*.note` files
- `tools/delegate.sh` — does NOT have `report_increment` task_type (intentionally removed)
- `skills/report_writing.skill.md` — long-form report style + finalization spec for §1/§2/§5–§8
- `templates/report.md.template` — long-form template for finalization
- `CLAUDE.md` §0 + §8 — automation policy (drain queue every session start; brain writes narrative)
