# PROGRESS.md

> 자동 갱신 파일. `tools/status.sh` 실행 시 갱신. 점수는 `actual_scores.json` (5분 자동 fetch) 신뢰.

**Last updated**: 2026-04-21T01:17:50Z
**Updated by**: tools/status.sh
**Scoreboard daemon**: **DOWN — restart needed**
**Scores last fetched**: 2026-04-21T00:19:13Z

---

## 챌린지별 상태 (실제 scoreboard 점수)

| ID | 이름 | State | Score (us) | Leader | Gap | Δ Native | 시도 |
|---|---|---|---|---|---|---|---|
| 1 | Uranium | `exploited` | 10000.0 | us (10000.0) | 0.0 | 10.0000 | 11 |
| 2 | Harvest | `exploited` | 5712.52 | d7c4d471236b... (10000.0) | 4287.48 | 16099.4317 | 71 |
| 3 | Fei-Rari | `exploited` | 3836.5 | f06ad1117aee... (10000.0) | 6163.5 | 10.0000 | 54 |
| 4 | Superfluid | `exploited` | 14985.29 | 3714e4401820... (15000.0) | 14.71 | 10.0000 | 28 |
| 5 | Superfluid v2 | `exploited` | 24241.52 | e449c8531708... (24310.04) | 68.52 | 10.0000 | 101 |

**Total**: us = **58775.83** | leader = **60997.78** | we_lead = **false** | gap_to_leader = **2221.95**

---

## 우선순위 큐

1. ch1 (Uranium) — 가장 단순. 워밍업.
2. ch3 (Fei-Rari) — 단일 tx reentrancy.
3. ch2 (Harvest) — oracle manip + 파라미터 튜닝.
4. ch4 (Superfluid v1) — ctx forgery.
5. ch5 (Superfluid v2) — patched, 가장 어려움.

---

## 최근 알림

- [2026-04-20T15:21:48Z] [info] ch1_uranium: Δ -113732.9302 native (실제 점수는 actual_scores.json 참고)
- [2026-04-20T15:21:49Z] [info] ch2_harvest: Δ -15842.5491 native (실제 점수는 actual_scores.json 참고)
- [2026-04-20T15:21:51Z] [info] ch3_feirari: Δ -7235.8505 native (실제 점수는 actual_scores.json 참고)
- [2026-04-20T15:21:55Z] [info] ch4_superfluid: Δ -4005714.2896 native (실제 점수는 actual_scores.json 참고)
- [2026-04-20T15:21:57Z] [info] ch5_superfluid_v2: Δ -930833.9127 native (실제 점수는 actual_scores.json 참고)
- [2026-04-20T16:22:18Z] [--warn] STUCK: ch2_harvest (60min no change). Trigger creative escalation.
- [2026-04-20T16:54:51Z] [--warn] Reset triggered: ch2
- [2026-04-20T17:02:28Z] [info] ch2_harvest: Δ -0.0246 native (실제 점수는 actual_scores.json 참고)
- [2026-04-20T17:07:30Z] [info] ch2_harvest: Δ +4363.4818 native (실제 점수는 actual_scores.json 참고)
- [2026-04-20T17:12:31Z] [info] ch2_harvest: Δ +11725.9745 native (실제 점수는 actual_scores.json 참고)

---

## 활성 챌린지 가설

**ch1_uranium**: From the clean block-6919826 baseline, replaying the validated 335-transaction Uranium bundle with EIP-1559 priorityFee=0 and maxFeePerGas raised to the live RPC quote still reproduces the large positive native delta from nonce 0 without needing any new exploit logic.

**ch2_harvest**: Attempt71: the currently exposed GOOD clean reset family still allows a reproducible positive replay with the proven peak-reset runner, but only to about 16.099k ETH; the archived 40k+ preserved family is not exposed on this endpoint today.

**ch3_feirari**: From the live post-replay head at block 14684704, the Saddle sUSD metapool remains mispriced for exactly three additional 1500000 DAI round-trips: buy sUSD on Curve, swap sUSD -> saddleUSD-V2 on Saddle, swap back to DAI, and convert the recovered DAI profit to ETH. After those three passes, the post-state no longer supports a profitable fourth pass even when the trade size is tuned down to 100000 and 5000 DAI.

**ch4_superfluid**: on a clean ch4 reset, the profitable full-drain path is the proven reset replay corpus (USDCx/DAIx/ETHx + live MATICx rows 1-800 + QIx + MOCAx + WORKx + the saved post-800 MATICx tail) through the existing helper source, followed by the fresh residual contract-holder sweep (USDCx top1/top2 + MATICx contract top1/top2) and then the full live STACKx holder drain on the same reset; on attempt 28 this sequence exceeded the prior max balance while the DAIx residual contract remained excluded because direct execute simulation still reverts with claim: !outputAccepted

**ch5_superfluid_v2**: The highest verified reset-head FakeHost replay is now the winning reproducible ch5 path: five profitable native helper rounds, the validated ERC20-backed stage table, a profitable QIx continuation, and SUSHIx quoted-dust cleanup until the live quote drops below margin. Attempt101 on a fresh reset-head improved the prior high-water mark, and the additional registered SuperToken scan found no extra claimable value beyond explicitly skipping RICx because its SuperToken reports no underlying token.


---

## 컨텍스트 압축 시 보존된 정보

(없음)
