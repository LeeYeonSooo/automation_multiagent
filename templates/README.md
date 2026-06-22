# templates/ — PoC skeletons for Assignment C

These files are consumed by `tools/delegate.sh` (see lines 72–90) when the brain
dispatches a `poc` task. Codex copies the relevant template into
`challenges/<ch>/poc/Attempt<N>.t.sol`, fills the `TODO[codex]:` markers from the
challenge `analysis.md`, and runs `forge test`.

## Files

| File | Purpose |
|---|---|
| `foundry.toml.template` | Common Foundry config + `[rpc_endpoints]` aliases (ch1..ch5) |
| `uranium.t.sol.template` | BSC Uranium V2 fork, broken-K AMM swap drain |
| `harvest.t.sol.template` | Ethereum Harvest fUSDT — UniV2 flash-swap + Curve pump/dump |
| `feirari.t.sol.template` | Ethereum Rari Fuse — Aave flashloan + cross-fn reentrancy via CEther |
| `superfluid.t.sol.template` | Polygon Superfluid v1 (ctx msgSender forgery) + v2 (other-field bypass) |
| `report.md.template` | 5-section exploit report skeleton (TL;DR, RCA, repro, failed attempts, patch) |

## How Codex uses them (copy-adapt pattern)

1. Read `challenges/<ch>/analysis.md` for hypothesis + pinned fork block.
2. `cp templates/<name>.t.sol.template challenges/<ch>/poc/Attempt<N>.t.sol`
3. Fill every `TODO[codex]:` block with concrete values (addresses, amounts, indices).
4. `forge test --match-path challenges/<ch>/poc/Attempt<N>.t.sol -vvv | tee challenges/<ch>/runs/attempt<N>.log`
5. Update `challenges/<ch>/status.json` and surface a 3-line summary per AGENTS.md §13.

Never overwrite previous attempts — number sequentially.

## remappings.txt guidance

Each `challenges/<ch>/` folder must have a `remappings.txt` with (at minimum):

```
forge-std/=lib/forge-std/src/
reference/=../../reference/
```

The `reference/` remap is mandatory for ch4/ch5 so `superfluid.t.sol.template`
can `import "reference/ContextUtils.sol";`. Challenges that don't use it can
drop the line.

## Per-challenge foundry.toml

Each challenge gets its own copy of `foundry.toml.template` at
`challenges/<ch>/foundry.toml`. Uncomment `fork_block_number` once recon pins
the block in that challenge's `analysis.md`.

## Convention reminders

- Every `.t.sol` ends with `assertGt(attacker.balance, balBefore, ...)` — the
  success gate per AGENTS.md §3.2.7.
- Every flashloan-based template includes the callback stub already
  (`uniswapV2Call`, `executeOperation`) so Codex only fills the body.
- The closing `@notice` NatSpec block describes the hypothesis under test —
  Codex rewrites it per attempt so run logs tie back to the specific theory.
