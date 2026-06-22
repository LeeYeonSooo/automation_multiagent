# Analysis: ch3_feirari

**Chain**: Ethereum (chain_id=1)
**Max points**: 10,000
**Difficulty**: Medium — single-tx cross-function reentrancy
**Native token**: ETH (payout target — borrowed ETH directly)
**Priority**: 2 (after ch1 — well-understood single-tx attack, no parameter tuning)

---

## Hypothesis

Rari Fuse is a Compound fork. In their `CEther` (ETH market), the `doTransferOut(to, amount)` internal function was changed from `to.transfer(amount)` (2300 gas, safe) to `(bool s,) = to.call.value(amount)("")` (forwards all gas). Combined with the standard Compound code order — `doTransferOut` called **before** `accountBorrows[borrower]` storage is written — this enables **cross-function reentrancy**:

1. Attacker deposits USDC/DAI as collateral, calls `borrow(X_ETH)` via `cEther`
2. `doTransferOut` forwards ETH to attacker contract → triggers `receive()` callback
3. Inside callback, storage still shows `accountBorrows[attacker] == 0` (borrow not yet recorded)
4. Attacker calls `comptroller.exitMarket(cUSDC)` — health check passes because borrow not yet recorded
5. Collateral is unlocked; attacker transfers it out
6. Callback returns; `borrow()` completes with stale storage (records borrow anyway)
7. Attacker retains collateral + borrowed ETH

Net result: attacker keeps ETH + original collateral, protocol has uncollateralized debt.

## Target Contracts

| Role | Address | Notes |
|---|---|---|
| Unitroller (Comptroller proxy) | `0xc54172e34046c1653d1920d40333Dd358c7a1aF4` | `enterMarkets` / `exitMarket` / `getAccountLiquidity` |
| fDAI | `0x7e9cE3CAa9910cc048590801e64174957Ed41d43` | collateral market — `mint(uint256)` to deposit |
| fETH (CEther) | `0xbB025D470162CC5eA24daF7d4566064EE7f5F111` | borrow market — `borrow(uint256)` triggers the bug |
| DAI | `0x6B175474E89094C44Da98b954EedeAC495271d0F` | collateral asset for flashloan + mint |
| Aave Lending Pool V2 | `0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9` | 150M DAI flashloan source (0.09%) |
| Balancer Vault | `0xBA12222222228d8Ba445958a75a0704d566BF2C8` | alternative 0%-fee flashloan source |
| WETH | `0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2` | not needed — attacker already holds ETH after callback |

Historical attacker contract (for bytecode reference only): `0x6162759edad730152f0df8115c698a42e666157f`. Attacker tx: `0xdee86cae2e1bab16496a49b2ec61aae0472a7ccf06f79744d42473e96edd6af6` (Polygon example — mainnet attack has separate hash, see rekt).

## Attack Chain

1. **Recon**
   - Confirm fork block has vulnerable `fETH` (bytecode: `doTransferOut` uses `call.value` not `transfer`)
   - `cast code $FETH --rpc-url $RPC_CH3_FEIRARI | head -c 200` — compare byte signatures against known-bad version
   - Check `comptroller.markets(fETH).isListed == true`
   - Confirm fETH has ≥ X ETH liquidity for the borrow

2. **Deploy attacker contract**
   - Extends `IERC3156FlashBorrower` or Aave callback interface
   - Has `receive() external payable` that executes the reentrant exitMarket + withdrawal
   - Has `enterMarkets` + `borrow` orchestration in main entry

3. **Execute single-tx attack**
   - Call `aave.flashLoan([DAI], [150_000_000e18], attacker, "", 0)`
   - Aave invokes `executeOperation(assets, amounts, premiums, initiator, params)`
   - Inside:
     - Approve fDAI to pull 150M DAI: `DAI.approve(fDAI, 150_000_000e18)`
     - Deposit: `fDAI.mint(150_000_000e18)`
     - Enter markets: `comptroller.enterMarkets([fDAI])`
     - Borrow: `fETH.borrow(1977e18)` — triggers `receive()` callback
     - In `receive()`:
       - `comptroller.exitMarket(fDAI)` — passes because accountBorrows still 0
       - `fDAI.redeem(shares)` or `redeemUnderlying(150_000_000e18)` — collateral back
     - `receive()` returns; borrow() finishes recording (futile — we already exited)
     - Repay flash: transfer 150M DAI + 0.09% fee back to Aave

4. **Final state**
   - Attacker holds 1977 ETH native
   - No collateral locked (exitMarket succeeded)
   - Flash repaid

5. **Native conversion**
   - ETH is already native — no conversion needed! (Advantage of this exploit)
   - Ensure attacker EOA, not a contract, holds final ETH
   - Or transfer from attacker contract to EOA at end of tx

6. **Score gate**
   - `cast balance 0xc943...` on ch3 RPC shows > initial (by ~1977 ETH minus flash fee in DAI equivalent)
   - Archive to `exploits/successful/Run_v<N>_reentrant_exit.s.sol`

## References

- Knowledge: `/Users/dldustn/Desktop/AssignmentC/knowledge/case_feirari.md`
- Skill: `/Users/dldustn/Desktop/AssignmentC/skills/exploit_feirari.skill.md`
- Skill: `/Users/dldustn/Desktop/AssignmentC/skills/flash_loan.skill.md` (Aave V2 section)
- Template: `/Users/dldustn/Desktop/AssignmentC/templates/feirari.t.sol.template`
- External: https://rekt.news/fei-rari-rekt/, Compound `CEther` patch commit in Compound monorepo

## Success Criterion

`cast balance $PUBLIC_ADDRESS --rpc-url $RPC_CH3_FEIRARI` strictly greater than fork-initial balance, ideally by ≥ 1000 ETH equivalent.

## Score Optimization Notes

- Single-tx attack; no iteration tuning
- Borrowed amount capped by fETH liquidity — check `fETH.getCash()` and scale borrow accordingly
- If fETH has > 10k ETH liquidity, scale up borrow (historical attack took 1977 ETH = $80M)
- Repeat across multiple Fuse pools if fork has several (Rari Fuse historically had ~20 pools; each uses its own Comptroller)
- Gas ~800k for the whole chain

## Dead Ends

## DEAD_END (exploit 2026-04-20, Pool 8 sequential stable-borrow before CEther callback)

Hypothesis: on the reset snapshot, Pool 8 would allow a two-phase extension of the proven CEther drain. We could borrow CErc20 stables in normal top-level calls first, then trigger the later `fETH-8` callback and still `exitMarket(fDAI-8)` because only the ETH borrow stayed stale during reentrancy.

Why it's wrong on the reset fork: the visible stable debts already block the collateral exit before any CEther callback matters. On the reset RPC (`chain_id=2401`, `block=14684686`), a probe that minted `150,000,000 DAI` into `fDAI-8`, then borrowed `1,000,000 FEI` and `1,000,000 LUSD` in normal top-level calls, hit `exitMarket(fDAI-8) == 14` both directly and during a later `fETH-8` callback. That means hiding only the ETH borrow is insufficient; Pool 8's comptroller still sees the pre-existing stable debt and rejects the collateral exit.

