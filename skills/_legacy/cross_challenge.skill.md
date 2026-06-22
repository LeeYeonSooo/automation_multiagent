# cross_challenge.skill.md

**Primary consumer**: Codex working on ch4/ch5; Brain orchestrating cross-challenge synthesis.

Mentor hint §6.4: "v2 익스플로잇 방법을 알면 같은 기법을 v1에서도 쓸 수 있다. v2가 풀리면 v1 점수도 같이 올라간다."

In Upside Assignment C, challenges are NOT independent. ch4 (Superfluid v1) and ch5 (Superfluid v2) share the same Host, IDA, SuperTokens — they differ only in which patch level is deployed on the fork. Similarly, ch1 (Uranium) is a UniV2 fork → UniV2 invariants transfer. ch3 (Fei-Rari) is Compound V2 fork → CEther mechanics transfer to any CEther-forked pool on the same fork (Tetranode, Fraximalist, etc.).

This skill is the **protocol for transferring insight between challenges**.

---

## §1 When to trigger cross-challenge synthesis

Trigger conditions (ANY of these → run §2 protocol):

- A ch5 hypothesis reaches DEAD_END → check if the technique transfers to ch4 (even though ch4 is already exploited — adds points via different vector).
- A ch4 hypothesis succeeds → check if a scaled version transfers to ch5 (may unlock ch5 via a path we didn't see).
- ch3 Fei-Rari finds a new Fuse pool to drain → check if the same pool's Compound-V2-fork pattern applies to ANY compound-fork on other challenges (unlikely, but zero-cost check).
- ch1 Uranium finds a new AMM invariant bug in a different UniV2 fork → document in `knowledge/vuln_db.md` even if not directly applicable.
- Brain observation: same class of bug (CEI, callback chain, ABI quirk) appearing in two challenges' analysis.md.

---

## §2 Cross-challenge synthesis procedure

For the originating challenge's finding X, walk through every other challenge:

```markdown
## Cross-Challenge Check (Attempt N on <originating_ch>)

### Does X apply to ch1 (Uranium)?
- **Mechanism overlap**: <yes/no> — <why>
- **Action**: <skip / spawn parallel task / incorporate into existing ch1 hypothesis>

### Does X apply to ch2 (Harvest)?
...

### Does X apply to ch3 (Fei-Rari)?
...

### Does X apply to ch4 (Superfluid v1)?
...

### Does X apply to ch5 (Superfluid v2)?
...

### Transfer rate summary
- High-overlap challenges: <list>
- Low-overlap but worth exploring: <list>
- No overlap: <list> (document to avoid re-checking later)
```

---

## §3 Specific transfer pairs worth always checking

### ch4 ↔ ch5 (Superfluid v1 ↔ v2)
Same addresses, different impl. **ALL v1 techniques must be re-tested on ch5** and vice versa. Even a small technique (e.g., batchCall with a specific opcode combination, specific timestamp) may behave differently due to Patch 1 coverage gaps.

Currently documented in `skills/exploit_superfluid_v2.skill.md`. Update there when findings transfer.

### ch1 ↔ ch3 (UniV2 fork ↔ Compound fork)
Unrelated mechanics but share "fork without re-auditing after modification" vulnerability class. Patterns:
- ch1: constant `1000` → `10000` without adjusting LHS
- ch3: `transfer` → `call.value` without rechecking reentrancy surface

If either challenge discovers a sibling fork with similar copy-paste bugs on the same fork state, document in `knowledge/vuln_db.md` for future reference.

### ch2 ↔ cross-protocol oracle abuse
If ch2's iteration pattern (pump→deposit→dump→withdraw) reveals a specific Curve pool / Yearn vault interaction quirk, the same pattern may work on other yield aggregators on the same fork (Harvest itself has multiple vaults: fUSDC, fDAI, fWETH, fUSDT). Scan all HVault deployments.

---

## §4 Brain's role (orchestration)

When Codex reports a finding that triggers §1:
1. Brain reads the Codex output
2. Brain runs §2 mentally (or uses this skill's checklist)
3. Brain spawns new `delegate.sh` tasks for each high-overlap challenge, with explicit "cross-apply finding X from ch<Y>" in the GOAL
4. Brain's own report.md entry for the originating attempt mentions the cross-challenge implications (§4 subsection: "Cross-challenge applicability")

---

## §5 Pitfalls

- **Don't re-test trivially**: if the finding is "ch4's trailing-bytes trick works" and we already have ch4 exploited, don't spawn a redundant task on ch4. Instead, ask "does the v2 patched version of this trick bypass Patch 1?" — that's the interesting question.
- **Track the cross-application in analysis.md**: if you spawn a cross-challenge task, reference it in the originating analysis.md with `See also: challenges/ch<Y>/analysis.md Attempt<M>`.
- **Mentor hint is asymmetric**: "v2 solution → v1 point boost" is explicit; "v1 solution → v2 point" is NOT explicit (we have ch4 solved but ch5 not). Don't assume reverse transfer.

---

## §6 Cross-references

- `knowledge/mentor_hints.md` §6.4 — the source hint
- `skills/deep_analysis.skill.md` §10 — cross-challenge check is mandatory step before DEAD_END
- `knowledge/vuln_db.md` — catalog where cross-patterns accumulate
- `skills/creative_escalation.skill.md` — when cross-challenge check yields nothing, escalate creatively
