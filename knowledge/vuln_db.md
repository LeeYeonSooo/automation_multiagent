# Vulnerability DB

이전 분석에서 정리한 **A(취약점) / B(방어) / C(약한방어) / D(비용)** 4-카테고리 분류. Claude의 가설 생성과 Codex의 PoC 작성에 모두 참조됨.

---

## 분류 기준

- **A. 실제 익스플로잇 가능한 취약점** — hunt 대상
- **B. 방어 메커니즘** — 발견되면 해당 벡터 포기 신호
- **C. 약한 방어** — 우회 가능. 우회 비용 계산 필요
- **D. 비용/손실 요인** — net 마이너스 가능성

---

## I. Harvest Finance — Oracle Manipulation

### A. 실제 취약점
1. **Share 발행/상환 분모에 manipulable한 값 사용** — `underlyingBalanceWithInvestment()`가 Curve pool 비율에 의존. 핵심.
2. **`balanceOf(address(this))` 기반 accounting** — spot balance를 share 계산에 직접 사용
3. **동일 트랜잭션 내 deposit+withdraw 허용** — cooldown/lock 없음
4. **Flash-scale 공격에 대한 자본 요구 부재**

### B. 방어 (있으면 이 벡터 포기)
- TWAP oracle (Uniswap V2 cumulativePrice 등)
- Chainlink / UMA push-based oracle
- Deposit/withdraw 간 block delay 또는 epoch lock
- `commitDeposit` + `executeDeposit` 2-step pattern
- 같은 block 내 deposit-withdraw 금지 플래그

### C. 약한 방어
- **±3% arbitrage check** — 단일 tx 내 단일 swap만 보기 때문에 임계 바로 아래 반복으로 우회. **실제 Harvest 공격의 정확한 bypass 방식**.
- **Deposit cap** — 총 cap이 있어도 iteration 가능하면 무용

### D. 비용 (반드시 계산)
- **Curve stableswap fee**: pool마다 다르지만 과거 yUSD pool은 약 0.04% per swap. pump + dump = 최소 0.08%
- **Flash loan fee**: dYdX 0%, Aave v2 0.09%, Maker DSS-Flash 0%
- **Slippage**: pool depth 대비 swap size가 클수록 2차 손실
- **Gas**: L1에서 iteration 하나당 수십만 gas
- **Iteration 횟수**: 너무 많이 돌리면 누적 fee가 share 이득 초과. optimal N 존재. binary search.

---

## II. Fei-Rari — Cross-function Reentrancy

### A. 실제 취약점
1. **CEI 위반** — `doTransferOut` → storage write 순서. 근본 원인.
2. **Cross-function nonReentrant 미적용** — `borrow`와 `exitMarket`이 별개 lock 또는 lock 없음
3. **Native ETH / callback token에 대한 reentrancy 가정 미검증** — fork 수정 시 재검토 안 함

### B. 방어
- 모든 상태변경 함수에 shared `nonReentrant` lock (global mutex)
- OZ `ReentrancyGuard` + transient storage
- CEI 엄격 준수 (storage → external call 순서)
- `.transfer()` 또는 `.send()` 사용 (2300 gas limit)
- callback 가능 토큰 whitelist (governance filter)

### C. 약한 방어
- **단일 함수 `nonReentrant`만 적용** — cross-function reentrancy에는 무력
- **Health check를 external call 이후에 수행** — 재진입 중 bypass 가능

### D. 비용
- Flash loan fee (150M USDC 규모면 0.09% = $135K)
- 담보 deposit 시 일시적 자본 lockup (flash loan으로 해결)
- **공격 전 bytecode/소스 확인 필수**: CEther의 `transfer` 버전이거나 nonReentrant 제대로 걸려 있으면 flash loan fee만 태우고 revert

---

## III. Superfluid v1 — Context Forgery via ABI Trailing Bytes

### A. 실제 취약점
1. **`authorizeTokenAccess`가 ctx 자체를 검증하지 않음** (Patch 1 이전). host만 확인.
2. **Agreement 함수 직접 호출 허용** — host를 경유했다는 런타임 체크 없음
3. **Trusted field(msgSender, appAllowance*)를 untrusted transport(calldata)로 전달**
4. **`_replacePlaceholderCtx`의 placeholder 판정이 길이만 봄** — 0-length placeholder 뒤에 fake ctx packed로 덧붙이면 호스트 ctx 교체 후에도 attacker ctx 잔존

### B. 방어 (Patch 1 / 2)
- 모든 agreement 함수 진입 시 `authorizeTokenAccess` + `isCtxValid` 강제
- `ctxStamp = keccak256(ctx)` 검증 (Patch 1)
- Host-only modifier
- Meta-tx면 EIP-712 서명 기반 sender 증명

### C. 약한 방어
- **Patch 1 자체가 불완전** — `authorizeTokenAccess` 추가했지만 `claim()` 등 일부 엔트리에 적용 안 됨. 이게 v2(ch5) 공격 지점.
- **msgSender만 묶고 나머지 필드는 방치** (Patch 1)