What we observed instead:
- PoC: `challenges/ch3_feirari/poc/Attempt52.t.sol`
- Evidence log: `challenges/ch3_feirari/runs/attempt52.log`
- Reset state confirmed `fETH-8.getCash() == 713.959880893796640440 ETH`
- After sequential `fFEI-8` and `fLUSD-8` borrows, `getAccountLiquidity` stayed positive (`42020711215958783009583`) while collateral remained entered
- A plain top-level `exitMarket(fDAI-8)` returned error code `14`
- A later `fETH-8.borrow(2 ETH)` still reentered successfully, but the callback `exitMarket(fDAI-8)` returned the same error code `14`
- `fFRAX-8` is not part of this live branch anyway because `borrowGuardianPaused(fFRAX-8) == true` on the reset snapshot

Suggested next direction: stop the Pool 8 sequential stable-borrow branch here. The proven 16-tx CEther replay remains valid on the reset fork, but the requested post-replay Pool 8 extension needs a different hypothesis than "borrow FEI/LUSD first, then hide only the CEther debt."

## DEAD_END (exploit 2026-04-20, Pool 8 callback multi-asset branch)

Hypothesis: even with `fETH-8` already reduced to `1 wei`, we could seed a little ETH into the native market, borrow just over the `1 ETH` minimum to trigger `receive()`, then use that callback to borrow `fFEI` / `fFRAX` / `fDAI` / `fLUSD` before exiting `fDAI-8` and redeeming the collateral.

Why it's wrong on the current fork: Pool 8's comptroller blocks that cross-asset callback path before any CErc20 debt is created. Reentering from `fETH.borrow()` into `fFEI.borrow()` hits `Comptroller._beforeNonReentrant()` and reverts with `re-entered across assets`, so the multi-asset branch never reaches the proposed "borrow stables, then exit collateral" stage.

What we observed instead:
- PoC: `challenges/ch3_feirari/poc/Attempt46.t.sol`
- Evidence log: `challenges/ch3_feirari/runs/attempt46.log`
- Live fork context stayed `chain_id=2401`, `block=14684704`.
- After seeding `fETH-8` from `1 wei` to `2000000000000000001 wei`, a borrow of `1000000000000000001 wei` still triggered the callback as expected.
- Inside the callback, a low-level `fFEI.borrow(1_000_000e18)` call returned `false` with revert reason `re-entered across assets`.
- `fFEI.borrowBalanceStored(address(this))` remained `0`, proving no CErc20 debt was created during the callback.
- `exitMarket(fDAI-8)` still returned `0` once the blocked CErc20 borrow was skipped, so the original single-market stale-ETH exit still exists but the requested multi-asset extension does not.

Suggested next direction: stop the Pool 8 stable-borrow branch here. Any further work should start from a different post-reset surface, not from "borrow CErc20 markets inside the CEther callback" on this comptroller path.

## DEAD_END (exploit 2026-04-20, Nomad zero-root replay)

Hypothesis: the Nomad branch on this fork could be drained by crafting fresh `BridgeMessage` transfers for the escrowed `WETH`, `USDC`, `DAI`, `WBTC`, `USDT`, and `FRAX`, then calling `Replica.process(message)` directly because `confirmAt[bytes32(0)] == 1` makes the zero root acceptable.

Why it's wrong on the live fork: `Replica.process(bytes)` still requires `messages[keccak256(message)] == MessageStatus.Proven` before it dispatches to the bridge router. On the current `RPC_CH3_FEIRARI` snapshot (`chain_id=2401`, `block=14684704`), the zero root is acceptable, but the historical successful Nomad message hashes are not present in `Replica.messages`, so replaying a real hacked message reverts with `!proven`. Historical `proveAndProcess` calldata from the 2022 exploit also does not help here: reconstructing one of those proofs yields a non-zero branch root that is not acceptable on this challenge fork.

What we observed instead:
- `Replica.confirmAt(0x00) == 1` and `Replica.acceptableRoot(0x00) == true`.
- `Replica.messages(<historical successful message hash>) == 0` for multiple real Nomad hack messages recovered from Etherscan.
- A direct call to `Replica.process(message)` with a historically successful bridge message reverts `!proven` on the live fork.
- The reconstructed historical proof root for a real `proveAndProcess` sample was `0x02cd3839600cdec91ee7a6a52adaf7d4f666448ae6a2b23df06a87104484ff95`, and `Replica.acceptableRoot(root)` returned `false`.
- Evidence log: `challenges/ch3_feirari/runs/exploit_1776664695.log`

Suggested next direction: stop this branch and revisit the Nomad hypothesis only if we can identify a live path to mark a fresh crafted message as `Proven` against an actually acceptable root on this fork. Without that missing prove step, overwriting the existing exploit runner would just burn attempts.

## DEAD_END (tune 2026-04-18, Tetranode pools)

Hypothesis: the same DAI-flashloan reentrancy could extend to other Tetranode pools, specifically `f6-ETH` on `0x814b02C1ebc9164972D888495927fe1697F0Fb4c` and `fETH-7` on `0xFB558eCD2D24886e8d2956775C619deb22f154EF`.

Why it's wrong: both native markets still have cash, but `borrowGuardianPaused(address)` is `true` on the live fork for both markets. A live `cast send` execute attempt against `f6-ETH` failed during gas estimation with `execution reverted: borrow is paused`, so this branch is not broadcastable.

What we observed instead:
- `f6-ETH` cash remained `1790.747145744033915079 ETH`, but borrowing is paused.
- `fETH-7` cash remained `9.042499242392467715 ETH`, but borrowing is paused.
- `fETH-36` in Fraximalist Money Market (`0x93de950f609F51b1fF0C5bf81d8588fBAdDe7d5C`) had `108.070790240136260138 ETH` cash with `borrowGuardianPaused=false` and `mintGuardianPaused(fFRAX-36)=false`.

Suggested next direction: self-fund collateral from the scored EOA, swap `ETH -> DAI -> FRAX`, mint `fFRAX-36`, borrow `fETH-36`, exit `fFRAX-36` during reentrancy, then unwind `FRAX -> DAI -> ETH`.

## DEAD_END (tune 2026-04-18, R4 Community pool)

Hypothesis: `Rari DAO Fuse Pool R4 (Community)` at pool index `3` should accept the same self-funded DAI collateral reentrancy used elsewhere, because `fr4ETH` still had `44.445382607103835535 ETH` cash, `borrowGuardianPaused(fr4ETH)=false`, and `fr4DAI` remained mintable with `collateralFactor=0.75e18`.

Why it's wrong: the borrow callback still fired, but `exitMarket(fr4DAI)` returned comptroller error code `14` during the reentrant window instead of `0`. That means this pool's comptroller path rejects the stale-borrow exit even though the CEther transfer remains reentrant, so the standard unlock-and-redeem path is not live-broadcastable here.

What we observed instead:
- Dry-run log: `challenges/ch3_feirari/runs/exploit_dryrun_1776485452.log`
- `REENTRANT_ETH_RECEIVED = 43.445382607103835535 ETH`
- `REENTRANT_EXIT_CODE = 14`
- The CEther borrow reverted upward as `doTransferOut failed`, leaving the pool undrained.
- Post-checks showed `fr4ETH.getCash()` still unchanged at `44.445382607103835535 ETH`.

Suggested next direction: treat pool `3` as a pool-specific comptroller dead end for the vanilla `exitMarket` reentrancy and continue draining the remaining pools whose reentrant exit still returns `0`, especially stable-backed leftovers in pool `79` and pool `27`, plus non-stable branches such as `Tribe ETH Pool`.

