# Progress Report — 2026-04-18

**Total Score: 39,574 / ~70,000 (2위, gap ~1,275 to leader)**

---

## CH1 Uranium (BSC) — Score: 10,000 / 10,000

### Exploit: K-invariant 100x loose check
- **Root Cause**: Uniswap V2 fork에서 수수료를 0.3%→0.16%로 낮추려고 리팩토링하면서 **좌변**의 balance-adjusted 스케일을 `balance*1000 - amount*3` → `balance*10000 - amount*16`으로 업그레이드했지만, **우변** 상수 `reserve² × 1000**2`는 `10000**2`로 같이 바꾸지 않고 방치 → LHS가 RHS보다 약 100배 커져서 `>=` 체크가 trivially 통과, invariant 100배 느슨 (Immunefi 1차 출처 검증).
- **Attack**: 각 pair에 dust 1 wei input → reserve 99% output으로 swap 호출
- **Result**: 4개 WBNB pair drain → 39,011 BNB. 이후 추가 pair drain → 110,015 BNB 총 획득.
- **Attempts**: 2 (recon + exploit). 모두 성공.
- **Losses**: 없음.

---

## CH2 Harvest (Ethereum) — Score: 8,646 / 10,000

### Exploit: Curve oracle manipulation on fUSDT vault
- **Root Cause**: Harvest fUSDT vault의 share pricing이 Curve yUSD pool의 `calc_withdraw_one_coin` (spot price) 기반. Flash loan으로 Curve pool 비율 조작 가능.
- **Attack**: UniV2 nested flash-swap (50M USDT + 10M USDC) → Curve USDC→USDT pump → fUSDT.deposit → Curve dump → fUSDT.withdraw 반복.

### Attempt History
| # | Params | Result | Gain/Loss |
|---|--------|--------|-----------|
| 1 | 20M swap, Aave V2 | FAIL: calc_withdraw_one_coin revert | 0 (gas only) |
| 2 | 5M swap, Aave V2 | FAIL: Aave V2 not deployed at fork block | 0 |
| 3 | 10M swap, UniV2 flash, N=20 | PASS (fork test): 3,762 ETH | +3,762 ETH (test) |
| 4 | 10M swap, UniV2 flash, N=7/tx × 35 chunks | SUCCESS: broadcast | +15,036 ETH |
| 5 | 5M/3M/2M/1M sweep | FAIL: all configs revert (vault depleted) | -gas |
| 6 | dYdX SoloMargin flash (0 fee) | SUCCESS: 추가 drain | +2,940 ETH |
| 7 | Reset + re-exploit 10M/N=7 | SUCCESS: peak 경신 | +22,367 ETH (new peak) |
| 8+ | Various smaller params | Mixed: some gas loss | Net positive |

- **Peak Balance**: 22,367 ETH
- **Issues**: vault에 아직 ~80T USDT 남음. 10M swapSize 고갈 후 smaller sizes 시도했으나 marginal profit < gas cost.
- **Gap to leader**: 1,354점. Leader가 10,000점 달성 — 더 많은 ETH 필요.

---

## CH3 Fei-Rari (Ethereum) — Score: 8,430 / 10,000

### Exploit: Cross-function reentrancy via CEther doTransferOut
- **Root Cause**: Fei-Rari Fuse의 CEther가 `transfer()` (2300 gas) → `call.value()` (all gas)로 변경. borrowFresh의 CEI 위반 노출.
- **Attack**: Flash loan DAI → fDAI mint → enterMarkets → fETH.borrow → receive() { exitMarket } → redeem collateral.

### Attempt History
| # | Target Pool | Result | Gain |
|---|-------------|--------|------|
| 1 | Pool 8 (fETH) | SUCCESS | +664 ETH |
| 2 | Pool 36 (fETH-36, Fraximalist) | SUCCESS | +106 ETH |
| 3 | Pool 6, 7 | FAIL: borrowGuardianPaused | 0 |
| 4 | Kitchen Sink | SUCCESS | +1,927 ETH |
| 5 | Babylon's Gold | SUCCESS | +424 ETH |
| 6 | Olympus Pool Party | SUCCESS | +412 ETH |
| 7 | Harvest FARMstead | SUCCESS | +401 ETH |
| 8 | DeFiGeek Community | SUCCESS | +183 ETH |
| 9 | NFTX Pool | SUCCESS | +120 ETH |
| 10 | Pools 100-200 scan | 추가 발견하여 drain | +2,390 ETH |

- **Total**: 6,658 ETH across 10+ pools
- **Gap to leader**: 39점 — 거의 따라잡음!