### D. 비용
- **거의 없음**. flash loan 불필요. gas만 듦.
- 단, 대상 victim 주소 선택이 중요. 큰 잔액 하나가 작은 잔액 여럿보다 ROI 높음.

---

## IV. Superfluid v2 (patched) — ctx Other-Fields

### A. 실제 취약점
1. **`claim()`에 `authorizeTokenAccess` 누락** (Patch 2 이전, ch5 환경)
2. **ctxStamp 검증 부재로 ctx 전 필드 spoofable**
3. **ctx의 trusted field(allowance, appAddress 등)를 downstream에서 re-derive 없이 사용**
4. **callback chain에서 SuperApp identity가 ctx 기반으로 결정됨**

### B. 방어 (Patch 2)
- `claim()`에도 `authorizeTokenAccess(token, ctx)` 한 줄 추가하면 이 벡터 사망

### C. 약한 방어
- 없음 (Patch 2 적용 후엔 v2 같은 공격 어렵)

### D. 비용
- 거의 없음
- 단 callback 구성을 위한 attacker SuperApp 컨트랙트 배포 비용

### 핵심 가설 (ch5용)
msgSender는 사용 시점에 덮어씌워져 무용. 대신 `appCreditGranted` / `appCreditUsed` / `appAddress` / `appCreditToken` 조작:
- appCreditGranted를 inflate → SuperApp이 callback 내에서 sub-operation으로 소비 가능한 한도 비정상 증가
- appAddress를 victim 주소로 위장 → 후속 권한 체크 오판
- appCreditToken을 다른 토큰으로 → allowance 대상 변조

claim() → `_loadAllData` → callback inputs (`callAppBeforeCallback` / `callAppAfterCallback`) 경로에서 attacker controlled SuperApp이 호스트에 sub-op 호출 → underlying 탈취

---

## V. Uranium Finance (ch1) — AMM K-invariant Wrong Constant

### A. 실제 취약점 (Immunefi 1차 출처 검증 기준)
1. **Swap 함수의 K-invariant 검증에서 LHS는 `balance*10000 - amount*16` 스케일(수수료 0.3%→0.16% 반영)로 업그레이드했지만 RHS는 `reserve² * 1000**2` 그대로 방치** — 원래라면 RHS도 `10000**2`로 같이 올렸어야 함. 결과적으로 LHS가 RHS보다 약 100배 커서 `>=` 체크가 trivially 통과 → invariant 100배 느슨
2. **결과**: dust input만으로도 풀의 양쪽 reserve 99%까지 출력으로 빼낼 수 있음

### B. 방어
- 정상 K-invariant: `(reserve0 - amount0In*fee_factor) * (reserve1 - amount1In*fee_factor) >= reserve0 * reserve1 * 1000^2`
- 컴파운드/표준 Uniswap V2는 정확히 1000^2

### C. 약한 방어
- 없음 (코드 상수 잘못이라 단순)

### D. 비용
- Flash loan fee만
- 한 트랜잭션에 다 빼낼 수 있어서 iteration 거의 불요

---

## VI. 횡단 패턴 (모든 챌린지 공통 체크)

### A 카테고리 (hunt 대상)
- Flash loan 미내성 경제 로직
- `balanceOf(this)` 기반 pricing
- External call 전 storage 미갱신
- Callback token + native ETH 담보 허용
- Trusted data in untrusted transport
- Fork + 수정 + 모델 재검토 없음
- 엔트리포인트 중 검증 루프에서 빠진 것 (Patch의 Patch 패턴)

### B 카테고리 (보면 포기)
- ReentrancyGuard / CEI 패턴
- Governance whitelist
- TWAP / Chainlink oracle

### C 카테고리 (재정리)
- Threshold-based guard (±X%)
- 단일 함수 nonReentrant
- Incomplete patch (방어 시도했으나 구멍)

---

## VII. 탐지 시그니처 (grep/AST 레벨)

### Oracle manipulation 의심
- `getPricePerFullShare`, `get_virtual_price`, `calc_withdraw_one_coin`, `getReserves` → `price` 변환
- `balanceOf(address(this))`를 pricing에 사용
- `IUniswapV2Pair`, `ICurvePool` view 함수를 share minting/burning에 사용

### Reentrancy 의심
- `.call{value:` / `.call.value(` after `require` but before storage write
- `accountBorrows[...] =` 라인이 external call 뒤에 오는지 diff 확인
- `nonReentrant`가 borrow/redeem/liquidate에만 있고 exitMarket/transfer에 없는 경우
- CEther / Native wrapper / WETH unwrap path
- ERC777/ERC1155 hook 토큰 사용

### Context/ABI forgery 의심
- `bytes ctx` / `bytes userData` 파라미터를 `msg.sender` 대신 사용
- `abi.decode`로 sender/principal 복원
- `encodeWithSelector` / `encodePacked`로 multi-hop dispatch하는 host/router
- `isCtxValid`, `ctxStamp`, `authorize*` 함수가 모든 entry point에서 호출되는지 diff

### AMM invariant 의심
- swap 함수에서 K-invariant 상수 (1000, 10000 등)
- Uniswap V2 fork에서 fee 계산 변경