## Tune Outcome (2026-04-18)

Executed the Fraximalist pivot live:
- Bought `360,000 DAI` with `140 ETH` max funding on Uniswap V2.
- Swapped `360,000 DAI -> 359,864.492608085495054713 FRAX` on Curve FRAX3CRV.
- Minted `fFRAX-36`, borrowed `107.070790240136260138 ETH` from `fETH-36`, reentered `exitMarket(fFRAX-36)`, redeemed collateral, and unwound back to ETH.
- Post-run `fETH-36.getCash()` is exactly `1 ETH`.
- Scored EOA native balance is now `780.499458422016546843 ETH`.
- Net increase versus the pre-run live balance was `106.082334442050088728 ETH`.

## Tune Outcome (2026-04-18, multi-pool DAI recycle)

Enumerated `FusePoolDirectory` on the live fork and confirmed `184` public Fuse pools. The profitable follow-up set was not the already-paused Tetranode branches, but a group of additional unpaused CEther markets that also exposed mintable DAI collateral markets.

Executed live with a new `FeiRariAttack` contract at `0xe41b9be07c2c2c8991ff986bc507dd17659be683`, reusing the same `150,000,000 DAI` Aave V2 flash loan across six separate comptrollers:

- `0xb1's Kitchen Sink`: `+1926.889360233651877868 ETH`
- `Babylon's Gold Lender`: `+423.781446850396144315 ETH`
- `Olympus Pool Party`: `+411.756557630344256006 ETH`
- `Harvest FARMstead`: `+400.765552476551051501 ETH`
- `DeFiGeek Community Pool`: `+183.386455939853265055 ETH`
- `NFTX Pool`: `+120.459458082800736201 ETH`

Post-run state:

- Scored EOA native balance is now `4247.500421274300879213 ETH`.
- Net increase versus the pre-run live balance was `3467.000962852284332370 ETH`.
- Run log: `challenges/ch3_feirari/runs/exploit_1776484819.log`

## BONUS

The directory sweep also surfaced additional unpaused CEther pools beyond the six DAI-backed targets above, including `Tribe ETH Pool` with `2392.401126398370465747 ETH` cash. The largest remaining branch is not a simple DAI/USDC/FRAX recycle: `Tribe ETH Pool` exposes `stETH` / `wstETH` collateral markets rather than a stablecoin market, so it needs a different collateral sourcing path than the multi-pool DAI flash-loan exploit used here.

## Tune Outcome (2026-04-18, self-funded pool79+27 recycle)

Finished the stable-backed follow-up sweep of pools `0-100`:
- Pool `3` (`Rari DAO Fuse Pool R4 (Community)`) remained funded but dead-ended with `exitMarket` error code `14`.
- Pool `79` (`Fox and Frens`) remained live with `6.011989215198676562 ETH` cash and a mintable `fDAI-79` market.
- Pool `27` (`Stake DAO Pool`) remained live with `11.997207155715863871 ETH` cash and a mintable `fFRAX-27` market.

Executed live with the updated `Run.s.sol` using self-funded stable collateral from the scored EOA:
- Bought `300,000 DAI` with up to `140 ETH` on Uniswap V2.
- Reused that DAI against `fDAI-79`, borrowed `5.011989215198676562 ETH`, reentered `exitMarket(fDAI-79)`, and redeemed the DAI.
- Swapped the recovered DAI into `299,891.521063759021344111 FRAX` on Curve.
- Minted `fFRAX-27`, borrowed `10.997207155715863871 ETH`, reentered `exitMarket(fFRAX-27)`, redeemed the FRAX, swapped back to DAI, and unwound to native ETH.

Post-run state:
- `fETH-79.getCash()` is now exactly `1 ETH`.
- `fETH-27.getCash()` is now exactly `1 ETH`.
- Scored EOA native balance via `cast balance` is now `4262574336494159325224 wei` (`4262.574336494159325224 ETH`).
- Net increase versus the pre-run live balance was `15073915219858446011 wei` (`15.073915219858446011 ETH`).
- Live run log: `challenges/ch3_feirari/runs/exploit_1776485650.log`

## Tune Outcome (2026-04-18, leftover stable-backed mask 125)

Follow-up tuning against the remaining candidate pools found one more live stable-backed sweep, but not the full seven-pool mask.

- `Olympus Pool Party`, `Harvest FARMstead`, `NFTX Pool`, `Fox and Frens`, `Stake DAO Pool`, and `Fraximalist Money Market` all remained live and broadcastable under the same self-funded stable-collateral pattern.
- `Badger Pool` still exposed unpaused `fETH` cash (`1.283883491718825466 ETH`), but the reentrant callback returned `exitMarket` error code `14`, so it had to be excluded from the final live mask.
- `Tribe ETH Pool` in the `100-200` scan remained the largest untouched branch with `2392.401126398370465747 ETH` cash, but its live collateral side is `stETH` / `wstETH`, not DAI/FRAX, so it is not reachable with the current stable-backed runner.

Broadcast details:

- Dry-run-safe pool mask: `125`
- Deploy tx: `0x1946ec0a67df053de87889c769d409d0316517f52f9d3e35fb7c7199582b865c`
- Execute tx: `0x09189c9a80019480dd698788a90107423694e38537beb7e168018a5509f80102`
- Live run log: `challenges/ch3_feirari/runs/exploit_1776490287.log`

Post-run state:

- Scored EOA native balance via `cast balance` is now `4268371376053838034480 wei` (`4268.371376053838034480 ETH`).
- Net increase versus the pre-run live balance was `5797039559678709256 wei` (`5.797039559678709256 ETH`).
- Cumulative increase versus the original `10 ETH` starting balance is now `4258371376053838034480 wei`.

## Hypothesis Tree (Smoke Test)

Smoke-test note: this pass is analysis-only by design. No new `.t.sol` or broadcast was written in this turn. As of `actual_scores.json:24-30`, `ch3_feirari` remains at `7860.3` against a leader score of `8468.52`, so the remaining tree focuses on fresh drain surface rather than re-proving pool `8`.

### HypA — Tribe ETH Pool via stETH/wstETH collateral

