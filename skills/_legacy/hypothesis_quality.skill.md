# hypothesis_quality.skill.md

**Primary consumer**: `tools/hyp_validator.sh` (automated check) + Brain (manual review).

Every `poc`/`debug` task produces a hypothesis tree in `challenges/<ch>/analysis.md`. This skill defines the rubric the validator applies and the brain uses to accept/reject Codex's output.

---

## §1 Quality gate — mandatory sections per Attempt N

Validator parses `analysis.md` for the following headings, all tagged with the attempt number:

| Section heading | Required | Min-length | Source |
|---|---|---|---|
| `## Code Observations (Attempt N)` | ✅ | 500 words | `deep_analysis.skill.md` §2 stream |
| `## Hypothesis Tree (Attempt N)` | ✅ | 3 hypotheses | `deep_analysis.skill.md` §2 tree |
| `## Self-Critique (Attempt N)` | ✅ | 3+ questions/hypothesis | `deep_analysis.skill.md` §8 |
| `## Analog Cross-Reference (Attempt N)` | ✅ | 1 paragraph | `deep_analysis.skill.md` §9 |
| `## Bytecode Diff (Attempt N)` | ⚠️ conditional | 1 table | §1.5 (only if verified+unverified impls exist in sources/) |
| `## Cross-Challenge Check (Attempt N)` | ⚠️ conditional | 5 subsection | §10 (only if stuck on ch4/ch5) |

Missing or empty sections → validator blocks the task from being marked success → brain is notified.

---

## §2 Per-hypothesis rubric

Each hypothesis inside `## Hypothesis Tree (Attempt N)` must contain ALL of:

```markdown
### Hyp<L> — <one-line name>
- **Why (prior evidence)**: <cite specific file:line from sources/<ch>/> — NOT "the IDA contract" generic
- **Expected outcome on success**: <specific state mutation / event emitted / tx hash criteria>
- **Expected revert pattern on failure**: <specific require message / custom error name / panic code>
- **Single-line test plan**: <one solidity statement that verifies/falsifies>
- **Three-axis tag**:
  - code-level: <typo|CEI|access|oracle|ABI-quirk|unchecked-call|signed-wrap|proxy-storage>
  - logic-level: <state-machine|cross-function-reentrancy|economic|governance-race|approval-frontrun|callback-chain>
  - known-pattern: <vuln_db.md §id or "novel">
  → <score>/3 matches → <high|medium|low> prior
```

Hypothesis scoring:
- **3/3 matches** → high prior, implement first
- **2/3 matches** → medium prior, backup
- **1/3 matches** → low prior, document but skip unless higher-prior exhausted
- **0/3 matches** → reject (likely magical thinking)

Validator checks each hypothesis block for presence of all 5 subfields.

---

## §3 Brain manual review checklist

When Codex task completes, brain reads the new analysis.md sections and scores:

**Depth test** (beyond validator):
- [ ] Does Code Observations contain ≥3 observations that a sibling Codex session in the same challenge would NOT have found trivially? (Otherwise it's template-matching, not thinking.)
- [ ] Does the top hypothesis reference a file:line that nobody cited in prior attempts? (Otherwise we're retreading.)
- [ ] Does Self-Critique include at least one question that would invalidate the top hypothesis (not just confirm it)? (Otherwise critique is sycophantic.)
- [ ] Does Analog Cross-Reference identify a vuln_db.md entry OR honestly say "novel, no analog"? (Otherwise it's vague.)

**Creativity test** (for ch5 specifically):
- [ ] Is at least one hypothesis categorized as "novel, no analog"? (ch5 is 1/5-cohort difficulty → the winning vector is likely novel.)
- [ ] Does the top hypothesis account for the documented constraints from prior Dead Ends? (Or does it propose a constraint that's already been invalidated?)

If any brain-review checkbox fails → brain responds in 3 ways:
1. Mild failure (1-2 boxes) → add a comment in analysis.md noting the gap, continue to next attempt
2. Moderate failure (3-4 boxes) → re-delegate with explicit prompt fix ("your Code Observations section lacked depth; redo specifically noting X, Y, Z")
3. Severe failure (5+ boxes) → pause challenge, trigger `creative_escalation.skill.md` 8-step protocol with brain running it in person

---

## §4 Validator implementation

See `tools/hyp_validator.sh`. Runs after each delegate.sh task that wrote to `challenges/<ch>/analysis.md`. Outputs to stdout:
- `HYP_QUALITY: pass` if all mandatory sections present + each hypothesis has 5 subfields
- `HYP_QUALITY: fail: <reason>` otherwise, with specific missing element cited

Validator does NOT judge semantic quality (that's brain's job per §3). It only checks structural presence.

---

## §5 Examples

### GOOD (passes §2 rubric)

```markdown
### HypA — claim() callback publisher-override via forged subscriber dirty state
- **Why (prior evidence)**: sources/ch5_superfluid_v2/0x85eb36.../src/contracts/agreements/InstantDistributionAgreementV1.sol:840 — `require(vars.sdata.subId == _UNALLOCATED_SUB_ID, ...)`. Combined with Attempt 14 finding that 75 SuperApp publishers exist with dormant indexes, if we can set sdata.subId to UNALLOCATED AND sdata.indexValue < victim_idata.indexValue, claim() will settle from publisher to us.
- **Expected outcome on success**: Attacker EOA balance increases by `(victim_idata.indexValue - 0) × units`; publisher balance decreases by same amount.
- **Expected revert pattern on failure**: `IDA_SUBSCRIPTION_ALREADY_APPROVED` if subId != 0xffffffff, OR `IDA_SUBSCRIPTION_DOES_NOT_EXIST` if sId hash mismatch.
- **Single-line test plan**: `bytes32 sId = keccak256(abi.encodePacked("subscription", publisher_superapp, indexId, attacker));` then probe `IDA.getSubscription(token, publisher_superapp, indexId, attacker)` for existence and subId state BEFORE any forge attempt.
- **Three-axis tag**:
  - code-level: proxy-storage (subscription data hash layout)
  - logic-level: state-machine (UNALLOCATED → APPROVED → settle)
  - known-pattern: vuln_db.md §A-4 (pre-existing dormant state abuse) + mentor_hints.md §6.6 (publisher callback)
  → 3/3 → high prior
```

### BAD (fails §2 rubric)

```markdown
### HypA — try forging ctx differently
- Maybe appCallbackLevel matters
- Try different values
- Should work
```

Reasons: no file:line citation, no specific revert prediction, no test plan, no three-axis tag. Validator flags all 5 missing subfields.

---

## §6 Cross-references

- `skills/deep_analysis.skill.md` — the canonical protocol (§11 specifies the quality gate)
- `skills/cross_challenge.skill.md` — cross-challenge check (§4 "Brain's role")
- `skills/creative_escalation.skill.md` — escalation when quality repeatedly fails
- `tools/hyp_validator.sh` — automated validator
