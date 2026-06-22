# Scoring Model

## 공식
```
score = minmax_scale(log1p(scores), 0.01, 1) × max_pts
```

각 챌린지의 max_pts:
- Uranium / Harvest / Fei-Rari: 10,000
- Superfluid: 15,000
- Superfluid v2 (patched): 25,000
- **합계 70,000**

## 함의

### 1. log1p → 한계효용 급감
`log1p(x) = ln(1+x)`.
- x=1 → 0.69
- x=10 → 2.40
- x=100 → 4.62
- x=1000 → 6.91
- x=10000 → 9.21

수익이 100배 늘어도 raw score는 ~2배만 증가. **1자리수 늘리는 게 가장 ROI 큼.** 그 이상은 diminishing return.

### 2. minmax_scale → 상대평가
- min(=꼴등) = 0.01
- max(=1등) = 1.0
- 너가 1등이면 max_pts × 1.0 = 만점
- 너가 꼴등이면 max_pts × 0.01

**다른 팀이 너보다 1원이라도 더 짜면 너 점수 가파르게 깎임.**

### 3. 시간상 마지막 시점만 평가
멘토 명시: "결국 그냥 과제 끝나는 시점 점수 가장 좋다거든요."
중간 점수 의미 없음. 21일 23:59:59 시점만.

## 전략적 의미

### A. 챌린지 우선순위 (점수 ROI 기준)
1. **ch5 Superfluid v2 (25,000)** — 푼 사람이 거의 없으므로 풀기만 하면 1등 = 25,000 만점에 가까움
2. **ch4 Superfluid (15,000)** — 비교적 어려운 편이라 평균 수준만 해도 2~3등 가능
3. **ch1/2/3 (각 10,000)** — 모두가 풀 것. 1등 vs 꼴등 차이 = 9,900점

### B. 절대 수익을 짜내야 함
다른 팀이 0.5 ETH 짜낼 때 너가 0.6 ETH 짜내면 minmax에서 1등 = 만점.
극한 drain이 아니어도 "다른 모든 팀보다 약간 더"가 핵심.
→ Codex의 binary search/gradient 튜닝이 결정적

### C. 마감 직전 spurt
다른 팀들도 마감 직전에 점수 올림. 너도 마감 12시간 전부터 모든 챌린지 재튜닝.
Reset → 더 큰 수익 시도 → 잔액 누적.

### D. native token만 카운트
ERC20 잔뜩 들고 있어봤자 0점. 무조건 native(ETH/POL/BNB)로 변환해서 EOA 잔액에 쌓아야 함.
- WETH → unwrap
- USDC/USDT → swap to native (Uniswap/Curve/직접 swap)
- 수수료/슬리피지 손실 < 점수 이득 인지 확인

## Stuck 임계 계산
60분간 점수 변화 없으면 stuck. 이때 `creative_escalation` 발동.
하지만 이 60분도 너무 길 수 있음. 챌린지가 막힌 건지, 단순히 다른 팀이 안 움직여서 minmax가 변동 없는 건지 구분 필요.

추정 점수 계산 (poll_scoreboard.py 내부):
```
score = log1p(eth) / log1p(1000) × max_pts
```
실제 minmax는 다른 팀 데이터 없으면 추정 불가. 이 추정치는 단순 절대값 기반 휴리스틱.

## 시간 가치
4월 18일 ~ 21일 = 약 4일.
- ch1~3 첫 exploit: 18일 안에 끝내야 함 (Phase 1)
- ch4: 19일까지
- ch5: 20일~21일 집중
- 21일 오후: 모든 챌린지 점수 최적화 spurt
- 21일 저녁: 보고서 마감

## Reset 활용
Reset 가능하므로 한 번 짜낸 뒤 더 좋은 전략 떠오르면 reset 후 재시도 가능.
**단 reset하면 누적되지 않음** — 마지막 시점 잔액만 점수.
즉 reset 후 더 큰 잔액 만들 자신 있을 때만.

## 점수 곡선 시각화
```
score
  |
1 |        ____────
  |     __/
  |   _/
  | _/
  |/
0 +---------------> wei
  0   1e17  1e18  1e19
```
log1p이므로 초기 진입(0→non-zero)에서 가장 큰 점수 jump.
**0에서 0.001 ETH로만 가도 score 0.01→상당히 큼. 그 다음부터는 천천히.**