- **Why (prior evidence)**: The archived vulnerable Fuse bundle still exposes the full primitive: `CEther.doTransferOut` forwards all gas via `to.call.value(amount)("")` (`sources/ch3_feirari/0xe16db319d9da7ce40b666dd2e365a4b8b3c18217_unitroller_proxy_fuser1pool8_comptroller_impl/src/CEther.sol:136-139`), `borrowFresh` performs `doTransferOut` before recording `accountBorrows` (`sources/ch3_feirari/0xe16db319d9da7ce40b666dd2e365a4b8b3c18217_unitroller_proxy_fuser1pool8_comptroller_impl/src/CToken.sol:767-817`), and `exitMarket` only blocks if `amountOwed != 0` or `redeemAllowedInternal != 0` (`sources/ch3_feirari/0xe16db319d9da7ce40b666dd2e365a4b8b3c18217_unitroller_proxy_fuser1pool8_comptroller_impl/src/Comptroller.sol:172-186`). Mentor hint `§4.2` says unpaused cEther-equivalent pools beyond the original pool should be drained (`knowledge/mentor_hints.md:122-128`). The current sweep already identified `Tribe ETH Pool` as the largest untouched branch with `2392.401126398370465747 ETH` cash and `borrowPaused=false`, but with `stETH` / `wstETH` rather than stable collateral (`challenges/ch3_feirari/runs/scan_141_160_1776489449.log:32-40`, `challenges/ch3_feirari/analysis.md:159-161`, `challenges/ch3_feirari/analysis.md:187-189`).
- **Expected outcome on success**: Self-fund ETH into `stETH` or `wstETH`, mint the matching collateral market in pool `146`, call `enterMarkets`, borrow from `fETH-146`, reenter `exitMarket` during the ETH callback, redeem the `stETH` / `wstETH` collateral, convert back to ETH, and push the scored EOA materially closer to the leader.
- **Expected revert pattern on failure**: `exitMarket` returns non-zero code `14` from `redeemAllowedInternal` (`Comptroller.sol:184-186`), the borrow path returns `TOKEN_INSUFFICIENT_CASH` if the scan is stale (`CToken.sol:767-771`), or the branch fails operationally because the chosen collateral market is not mintable or unwinds poorly on the fork.
- **Single-line test plan**: Add pool `146` plus one `stETH` / `wstETH` collateral market to the existing runner, self-fund a small collateral amount, borrow `1-5 ETH`, and log `REENTRANT_EXIT_CODE` plus post-borrow `getCash()`.
- **Three-axis tag**:
  - code-level: CEI violation
  - logic-level: cross-function reentrancy
  - known-pattern: `knowledge/vuln_db.md:44-65,170-173`; `knowledge/mentor_hints.md:122-128`
  - Prior: `3/3` matches, highest upside

### HypB — Tribe Convex Pool stable-backed reuse

- **Why (prior evidence)**: The same source-archive primitive remains applicable (`sources/ch3_feirari/0xe16db319d9da7ce40b666dd2e365a4b8b3c18217_unitroller_proxy_fuser1pool8_comptroller_impl/src/CEther.sol:136-139`, `sources/ch3_feirari/0xe16db319d9da7ce40b666dd2e365a4b8b3c18217_unitroller_proxy_fuser1pool8_comptroller_impl/src/CToken.sol:767-817`, `sources/ch3_feirari/0xe16db319d9da7ce40b666dd2e365a4b8b3c18217_unitroller_proxy_fuser1pool8_comptroller_impl/src/Comptroller.sol:172-186`), and the generic collateral leg is still just `mint()` / `redeem()` on an ERC20 cToken (`sources/ch3_feirari/0xe16db319d9da7ce40b666dd2e365a4b8b3c18217_unitroller_proxy_fuser1pool8_comptroller_impl/src/CErc20.sol:43-72`). The scan surfaced `Tribe Convex Pool` as a fresh stable-backed comptroller: `fETH-156` has `1.2 ETH` cash, `borrowPaused=false`, and the same pool exposes mintable `fFRAX-156`, `fDAI-156`, and `fUSDC-156` markets with `collateralFactor=0.8e18` (`challenges/ch3_feirari/runs/scan_141_160_1776489449.log:41-77`).
- **Expected outcome on success**: Reuse the already-working self-funded stable runner almost unchanged: buy FRAX or USDC, mint `fFRAX-156` or `fUSDC-156`, borrow `fETH-156`, exit during callback, redeem collateral, unwind back to native ETH, and remove the last untouched stable-backed CEther branch in the `141-160` range.
- **Expected revert pattern on failure**: `exitMarket` returns code `14` on this comptroller just like pool `3` / pool `22`, or `doTransferOut failed` bubbles up if the borrow callback cannot complete. A stale cash read would instead fail at `TOKEN_INSUFFICIENT_CASH` (`CToken.sol:767-771`).
- **Single-line test plan**: Extend the current `Run.s.sol` scanner config with pool `156`, use `fFRAX-156` as collateral, and dry-run a `1 ETH` borrow while logging the callback exit code.
- **Three-axis tag**:
  - code-level: CEI violation
  - logic-level: cross-function reentrancy
  - known-pattern: `knowledge/vuln_db.md:44-65,170-173`; `knowledge/mentor_hints.md:122-128`
  - Prior: `3/3` matches, highest prior to implement first because the stable-backed runner already exists

### HypC — Exact-cash residue sweep on previously live pools

- **Why (prior evidence)**: The same archived borrow path only rejects when `cashPrior < borrowAmount`, not when `cashPrior == borrowAmount` (`sources/ch3_feirari/0xe16db319d9da7ce40b666dd2e365a4b8b3c18217_unitroller_proxy_fuser1pool8_comptroller_impl/src/CToken.sol:767-772`), and still writes debt after `doTransferOut` (`sources/ch3_feirari/0xe16db319d9da7ce40b666dd2e365a4b8b3c18217_unitroller_proxy_fuser1pool8_comptroller_impl/src/CToken.sol:812-817`). Multiple proven-good pools were intentionally left at exactly `1 ETH` cash after prior successful broadcasts, including `fETH-36`, `fETH-79`, and `fETH-27` (`challenges/ch3_feirari/analysis.md:132-138`, `challenges/ch3_feirari/analysis.md:170-180`). This makes "borrow the final exact cash unit" a distinct cleanup hypothesis rather than a replay of the earlier `cash-1` safety margin.
- **Expected outcome on success**: Re-run the already-successful pool masks against only the previously live pools, but borrow exact `getCash()` instead of `getCash()-1`, driving the residual `1 ETH` balances to zero and reclaiming the remaining dust from already-proven comptrollers.
- **Expected revert pattern on failure**: `TOKEN_INSUFFICIENT_CASH` or `doTransferOut failed` if exact-cash borrowing leaves no slack for internal accounting, or `exitMarket` returns code `14` on the known excluded pools such as pool `3` / pool `22`.
- **Single-line test plan**: Dry-run a one-pool variant against a previously successful branch such as pool `79` with `borrowAmount = nativeMarket.getCash()` and compare `REENTRANT_EXIT_CODE` plus final `getCash()`.
- **Three-axis tag**:
  - code-level: CEI violation
  - logic-level: state-machine ordering bug
  - known-pattern: `knowledge/vuln_db.md:44-65,170-173`
  - Prior: `3/3` matches, cleanup branch after fresh pools are exhausted

Smoke-test implementation order for the next real debug or PoC task: `HypB -> HypA -> HypC`. `HypB` is the cleanest protocol check because it reuses the existing FRAX/USDC collateral runner on a new comptroller, `HypA` is the high-upside branch once that generalization is reconfirmed, and `HypC` is boundary cleanup after new pools are exhausted.

## Hypothesis Tree (Attempt 6)

Tune note: this attempt is the first post-mask-125 production pass. The stable-backed leftovers in pools `24`, `27`, `31`, and `79` now mostly sit at `1 ETH` cash, while the only materially funded untouched branch is still `Tribe ETH Pool` (`fETH-146`) with `2392.401126398370465747 ETH` cash plus mintable `fstETH-146` / `fWSTETH-146` collateral markets.

### HypA — Pool 146 via direct stETH collateral