---

## CH4 Superfluid v1 (Polygon) — Score: 12,234 / 15,000

### Exploit: Context forgery via ABI trailing bytes
- **Root Cause**: Host가 callData의 마지막 placeholder를 ctx로 교체. 공격자가 fake ctx를 실제 parameter 위치에, trailing placeholder를 뒤에 추가. IDA는 fake ctx를 읽고 host는 trailing placeholder를 교체.
- **Attack**: fakeCtx{msgSender=victim} → createIndex(victim as publisher) → updateSubscription(attacker as subscriber) → updateIndex → claim → downgrade → convert to native.

### Attempt History
| # | Approach | Result | Gain |
|---|----------|--------|------|
| 1-2 | forge test | FAIL: RPC timeout | 0 |
| 3 | forge script | FAIL: RPC timeout | 0 |
| 4 | cast send --create + execute | SUCCESS | +26,584 MATIC |
| 5 | Multi-victim batch (USDCx/DAIx/ETHx/WBTCx) | SUCCESS | +59,121 MATIC total |
| 6+ | Additional victims | SUCCESS | +210,991 MATIC total |

- **Peak Balance**: 210,991 MATIC
- **Issues**: RPC 매우 불안정 (자주 timeout/reset). cast send --create 방식으로 해결.
- **Gap to leader**: 487점.

---

## CH5 Superfluid v2 (Polygon, Patched) — Score: 250 / 25,000

### Status: 15 Attempts, Still Working

- **Root Cause (Theory)**: Patch-1이 authorizeTokenAccess에 isCtxValid 추가. 하지만 IDA.claim()은 authorizeTokenAccess를 호출하지 않음 → ctx 검증 우회 가능.
- **Blocker**: claim()의 forged ctx가 callback에 전달되지만, callback은 publisher가 등록된 SuperApp일 때만 발동.

### Dead Ends (14 attempts)
| # | Hypothesis | Result |
|---|-----------|--------|
| 1 | Direct claim with registerApp | FAIL: registerApp permission-gated |
| 2 | HOST-mediated claim | FAIL: no callbacks without SuperApp |
| 3 | Trailing bytes verification | Confirmed: forged ctx preserved in claim |
| 4 | SuperApp enumeration | Found 157 apps, none have IDA subs |
| 5 | Subscriber seeding (12 apps) | FAIL: no callbacks fire |
| 6 | Returned ctx settlement | FAIL: HOST echoes but doesn't settle |
| 7 | msgSender in claim settlement | FAIL: ignored |
| 8 | batchCall threading | FAIL: same fresh-ctx helper |
| 9 | appCallbackPush direct | FAIL: onlyAgreement gated |
| 10 | Deep source reading | Confirmed: no third agreement, all gated |
| 11 | Source code callback analysis | Confirmed: callback overwrites forged fields |
| 12 | createIndex forgery for SuperApp | FAIL: Patch-1 blocks |
| 13 | Fork IDA bytecode diff | FAIL: subset of public, no hidden selectors |
| 14 | SuperToken analysis | Debug: ctx doesn't affect settleBalance |

### Breakthrough (Attempt 15)
- **Found live publisher SuperApp**: `0xcaB28480ab5c1E133e9B7FC67E030B8DCC2A1d24` with MATICx index
- **Forged claim enters publisher callback with forged msgSender!**
- vm.etch POC confirmed concept works — 98,968 wei native recovered
- **Next**: Analyze real publisher app's callback code to find exploitable path WITHOUT vm.etch

---

## Losses Analysis

| Challenge | Total Gas Spent | Total Gained | Net |
|-----------|----------------|--------------|-----|
| ch1 | ~0.01 BNB | 110,015 BNB | +110,015 BNB |
| ch2 | ~5 ETH (gas + failed txs) | 22,367 ETH | +22,362 ETH |
| ch3 | ~2 ETH | 6,658 ETH | +6,656 ETH |
| ch4 | ~10 MATIC (gas) | 210,991 MATIC | +210,981 MATIC |
| ch5 | ~3 MATIC (gas + probing) | 0 | -3 MATIC |

**Overall: All profitable except ch5 (minimal gas loss). RPC resets cause temporary balance drops but scores preserve peak.**

---

## Next Steps (Priority)

1. **ch5 debug**: Publisher SuperApp callback 분석 → 실제 exploit 구현 (24,750점 잠재)
2. **ch2 tune**: vault 추가 drain with smaller swapSize
3. **ch4 re-exploit**: RPC reset 후 재실행
4. **ch3**: 추가 Fuse pool 스캔
