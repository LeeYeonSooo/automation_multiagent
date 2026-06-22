# Session Log: 2026-04-20 (22:07 KST start)

## Session Summary

### Scores at Start
| Challenge | Score | Max | Gap |
|-----------|-------|-----|-----|
| ch1_uranium | 10000.0 | 10000 | 0 |
| ch2_harvest | 8152.24 | 10000 | 1847.76 |
| ch3_feirari | 3781.87 | 10000 | 6218.13 |
| ch4_superfluid | 14985.29 | 15000 | 14.71 |
| ch5_superfluid_v2 | 24241.52 | 25000 | 758.48 |
| **TOTAL** | **61160.92** | **70000** | **8839.08** |

### Scores at Latest (scores dropped due to competitor improvements!)
| Challenge | Score | Max | Gap |
|-----------|-------|-----|-----|
| ch1_uranium | 10000.0 | 10000 | 0 |
| ch2_harvest | 5712.52 | 10000 | 4287.48 |
| ch3_feirari | 3670.32 | 10000 | 6329.68 |
| ch4_superfluid | 14985.29 | 15000 | 14.71 |
| ch5_superfluid_v2 | 24241.52 | 25000 | 68.52 |
| **TOTAL** | **58609.65** | **70000** | **11390.35** |

**Note**: Scores dropped because other competitors improved their raw balances, shifting the minmax scaling window.

---

## Key Discovery: Scoring Formula Insight

The scoring formula `minmax_scale(log1p(scores), 0.01, 1) * max_pts` includes a **seed score** per challenge to prevent extreme initial changes. Our raw balance didn't decrease, but competitors' improvements compress our relative score.

### Raw Score Comparison (from scoreboard API)
| Challenge | Our Raw | Leader Raw | Ratio |
|-----------|---------|------------|-------|
| ch1 (Uranium) | 113,742 BNB | us | 1.0 |
| ch2 (Harvest) | 46,243 ETH | 320,686 ETH | 0.14x |
| ch3 (Fei-Rari) | 6,982 ETH | 26,730 ETH | 0.26x |
| ch4 (Superfluid) | 4,005,724 MATIC | us (near max) | ~1.0 |
| ch5 (Superfluid v2) | 999,872 MATIC | 1,033,293 MATIC | 0.97x |

---

## Work Completed

### 1. Reports (All 5 Complete)
All reports updated with:
- Root Cause analysis
- Better Patch proposals (minimal fix + architectural defense-in-depth)
- Attack method description
- Profit maximization strategies
- Lessons learned (attacker/defender/auditor perspectives)

Files: `challenges/ch{1-5}/report.md`

### 2. ch2_harvest Analysis
- Reset + replay attempted multiple times
- Best result this session: 13,354 ETH (below historical max of 46,243 ETH)
- RPC timeout is the persistent blocker
- **Key finding**: Leader has 320K ETH, which is 7x more than Harvest Finance alone can provide
- Investigated additional protocols: CheeseBank (paused), OUSD (in progress), Value DeFi (low TVL)
- Codex delegation for multi-protocol investigation
- Optimized replay running with higher iteration counts (currently stuck on RPC timeout)

### 3. ch3_feirari Analysis
- Enumerated all 150+ Fuse pools on the fork (block 14684686)
- Found 24 pools with CEther > 0.01 ETH, total ~9K ETH
- **Key finding**: Leader has 26,730 ETH — matching the original Fei-Rari hack ($80M)
- Investigated two-phase drain (CErc20 stablecoin extraction via sequential borrow) — **confirmed dead end** (exitMarket error 14)
- Found Euler Finance on fork with ~18K ETH TVL, but `donateToReserves` not present at this block
- **Found Saddle Finance sUSDv2 exploit** yielding ~178K DAI profit
- Checked Compound V2 (946K ETH, no known vulnerability), CREAM (drained), Alpha Homora (drained)
- Multiple Codex delegations for Pool R4 investigation and alternative protocol exploits

### 4. ch5_superfluid_v2 Analysis
- Codex tune completed: no additional profitable SuperTokens found
- New competitor took the lead (24,310 vs our 24,241)
- 33K MATIC gap to reclaim lead
- No known path to improvement at this time

### 5. ch4_superfluid
- Near max (14,985/15,000), no action taken

---

## Active Background Tasks
1. **ch2 optimized replay** (PID 63606) — stuck on RPC timeout, retrying
2. **ch3 Saddle/Euler Codex** (PID 56040) — writing Pool R4 exploit + Saddle drain
3. **Scoreboard daemon** (PID 38004) — alive, polling every 5 minutes

---

## Dead Ends Confirmed This Session
1. ch3 two-phase drain (CErc20 stablecoin extraction via sequential borrow + reentrancy) — exitMarket returns error 14 even during CEther callback when CErc20 borrows exist
2. Euler Finance donateToReserves exploit — function not present at block 14684686
3. CheeseBank exploit on ch2 fork — mint is paused
4. CREAM/Alpha Homora on ch3 fork — already drained

---

## Remaining Opportunities
1. **ch2**: Find additional exploitable protocols on the Oct 2020 fork (OUSD, bZx variants, etc.)
2. **ch3**: Saddle Finance exploit in progress; oracle manipulation on Fuse pools; more CEther pools
3. **ch5**: Find 33K additional MATIC (currently unknown path)
4. **ch3**: Investigate if any Fuse pool uses ERC777 tokens enabling CErc20 reentrancy

---

## Session Update (14:30 KST)

### ch3 Saddle Finance Breakthrough
- **Saddle sUSD metapool exploit confirmed profitable**: 1.5M DAI round-trip yields ~178K DAI (~60 ETH)
- New ch3 historical max: **7,042 ETH** (from 6,982 → +60 ETH)
- ch3 score improved: **3,670 → 3,708** (+38 pts)
- Saddle continuation Codex running for additional round-trips
- Total score: **58,609 → 58,647** (+38 pts)

### Active Processes
1. ch3 Saddle continuation (PID 76009) — extracting more from metapool
2. Scoreboard daemon (PID 38004) — monitoring

### Key Insight: Saddle Finance sUSD Metapool
The Saddle Finance sUSD/saddleUSD-V2 metapool at block 14684686 still has exploitable reserves despite the April 28, 2022 hack. The exploit works by:
1. Self-fund DAI (from existing Fuse drain profits)
2. Buy sUSD with DAI on Curve 3pool
3. Swap sUSD → saddleUSD-V2 LP on Saddle MetaSwap (overpriced due to pool imbalance)
4. Swap saddleUSD-V2 → DAI back on Saddle (underpriced)
5. Profit: ~178K DAI per 1.5M round-trip
6. Convert DAI profit to ETH via Uniswap V2