- **Why (prior evidence)**: The archived Fuse source still exposes the same borrow-before-accounting window: `CEther.doTransferOut` forwards all gas via `to.call.value(amount)("")` (`sources/ch3_feirari/0xe16db319d9da7ce40b666dd2e365a4b8b3c18217_unitroller_proxy_fuser1pool8_comptroller_impl/src/CEther.sol:136-139`), `borrowFresh` transfers out before recording `accountBorrows` in the vulnerable bundle (`sources/ch3_feirari/0xe16db319d9da7ce40b666dd2e365a4b8b3c18217_unitroller_proxy_fuser1pool8_comptroller_impl/src/CToken.sol:806-817`), and `exitMarket` only rejects on non-zero `amountOwed` / failed `redeemAllowedInternal` (`sources/ch3_feirari/0xe16db319d9da7ce40b666dd2e365a4b8b3c18217_unitroller_proxy_fuser1pool8_comptroller_impl/src/Comptroller.sol:172-186`). Mentor hint `§4.2` says to enumerate and drain every unpaused CEther-equivalent pool, not just the original DAI-backed set (`knowledge/mentor_hints.md:135-141`). On the live fork during this tune pass, direct `cast call` checks confirmed that `fETH-146` still has `2392.401126398370465747 ETH` cash with `borrowGuardianPaused=false`, while `fstETH-146` is listed with `collateralFactor=0.8e18` and `mintGuardianPaused=false`.
- **Expected outcome on success**: Send self-funded ETH to Lido `submit()`, mint `fstETH-146`, enter the market, borrow essentially all `fETH-146` cash, reenter `exitMarket(fstETH-146)` during the ETH callback, redeem the stETH collateral, swap stETH back to native ETH on Curve stETH/ETH, and forward the enlarged ETH balance to the scored EOA.
- **Expected revert pattern on failure**: `exitMarket` returns comptroller error code `14` from `redeemAllowedInternal`, `borrow()` returns a comptroller rejection if the stETH oracle haircut makes the LTV insufficient, or the Curve unwind misses its `minDy` guard.
- **Single-line test plan**: Extend `Run.s.sol` with a dedicated pool `146` stETH path using Lido + Curve, dry-run with ~`3500 ETH` self-funded collateral, and log the reentrant exit code plus final owner delta.
- **Three-axis tag**:
  - code-level: CEI violation
  - logic-level: cross-function reentrancy
  - known-pattern: `knowledge/vuln_db.md:44-65`; `knowledge/mentor_hints.md:135-141`
  - Prior: `3/3` matches → implement first

## DEAD_END (debug 2026-04-19, stale task-input replay plan)

Hypothesis: the current `$RPC_CH3_FEIRARI` still matched the handoff note "student at ~2389 ETH, only pool 146 drained", so the next action should be to broadcast `runExactLeftovers()`, then the cleanup sweep, then `runPool182Seeded()`.

Why it's wrong: the live fork state is already much later than that note. A fresh Attempt2 check on the current RPC at block `14684686` showed:
- student EOA balance `6662709731430291358815 wei` (`6662.709731430291358815 ETH`)
- `fETH-146.getCash() == 1`
- `fETH-8.getCash() == 1000000000000000000` (`1 ETH`)
- `fETH-182.getCash() == 0`

That means the requested follow-up steps are stale on the current RPC: pool 146 is already dusted out, pool 8 is already dust-only, and pool 182 has already been fully cleared. Broadcasting the originally requested sequence would be debugging the wrong state.

Artifacts:
- PoC: `challenges/ch3_feirari/poc/Attempt2.t.sol`
- Log: `challenges/ch3_feirari/runs/attempt2.log`

Suggested next direction: rescan the current live fork from scratch and build a new target list from the remaining non-dust unpaused CEther branches, instead of replaying the older "post-pool146 only" sequence.

## DEAD_END (exploit 2026-04-18, pool72 same-market ETH and directory extension)

Hypothesis: the current live fork still hid a profitable branch outside the previously assumed `0-184` Fuse range. Fresh directory enumeration on the live fork showed pools continuing through `198`, and `troopersGarage` (pool `72`) still had `73.740282143822284630 ETH` sitting in `fETH-72`. Because every non-ETH market in pool `72` had `collateralFactor = 0`, the new idea was to self-fund `150 ETH`, mint `fETH-72`, enter that same market, borrow the pre-existing `73.740282143822284629 ETH`, then reenter `exitMarket(fETH-72)` during the CEther callback and redeem the original ETH collateral afterward.

Why it's wrong:
- The directory extension was real, but not profitable: on the live fork at block `14684700`, pools `184-198` existed, yet the only CEther markets in that range with any listing were `fETH-185` and `fETH-189`, both with `getCash() = 0`. No unpaused funded CEther target exists in `184-198`.
- Pool `72` does reenter, but the same-market unlock fails. The dry-run log `challenges/ch3_feirari/runs/exploit_pool72_dryrun_1776521757.log` shows `REENTRANT_ETH_RECEIVED = 73.740282143822284629 ETH`, then `comptroller.exitMarket(fETH-72)` reverts inside the callback and the borrow bubbles up as `doTransferOut failed`.
- Live market dump for pool `72` confirmed the structural limitation: `fFOREX-72`, `fFEI-72`, `ffxEUR-72`, and `ffxAUD-72` all have `collateralFactor = 0`, leaving no alternate collateral market to unlock during the callback.

Suggested next direction: none on the current non-reset fork. The live fork now appears exhausted for broadcastable CEther drains: stable-backed leftovers are already at `0` or `1 wei`, pool `182` still sits below its effective borrow floor, pool `166` remains whitelist-blocked, pools `184-198` have no funded CEther cash, and the only fresh funded branch (`72`) dead-ends on same-market reentrancy.

### HypB — Pool 146 via wstETH wrapper path

- **Why (prior evidence)**: The exploit primitive is identical to HypA (`CEther.sol:136-139`, `CToken.sol:755-817`, `Comptroller.sol:172-186`), but pool `146` also exposes a second listed LST collateral market, `fWSTETH-146`, with the same `0.8e18` collateral factor and `mintGuardianPaused=false`. That creates a backup route if `fstETH-146` behaves awkwardly on mint/redeem, or if using wrapped shares avoids a token-specific transfer quirk.
- **Expected outcome on success**: Submit ETH to Lido for stETH, wrap to wstETH, mint `fWSTETH-146`, borrow `fETH-146`, reenter `exitMarket(fWSTETH-146)`, redeem, unwrap back to stETH, swap to ETH on Curve, and forward the native profit.
- **Expected revert pattern on failure**: wrap/unwrap path fails due to allowance or share math, `exitMarket` returns code `14`, or the borrow path rejects because the wstETH oracle valuation is lower than assumed.
- **Single-line test plan**: Keep the same pool `146` runner but swap the collateral leg from `fstETH-146` to `fWSTETH-146`, then compare callback exit code and final owner delta against HypA.
- **Three-axis tag**:
  - code-level: CEI violation
  - logic-level: cross-function reentrancy
  - known-pattern: `knowledge/vuln_db.md:44-65`; `knowledge/mentor_hints.md:135-141`
  - Prior: `3/3` matches → backup with same upside

### HypC — Pool 156 and exact-cash residue cleanup

