# external_refs.md

External reference inventory per challenge — audit reports, patch commits, Discord/forum discussions, public exploit analyses. Read alongside `knowledge/case_*.md` (incident narrative) and `sources/<ch>/INDEX.md` (archived source).

These are **pointers**, not mirrors. If bandwidth permits, the actual content should be WebFetch'd and stashed under `knowledge/external_content/<ch>/` — see §7 for the stash protocol.

---

## §1 ch1 Uranium Finance

### Incident
- Attack tx (BSC mainnet): search `rekt.news/uranium-rekt` for the canonical story
- Attacker address: `0xc47bdd0a852a88a019385ea3ff57cfbda1a8fac5` (approximate; verify via rekt)

### Patch / post-mortem
- Uranium team's own post-mortem: project shut down post-exploit, minimal official docs
- Key reference: SushiSwap's UniV2 post-fork audit checklist (by similarity)

### Pattern references
- UniV2 invariant is well-documented in Uniswap V2 whitepaper §3.1 `k = x * y`
- `knowledge/vuln_db.md` Class-A (single-constant-typo)

---

## §2 ch2 Harvest Finance

### Incident
- rekt.news/harvest-finance-rekt
- Attacker tx: `0x35f8d2f572fceaac9288e5d462117850ef2694786992a8c3f6d02612277b0877` (mainnet)
- Attacker contract: `0xc6028a9fa486f52efd2c8b09fee3c6f32fd6fc7e`

### Patch / post-mortem
- Harvest's own post-mortem: https://medium.com/harvest-finance/harvest-flashloan-economic-attack-post-mortem-3cf900d65217
- Introduced `depositArbCheck` ±3% threshold — bypassed by iteration in the original attack and confirmed bypassable at our fork block per Attempt2

### Audit references
- Haechi Audit (Harvest core, pre-incident) — highlighted spot-price oracle risk in strategies, was ignored
- Curve yUSD pool audit by Trail of Bits (indirect — yUSD oracle quality limits)

### Pattern references
- `knowledge/vuln_db.md` Class-A (spot-price as share oracle + cumulative-threshold-bypass)

---

## §3 ch3 Fei-Rari (Rari Fuse)

### Incident
- rekt.news/fei-rari-rekt
- Attacker tx (mainnet): `0xab486012f21be741c9e674ffda227e30518e8a1e37a5f1d58d0b0d41f6e76530` (Rari Pool 8 drain)
- Cross-protocol dimension: Fei protocol PCV was insured, paid out victim deposits ($80M)

### Patch / post-mortem
- Rari team's post-mortem: https://medium.com/@raricapital (approximate)
- Compound V2 maintained a patched `CEther.doTransferOut` after this incident — their own CEther never had `call.value`, only Rari's fork did

### Audit references
- Rari Fuse audits: minimal public; the `call.value` modification was post-audit
- Compound V2 audits (OpenZeppelin, Trail of Bits) — inherited safety assumed, broken by the modification

### Pattern references
- `knowledge/vuln_db.md` Class-A (CEI violation + reentrancy via transfer→call substitution)
- Reentrancy canonical: Consensys Smart Contract Best Practices

---

## §4 ch4 Superfluid v1

### Incident
- rekt.news/superfluid-rekt
- Attacker tx (Polygon): `0xdee86cae2e1bab16496a49b2ec61aae0472a7ccf06f79744d42473e96edd6af6`

### Patch / post-mortem
- Superfluid team's patch commit (Patch 1): search `superfluid-finance/protocol-monorepo` for the ctx validation introduction
- Superfluid's incident report: https://medium.com/superfluid-blog (approximate)

### Audit references
- Certora formal verification (Superfluid-claimed): limited scope, didn't cover ABI trailing bytes
- Host's `_callExternalWithReplacedCtx` was NOT in the audit scope — post-audit infrastructure

### Pattern references
- `knowledge/vuln_db.md` Class-A (ABI trailing-bytes + missing ctx validation)
- Solidity ABI specification docs §4 (ABI encoding) — explicitly notes trailing bytes are ignored in decoding

---

## §5 ch5 Superfluid v2 (Patch 1 applied, Patch 2 absent)

This is the **mentor-flagged "creativity required" challenge**. External materials:

### Patch 2 commit (canonical diff)
- Superfluid monorepo commit hash: **`84f366b3d30d242d0a9173ced45b0db227222cb3`**
- URL: `https://github.com/superfluid-finance/protocol-monorepo/commit/84f366b3d30d242d0a9173ced45b0db227222cb3`
- This is the exact one-line fix: adds `AgreementLibrary.authorizeTokenAccess(token, ctx)` to `InstantDistributionAgreementV1.claim()`

### Patch 1 context
- The fix was INCOMPLETE — patch 1 added `authorizeTokenAccess` to most IDA entries but missed `claim()`
- ch5 = fork deployed at Patch-1 level (our attack surface)
- ch4 = fork deployed at pre-Patch-1 level (simpler exploit path, already solved)

