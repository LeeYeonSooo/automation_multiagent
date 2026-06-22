# Analysis: ch6_superfluid_v21 (rw6) — Superfluid v2.1

## Fork 상태
- IDA impl: `0x848497975f5757aa1a48e13bbf46d330e62b19a7` (Patch 1 only, claim에 authorizeTokenAccess 없음)
- Host impl: `0x513b7c5c6b7d8b21a14d6d5536878fb0a803bef4` (Patch 1 — isCtxValid 검증 있음)
- rw5와 동일한 컨트랙트

## 핵심 취약점

### IDA.claim() — authorizeTokenAccess 누락
- Patch 1: `authorizeTokenAccess`에 `isCtxValid(ctx)` 검증 추가
- 하지만 `claim()`은 `authorizeTokenAccess`를 호출하지 않음 (Patch 2에서 수정)
- 따라서 claim()에 임의의 forged ctx 주입 가능

### 공격 벡터: Context Forgery via Trailing Bytes Trick
Host.callAgreement() → _replacePlaceholderCtx() → IDA function

1. 공격자가 callData를 구성: `abi.encodeWithSelector(claim.selector, ..., forgedCtx) ++ uint256(0)`
2. Host가 _replacePlaceholderCtx로 마지막 placeholder(0)를 실제 ctx로 교체
3. claim()은 ABI decoder가 읽는 forgedCtx를 사용 (trailing bytes인 실제 ctx는 무시)
4. forgedCtx의 keccak256 ≠ _ctxStamp → 하지만 claim은 isCtxValid 안 함!

### Forged Context의 활용
- `appCallbackPush(forgedCtx, app, ...)` 에서 forgedCtx decode → re-stamp
- 이제 forged ctx가 유효한 stamp를 가짐
- SuperApp callback에서 이 유효한 ctx로 `host.callAgreementWithContext()` 호출 가능

### 기존 FakeHost 접근 vs 정석 접근

**FakeHost (non-intended)**:
- IDA.claim()을 직접 호출 (Host 우회)
- FakeHost가 ISuperfluid 인터페이스 구현
- callAppBeforeCallback에서 re-entry → 증폭

**정석 (intended — ctx forgery via Host)**:
- Host.callAgreement()을 통해 claim() 호출
- Trailing bytes trick으로 forged ctx 주입
- SuperApp callback에서 callAgreementWithContext로 후속 작업
- msgSender는 일시적으로 SuperApp으로 덮어씌워지지만, oldSender로 보존/복원

## 핵심 발견: beforeAgreementUpdated는 staticcall

Host._callCallback에서:
- beforeAgreementUpdated → staticcall (상태 변경 불가)
- afterAgreementUpdated → call (상태 변경 가능)

이 때문에 FakeHost의 before callback 재진입 패턴은 real Host에서 불가능.

## 진행 중인 가설

### Hypothesis 1: afterCallback에서 updateIndex + claim 루프
afterAgreementUpdated에서 updateIndex로 indexValue 증가 → claim으로 추가 수금
문제: updateIndex에 isAccountCriticalNow 솔벤시 체크 → 잔액 초과 불가

### Hypothesis 2: 기존 on-chain subscription 활용
Fork 상태의 기존 publisher-subscriber pair에서 미수금 claim 수행
문제: subscriber가 공격자가 아님

### Hypothesis 3: Forged msgSender를 통한 권한 승계
Callback ctx의 forged msgSender가 callAgreementWithContext에서 oldSender로 보존
이 forged identity가 어딘가에서 유의미한 권한 차이를 만드는지 조사 필요

## 실제 Superfluid 해킹 사건 (2022-02-08)

1차 공격 (Patch 1 전): ctx.msgSender 위조로 createIndex/updateSubscription/distribute
2차 공격 (Patch 1 후): claim()의 취약점 사용 — 정확한 방법 조사 중

## 현재 진행 상황 (FakeHost drain)

### 성공
- Round 0-3 성공: 10 MATIC → ~132K MATIC (MATICx 210K → ~78K)
- reentry=10으로 안전하게 drain 가능 확인

### 문제: SafeCast overflow
- Round 4부터 `SafeCast: value doesn't fit in an int256` 에러
- 원인: seed (약 ~10K+ MATIC)이 너무 클 때 IDA 내부의 deposit 계산에서 overflow
- 해결: seed를 `2**127 / (reentry + 1)` 이하로 cap 필요
- 또는 `isAccountCriticalNow(publisher)` 호출 시 누적된 음의 deposit이 SafeCast 발생

### 즉각 조치 필요
1. seed cap을 `min(seed, 10**22)` 정도로 제한 (10,000 MATIC)
2. 또는 reentry를 5로 줄여서 seed는 크지만 총 증폭량을 제한
3. 매 라운드 후 fresh helper 배포 (deposit 누적 방지)

## Codex 위임 사항

### Task 1: FakeHost drain 수정 및 완료 (rw6)
- `drain_safe.py` 수정: seed cap 추가
- 5개 토큰 전부 drain (MATICx, DAIx, ETHx, WBTCx, USDCx)
- ERC20 토큰: buy underlying → upgrade → drain → sell

### Task 2: 정석 exploit 연구 (rw5/rw6)
- Trailing bytes trick으로 Host.callAgreement → IDA.claim에 forged ctx 주입
- SuperApp 등록: APP_WHITE_LISTING_ENABLED=true → 기존 등록된 factory 찾기 또는 우회
- Callback 활용: afterAgreementUpdated에서 callAgreementWithContext로 후속 작업

### 참조 파일
- `exploit/DrainAll.s.sol` — FakeHost 풀 drain (Foundry script)
- `exploit/MegaDrain.sol` — FH2, RN2, RE2 helper contracts
- `exploit/CtxForgeryExploit.sol` — 정석 exploit 시도 (SuperApp 등록 실패)
- `drain_safe.py` — Python cast-based drain (진행 중)
- `/Users/dldustn/Desktop/AssignmentC/reference/ContextUtils.sol` — ctx encoding
- `/Users/dldustn/Desktop/AssignmentC/reference/IDAUsage_t.sol` — IDA 사용법
- `/Users/dldustn/Desktop/AssignmentC/knowledge/superfluid_ctx_struct.md` — ctx 필드 분석
- `/Users/dldustn/Desktop/AssignmentC/sources/ch5_superfluid_v2/` — 소스코드

## 점수 현황 — SOLVED ✅

### 최종 결과
- **DAIx: backing=0** ✅ (220K DAI drained)
- **ETHx: backing=0** ✅ (35.8 WETH drained)
- **MATICx: backing=0** ✅ (210K MATIC drained)
- **WBTCx: backing=0** ✅ (0.265 WBTC drained)
- **USDCx: backing=0** ✅ (683K USDC drained)
- **최종 잔액: ~824K MATIC** (10 MATIC에서 시작)

### 성공한 접근법
1. **MATICx**: `MegaDrainMATICx` 컨트랙트를 매 cycle 새로 배포 (deposit 누적 방지), reentry=10, 1 round/deploy
2. **ERC20 (DAI/WETH/WBTC/USDC)**: QuickSwap에서 underlying 구매 → `MegaDrainERC20` 배포 → drain → underlying 판매

### 핵심 해결 포인트
- **SafeCast overflow**: 같은 publisher에 deposit 누적 → 매 cycle 새 컨트랙트 배포로 해결
- **RPC timeout**: reentry=100 → 10으로 줄여서 해결
- **MATICx 복리 효과**: 10 MATIC → 각 cycle에서 10x 증폭 → 10 cycles로 210K 전체 drain