- **Why (prior evidence)**: The same borrow window remains present in the archived source (`CEther.sol:136-139`, `CToken.sol:755-817`, `Comptroller.sol:172-186`). The live fork still shows `fETH-156` with `1.2 ETH` cash and mintable `fFRAX-156` / `fUSDC-156` collateral at `0.8e18`, while the earlier re-checks of pools `24`, `27`, `31`, and `79` show that the previously drained stable-backed branches now mostly hold only exact-cash residue. This is a valid cleanup vector, but its upside is measured in single ETH rather than thousands.
- **Expected outcome on success**: Reuse the existing stable-backed runner for `fFRAX-156` or exact-cash one-pool sweeps, picking up the remaining `1.2 ETH` at pool `156` and possibly the exact `1 ETH` residues on already-proven comptrollers.
- **Expected revert pattern on failure**: `exitMarket` returns code `14` on the new comptroller, or exact-cash borrowing causes `doTransferOut failed` / `TOKEN_INSUFFICIENT_CASH` at the boundary.
- **Single-line test plan**: After pool `146`, optionally dry-run a tiny FRAX-backed branch for pool `156` or exact-cash borrow on one previously successful `1 ETH` pool.
- **Three-axis tag**:
  - code-level: CEI violation
  - logic-level: state-machine ordering bug
  - known-pattern: `knowledge/vuln_db.md:44-65`; `knowledge/mentor_hints.md:135-141`
  - Prior: `3/3` matches → cleanup only after HypA/HypB

## Tune Outcome (2026-04-18, Tribe ETH Pool stETH sweep)

Executed the high-upside `HypA` branch against `Tribe ETH Pool` (`pool 146`) on the live fork:

- Dry-run log: `challenges/ch3_feirari/runs/exploit_tribe146_dryrun_1776494410.log`
- First broadcast attempt with `--unlocked --sender` failed at the RPC transport layer, not the exploit layer: the node rejected `eth_sendTransaction` with `PermissionError` (`challenges/ch3_feirari/runs/exploit_1776494471.log`).
- Successful fallback broadcast used the same `Run.s.sol` path with a signed sender (`challenges/ch3_feirari/runs/exploit_1776494546.log`).

Live execution details:

- Deployed `TribeStEthAttack` at `0x47de59cd7cc91d83151c760f5dd88f201fa1f754`
- Deploy tx: `0x52e05e204bf1505e00e2e62d7d824ac7785ec503003b94c07657426c74777c62`
- Execute tx: `0xde56dbb1c54501bdcfc9de18342be848f07695f9b2e1fad805d475c3f986fd45`
- Sent `3500 ETH` into Lido, minted `3271.849475694663645047 stETH`, supplied it to `fstETH-146`, borrowed `2392.401126398370465746 ETH`, reentered `exitMarket(fstETH-146)` with callback code `0`, redeemed the stETH collateral, and unwound `3499.999999999999999997 stETH` into `3497.195540032188222510 ETH` on Curve.

Post-run state:

- Scored EOA native balance via `cast balance` is now `6657952342928434307212 wei` (`6657.952342928434307212 ETH`).
- Net increase versus the pre-run live balance was `2389580966874596272732 wei` (`2389.580966874596272732 ETH`).
- This exceeds the previous best live balance by `2389580966874596272732 wei`, clearing the requested success criterion.

## Open Questions for Codex

1. Which Fuse pools exist on the fork? Enumerate via `FusePoolDirectory` if deployed, else via Unitroller factory events.
2. Is `exitMarket` reachable while a borrow is mid-tx? Some Fuse pool forks added their own `nonReentrant` — verify on recon.
3. If the single-pool attack caps at borrowable ETH, is there a way to drain multiple pools within one flashloan (sequential enterMarkets across pools)?

## DEAD_END (2026-04-18, current live fork after historical max)

Hypothesis: the current live fork still had meaningful residual ETH in `Tribe ETH Pool` (`pool 146`), or at least another small broadcastable CEther branch that could be added on top of the existing `6935 ETH` score without resetting.

Why it's wrong on the actual live snapshot:

- At `2026-04-18T14:09:18Z`, live block `14684700`, `fETH-146.getCash()` returned exactly `1` wei. Pool `146` is already drained on the current fork, so there is no "larger flash loan" or "more iterations" path left there without resetting.
- The remaining live CEther balances on the same block were only:
  - `pool 166 / fETH-166`: `0.1 ETH`
  - `pool 173 / fETH-173`: `0.000495644543367033 ETH`
  - `pool 182 / fETH-182`: `0.25 ETH`
  - `pools 146, 156, 164, 177`: `1 wei` each
  - `pools 102, 127, 144`: `0`
- A dedicated dry-run against `Radicle Pool` (`pool 166`) with self-funded RAD collateral failed before borrow:
  - Log: `challenges/ch3_feirari/runs/radicle166_dryrun_1776520646.log`
  - `mintAllowed(fRAD-166, student, 82 RAD)` returned `18`
  - Direct live checks showed `enforceWhitelist = true` and `whitelist(student) = false` on the pool comptroller, so the student EOA cannot mint the collateral market needed for the reentrancy path.
- `The Bank Vault` (`pool 182`) was rechecked against the prior dry-run and remains blocked operationally:
  - Live `fETH-182.getCash()` is only `0.25 ETH`
  - The prior dry-run (`challenges/ch3_feirari/runs/cleanup_pool182_dryrun_1776514655.log`) still fails as `native borrow failed`, because the pool's internal borrow floor exceeds the remaining cash.

Conclusion: on the current non-reset fork, there is no remaining broadcastable profit source. Any further gain requires either a new hypothesis or a reset to an earlier snapshot, which was explicitly disallowed for this task.

## NEW HYPOTHESIS: Euler Finance donateToReserves Exploit (2026-04-20)

### 1. 취약점 코드 경로
- Euler Main Proxy: `0x27182842E098f60e3D576794A5bFFb0777E025d3`
- eWETH: `0x1b808F49ADD4b8C6b5117d9681cF7312Fcf0dC1D` (4,882 ETH available)
- eUSDC: `0xEb91861f8A4e1C12333F42DCE8fB0Ecdc28dA716` (30.75M USDC available in Euler)
- eDAI: look up via markets proxy `0xf43ce1d09050BAfd6980dD43Cde2aB9F18C85b34`
- Liquidation module proxy: `0x7123C8cBBD76c5C7fCC9f7150f23179bec0bA341`
- Exec module proxy: `0x59828FdF7ee634AaaD3f58B19fDBa3b03E2D9d80`
- Aave V2 Lending Pool: `0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9` (flash loan source)

**Vulnerability**: `EToken.donateToReserves(uint256 subAccountId, uint256 amount)` moves eTokens from user's balance to protocol reserves WITHOUT checking if the user's health factor drops below 1. This allows creating an underwater position that can be self-liquidated.

At fork block 14684686 (April 30, 2022), Euler V1 has NOT been patched. The actual hack occurred March 13, 2023 (block ~16818000). The vulnerability exists in the original codebase.

### 2. 왜 exploitable한가
- `donateToReserves()` decreases the user's eToken balance (collateral) but does NOT decrease dToken balance (debt)
- After donation, user's health factor < 1.0 (underwater)
- Liquidation module allows any account to liquidate underwater positions
- Attacker controls both the borrower (sub-account 0) and liquidator (sub-account 1)
- Liquidator receives eTokens at a discount, effectively draining the pool

### 3. 공격 단계
**For each market (WETH, DAI, USDC, WBTC, USDT):**