### Fork-era IDA (unverified)
- Fork addr: `0x848497975f5757Aa1a48e13bbF46D330E62b19A7`
- 19 selectors, all subset of verified IDA per Attempt 13
- **Must disassemble via Heimdall** — use `sources/ch5_superfluid_v2/0x85eb.../src/.../InstantDistributionAgreementV1.sol` as the reference and find byte-level diffs

### SuperApp registration mechanics
- `Superfluid.registerApp(configWord)` — permission-gated on this fork. Reverted with "SF: app registration requires permission" per Attempt 1.
- `registerAppByFactory` — also gated. `registerAppWithKey` — rejects invalid keys per Attempt 2.
- **Historical SuperApps on fork**: 157 registered (Attempt 4 scan). 75 of those are IDA publishers with dormant indexes (Attempt 14 scan).

### Known dead-end vectors (DO NOT re-attempt)
Per existing `challenges/ch5_superfluid_v2/analysis.md` Dead Ends:
1. Subscriber-side SuperApp seeding (Attempts 1-5)
2. Plain callAgreement returned-ctx settlement theory (Attempt 6)
3. Forged msgSender for settlement (Attempt 7)
4. Batched claim + CFA operations (Attempt 8)
5. Direct appCallbackPush (Attempt 9)
6. mapAgreementClasses / revokeSubscription (Attempt 10)
7. Forged appCreditGranted/appCreditUsed/appAddress/appCreditToken survival through callback (Attempt 11 — Host overwrites these before callback fires)
8. Forged createIndex with live-SuperApp publisher (Attempt 12 — Patch 1 blocks)
9. Fork IDA hidden selectors (Attempt 13 — no hidden selectors exist)
10. Publisher-side zero-overlap (Attempt 14 — invalidated; 75 overlap exists)

### Live state for hypothesis generation (Attempt 14 findings)
- 75 SuperApps are IDA publishers on fork
- Most have `indexValue = 0` currently (dormant)
- Earliest recovered live app-publisher tuple: publisher `0x7e2e5f06e36da0ba58b08940a72fd6b68fbdfd61`, subscriber `0x3226c9eac0379f04ba2b1e1e1fcd52ac26309aea`, token/index `(0x27e1e4e6...,0)` and `(0x263026e7..., 1)` — both dry (indexValue=0)
- Need to find: SuperApps with HISTORICAL `IndexUpdated` events showing non-zero indexValue at some prior block, then either (a) trigger them to refresh, or (b) replay at a block where indexValue>0

### Unexplored surfaces (for new hypotheses)
- `SuperToken._move` internal — does it check msg.sender against IDA? What if a direct-on-SuperToken op is possible?
- `Host.batchCall` with op 201 + other ops — Attempt 8 tested [claim, createFlow] but not all op combinations
- SuperApp jail mechanics — the 18 jailed SuperApps may have different state; can we trigger un-jail?
- `callAppActionWithContext` vs `callAgreementWithContext` differ in ctx handling — one tested, the other?
- `CFA.deleteFlow` by a 3rd-party sender under SuperApp jail conditions — per Patch 1 this may be unguarded

### Discord / forum refs
- Superfluid Discord channel `#developer-discussion` — patch discussion around commit 84f366b3 date
- Search for phrases like "authorizeTokenAccess missing claim" on GitHub Issues for pre-disclosure awareness

---

## §6 General DeFi exploit references (apply to any challenge)

### Vuln databases
- `rekt.news/leaderboard/` — the master list of all DeFi hacks
- `defillama.com/hacks` — structured data
- `defiyield.app/rekt-database` — with post-mortems

### Audit firms (common to our challenges)
- Trail of Bits — Fei/Rari, Superfluid (partial)
- OpenZeppelin — Compound V2, forks
- Certora — Superfluid formal specs
- PeckShield — Harvest, Uranium (post-incident analysis only)
- Consensys Diligence — multiple

### Post-mortem archives
- `github.com/pcaversaccio/reentrancy-attacks` — canonical reentrancy pattern list
- `github.com/sushiswap/sushiswap/security` — UniV2 fork pitfalls

### Tools referenced throughout this repo
- **Heimdall** (`heimdall decompile <addr> --rpc-url <rpc>`) — go-to for unverified bytecode
- **Dedaub** (`app.dedaub.com/decompile`) — web UI alternative
- **Tenderly** (`tenderly.co`) — tx simulation + decoded trace
- **Phalcon** (BlockSec) — exploit tx analysis

---

## §7 Stash protocol (when WebFetch'ing external content)

When reading an external URL that might be useful across sessions, stash under `knowledge/external_content/<ch>/<slug>.md`:

```bash
mkdir -p knowledge/external_content/<ch>
# Use Claude's WebFetch tool (brain) or curl (if infrastructure)
# to save a Markdown-friendly version
```

Contents:
- URL + date fetched
- Original title
- Relevance to our challenge (1 paragraph)
- Full content (clean markdown if possible)

Brain should stash before analyzing so the content survives session compaction.

Do NOT stash paywalled or login-required content (rekt.news is open).