1. Flash loan seed capital from Aave V2:
   - WETH: flash 30K WETH → wrap ETH or use directly
   - DAI: flash 30M DAI
   - USDC: flash 50M USDC

2. Sub-account 0 (victim position):
   a. `eToken.deposit(subAccountId=0, amount=20K)` → deposit into Euler
   b. `markets.enterMarket(subAccountId=0, underlying)` → enable as collateral
   c. `eToken.mint(subAccountId=0, amount=195K)` → self-borrow (lever up 10x)
   d. Use remaining capital to `eToken.repay(subAccountId=0, amount=10K)` → reduce debt
   e. `eToken.mint(subAccountId=0, amount=195K)` → lever up again
   f. `eToken.donateToReserves(subAccountId=0, amount=X)` → donate enough to go underwater

3. Sub-account 1 (liquidator):
   a. `liquidation.liquidate(violator=sub0, underlying=WETH, collateral=WETH, repay=maxUint, minYield=0)`
   b. `eToken.withdraw(subAccountId=1, amount=maxUint)` → withdraw all underlying

4. Convert all drained tokens to native ETH:
   - USDC/DAI/USDT → WETH via UniV2 Router
   - WBTC → WETH via UniV2
   - WETH.withdraw() → ETH
   - Transfer to scored EOA

5. Repay Aave flash loan

### 4. Available targets on fork

| Market | Euler Balance | eToken Address | Est. ETH Gain |
|--------|-------------|----------------|---------------|
| WETH | 4,882 ETH | 0x1b808F49ADD4b8C6b5117d9681cF7312Fcf0dC1D | ~4,800 |
| USDC | 30.75M USDC | 0xEb91861f8A4e1C12333F42DCE8fB0Ecdc28dA716 | ~10,600 |
| DAI | 5.26M DAI | (lookup via markets proxy) | ~1,800 |
| WBTC | 210.93 WBTC | (lookup via markets proxy) | ~2,700 |
| USDT | 3.33M USDT | (lookup via markets proxy) | ~1,100 |
| **Total** | | | **~21,000** |

### 5. 제약 조건
- Aave V2 flash loan: 0.09% fee (negligible)
- Gas: Euler liquidation is gas-heavy (~5M+ per tx). May need multiple txs.
- The Euler exploit uses sub-accounts (same address, different account IDs). All operations are from the attacker contract.
- Key: Euler sub-account ID = (accountAddress << 8) | subAccountId. Sub-account 0 and 1 are both under the attacker contract.

### 6. 성공 판정
- `cast balance $PUBLIC_ADDRESS --rpc-url $RPC_CH3_FEIRARI` increases by ~21,000+ ETH
- Current balance: ~6,979 ETH → target: ~28,000 ETH

### 7. 참조
- Actual Euler hack tx: 0xc310a0affe2169d1f6feec1c63dbc7f7c62a887fa48795d327d4d2da2d6b111d
- Euler V1 source: modules/EToken.sol, modules/Liquidation.sol
- donateToReserves: EToken.sol line ~230 (no health check after donation)

## NEW HYPOTHESIS: Nomad Bridge process() Exploit (2026-04-20)

### 1. 취약점
- Nomad Replica: `0x5BAe47bF29F4E9B1E275C0b427B84C4DaA30033A` (Evmos domain)
- ERC20 Bridge: `0x88A69B4E698A4B090DF6CF5Bd7B2D47325Ad30A3`
- XAppConnectionManager: `0xFe8874778f946Ac2990A29eba3CFd50760593B2F`
- **confirmAt[0x00] = 1** → zero root accepted as valid
- Any message with root=0x00 passes verification in `Replica.process()`

### 2. Bridge assets (drainable)
| Token | Balance | ETH equiv |
|-------|---------|-----------|
| WETH | 2,217 ETH | 2,217 |
| USDC | 28.6M | ~9,900 |
| DAI | 2.89M | ~1,000 |
| WBTC | 59.01 BTC | ~800 |
| USDT | 6.79M | ~2,340 |
| FRAX | 14.02M | ~4,830 |
| **Total** | | **~21,087** |

### 3. 공격 단계
1. Craft a Nomad message for each token:
   - type: TokenTransfer
   - origin domain: 1702260083 (Evmos)
   - destination domain: 6648936 (Ethereum)
   - recipient: our address
   - amount: full bridge balance
2. Call `Replica.process(message)` for each
3. The Replica verifies the message root against confirmAt[root] → confirmAt[0x00]=1 → passes
4. Bridge releases tokens to us
5. Convert all to ETH via UniV2

### 4. Message format
Nomad message = header + body
- header: nonce(4) + origin(4) + sender(32) + destination(4) + recipient(32) + body
- The message needs to be properly formatted for the Nomad protocol
- The key is setting the root in the proof to 0x00

### 5. 성공 판정
Combined with existing Fuse drain (7K ETH) + Nomad (~21K ETH) = ~28K ETH → match leader

## NEW HYPOTHESIS: Iron Bank via Alpha Homora V2 Credit Limit (2026-04-20)

### Key Discovery
- Alpha Homora V2 (0xba5eBAf3fc1Fcca67147050Bf80462393814E54B) has 23,000 ETH credit limit on Iron Bank
- Currently borrowed: ~7,412 ETH → **15,588 ETH available**
- Iron Bank cyWETH (0x41c84c0e2EE0b740Cf0d31F63f3B6F627DC6b393) has 14,743 ETH cash
- Whitelisted SushiSwap spell: 0xdc9c7a2bae15dd89271ae5701a6f4db147baa44c
  - Function: addLiquidityWMasterChef(address,address,(uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256),uint256)
  - Router: 0xd9e1cE17f2641f24aE83637ab66a2cca9C378B9F (SushiSwap)
  - Factory: 0xC0AEe478e3658e2610c5F7A4A2E1777cE9e4f2Ac

### Attack Vector
1. Create leveraged position via Alpha Homora using SushiSwap spell
2. Borrow maximum ETH from Iron Bank via credit limit
3. Manipulate SushiSwap pool to make borrowed ETH extractable
4. Or: find accounting bug in position closure that leaves excess ETH

### Verified Addresses
- Iron Bank Comptroller: 0xAB1c342C7bf5Ec5F02ADEA1c2270670bCa144CbB
- Iron Bank Oracle: 0xE4e9F6cfe8aC8C75A3dBeF809dbe4fc40e6FDc4b
- cyWETH collateral factor: 85%
- Alpha governor: 0xB593d82d53e2c187dc49673709a6E9f806cdC835

## DEAD_END (exploit 2026-04-20, Alpha Homora V2 / Iron Bank credit-line extraction)

Hypothesis: use Alpha Homora V2's whitelisted Sushi spell to borrow large WETH against Iron Bank, then redirect the borrowed ETH back to the executor through the spell flow while still passing the bank's post-execution safety check.

Why it's wrong on the live fork: the verified `HomoraBank` implementation records debt before it transfers borrowed tokens to the spell, and `execute()` re-checks `collateralValue >= borrowValue` after the spell returns. The Sushi spell does refund leftover WETH by unwrapping it and sending native ETH to `EXECUTOR()`, but that refund is only whatever tiny WETH dust remains after the spell rebalances and adds liquidity. Attempting to amplify that refund by over-borrowing WETH just reverts at the final `insufficient collateral` check.

What we observed instead:
- Reference tx `0x512e73e95f1b10303cfb9e67c827f4f45122d9781e8d197f9c0a8021380651c1` decodes as `execute(2965, spell, addLiquidityWMasterChef(USDC, WETH, (0,0,0,43865594218,0,0,49758528118,17717236964622002288), 1))` with `20 ETH` user input; it borrows USDC, not WETH.
- A local fork trace of that reference tx shows the spell flow is: borrow/transmit -> swap -> add liquidity -> take old collateral -> unwrap/re-wrap `WMasterChef` -> `putCollateral` -> unwrap leftover WETH -> send ETH to `EXECUTOR()` -> transfer harvested SUSHI to `EXECUTOR()`.
- `WMasterChef.getUnderlyingRate()` is constant `2**112`, so the wrapper does not count pending SUSHI rewards in the collateral rate.
- New PoC `poc/Attempt41.t.sol` on the live challenge block (`14684704`) opened a fresh position with `100,000 USDC` user collateral and a `10 WETH` borrow. The spell refunded exactly `0 wei` of ETH to the executor, while the resulting position remained safe with `borrowValue = 12.616 ETH` and `collateralValue = 35.908 ETH`.
- The same PoC then tried to borrow `1,000 WETH` against the same `100,000 USDC` user collateral and reverted with `insufficient collateral`.
- Evidence log: `challenges/ch3_feirari/runs/attempt41.log`

Suggested next direction: stop this branch. Any live exploit now needs a different Alpha/Iron Bank bug than "refund borrowed ETH through addLiquidityWMasterChef", because that path is bounded by the final Homora safety check on the current fork.

## DEAD_END (exploit 2026-04-20, Iron Bank donation / Alpha follow-up on live snapshot)

Hypothesis: the user-requested Cream / Iron Bank donation family was still live on this fork. The plan was to use a low-float collateral market to inflate collateral value by donating underlying directly into the market, then borrow against the inflated position and drain `iWETH`. When the low-float donation route failed, the fallback was Alpha Homora's 23k ETH Iron Bank credit line.

Why it's wrong on the live fork:
- Every low-float `cy*` market that would make the classical donation path viable is `mintGuardianPaused == true` on the live comptroller, including `cyCDAI`, `cyCUSDC`, `cyCUSDT`, `cyY3CRV`, `cySUSD`, `cyMUSD`, `cyDUSD`, `cyBUSD`, and `cyCREAM`.
- The unpaused low-float `i*` markets (`iMIM`, `iLINK`, `iYFI`, `iSNX`, `iDPI`, `iUNI`, `iSUSHI`, `iAAVE`, `iCRV`, `iCVX`, plus the synthetic fiat markets) all sit on the same delegate implementation `0x432979A3f808B6CfcA2d393206378EA5b39E33E5`, and direct underlying transfers into those markets do not update `getCash()`, `exchangeRateCurrent()`, or account liquidity on this fork.
- The whitelisted Alpha Homora Sushi path is live but not exploitable through simple credit-line extraction: a conservative position opens normally and returns `0` extra WETH / USDC to the executor, while larger borrow sizes still revert with `insufficient collateral`.

What we observed instead:
- `poc/Attempt41.t.sol` / `runs/attempt41.log`: `cyCDAI.mint()` reverts `mint is paused` on the live fork.
- `poc/Attempt42.t.sol` / `runs/attempt42.log`: the real `DAI -> Curve MIM -> iMIM -> borrow DAI -> Curve MIM -> donate` flow succeeds up to the donation, but `iMIM.getCash()`, `exchangeRateStored()`, and `getAccountLiquidity()` remain unchanged after the direct MIM transfer.
- `poc/Attempt44.t.sol` / `runs/attempt44.log`: the same non-crediting behavior reproduces on a standard ERC20 market. After minting `iLINK`, a direct transfer of `100,000 LINK` into `iLINK` leaves `getCash()`, `exchangeRateCurrent()`, and account liquidity flat.
- `poc/Attempt43.t.sol` / `runs/attempt43.log`: a moderate Alpha Homora borrow (`100 WETH` user input, `500 WETH + 1.4M USDC` requested borrow) reverts with `insufficient collateral`.
- `poc/Attempt45.t.sol` / `runs/attempt45.log`: a conservative Alpha Homora borrow (`100 WETH` user input, `20 WETH + 56,000 USDC` borrow) succeeds as a normal position with `collateralValue = 110.610840461008714290 ETH`, `borrowValue = 46.058496982720272052 ETH`, and `STUDENT_WETH_DELTA = 0`, `STUDENT_USDC_DELTA = 0`.

Suggested next direction: stop the Iron Bank branch on this snapshot. The requested donation attack is not broadcastable with the live market configuration, and the simple Alpha Homora credit-line extraction path is behaving like a normal leverage primitive rather than an exploit.

## DEAD_END (poc 2026-04-20, Alpha Homora WETH-only open/close + callback surfaces)

Hypothesis: one of the remaining Alpha Homora Sushi spell branches could still leak borrowed WETH to the executor on the live reset snapshot, either by borrowing only WETH and exploiting the swap path, by closing the position and extracting the borrowed side on unwind, by routing execution through a contract callback, or by supplying a fake callback token as one side of the pair.

Why it's wrong on the live fork: the WETH-only borrow path behaves like a normal leveraged LP open, not an extraction primitive. The spell swaps borrowed WETH into USDC to form the Sushi LP, leaves the executor with no meaningful WETH / USDC at open, and on close repays the debt before returning the remaining native ETH and leftover USDC to the EOA. The surrounding callback surfaces are also shut: `HomoraBank.execute()` still enforces `onlyEOA`, and a freshly created WETH/fake-token Sushi pair is not cached or whitelisted by the spell.

What we observed instead:
- New PoC: `challenges/ch3_feirari/poc/Attempt9.t.sol`
- Evidence log: `challenges/ch3_feirari/runs/attempt9.log`
- The current reset RPC served `chain_id=2401` and `block=14684702` during this run, not `14684704`.
- Opening a new WETH/USDC MasterChef position with `30 WETH` user input and `10 WETH` borrowed (`amtBBorrow = 0`) emitted exactly one Sushi pair swap, pushing `20024006277033191259 wei` of WETH into the swap and receiving `56436486778` USDC out.
- Immediately after open, the executor EOA held `0` WETH and `0` USDC, while the position carried only one debt token: `WETH` for `10000000000000000001 wei`.
- A normal `removeLiquidityWMasterChef` close succeeded without fallback, leaving `borrowValue = 0`, `collateralValue = 0`, `collateralSize = 0`, and returning assets to the EOA as `9975987006160279888 wei` additional native ETH plus `56436486777` USDC leftover.
- Calling `execute()` through a helper contract reverted `not eoa`, confirming the requested contract-callback surface is blocked at the bank entrypoint.
- Creating a fresh Sushi WETH/fake-token pair on the live factory produced a real pair address, but `spell.pairs(fake, WETH) == address(0)` and `spell.whitelistedLpTokens(pair) == false`, so the fake-token callback idea cannot reach the whitelisted spell path.

Suggested next direction: stop the Alpha Homora / Iron Bank branch on this snapshot. The requested WETH-only open, close/unwind, contract-callback, and fake-token branches all behave like bounded, non-extractive flows rather than an exploit path.
