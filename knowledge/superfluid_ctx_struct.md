# Superfluid Context Struct — 필드별 downstream 영향 매핑

ch4(v1)와 ch5(v2) 공격에 결정적. `reference/ContextUtils.sol` 의 Context struct를 기반으로, 각 필드를 조작했을 때 IDA(InstantDistributionAgreement) 내부에서 어떤 영향이 있는지 정리.

---

## Context struct (멘토 ContextUtils.sol에서)

```solidity
struct Context {
    uint8   appCallbackLevel;          // ctx1: callback 재귀 깊이 제한
    uint8   callType;                  // ctx1: AGREEMENT(1) | APP_ACTION(2) | APP_CALLBACK(3)
    uint256 timestamp;                 // ctx1: block.timestamp 복제
    address msgSender;                 // ctx1: 원래 호출자 (Patch 1에 의해 봉인됨 — claim 제외)
    bytes4  agreementSelector;         // ctx1: 호출 함수 selector
    bytes   userData;                  // ctx1: 임의 사용자 데이터
    
    uint256 appCreditGranted;          // ctx2: SuperApp callback에 부여된 allowance
    uint256 appCreditWantedDeprecated; // ctx2: (deprecated) wanted credit
    int256  appCreditUsed;             // ctx2: 이미 사용된 credit
    address appAddress;                // ctx2: 현재 callback 진행 중인 SuperApp
    address appCreditToken;            // ctx2: allowance 대상 SuperToken
}
```

---

## v1 (ch4) — msgSender 조작

Patch 1 적용 전. 거의 모든 IDA 함수가 `authorizeTokenAccess` 호출 안 하거나 ctx 검증 빠뜨림. 가장 단순한 공격.

| 함수 | msgSender 조작 효과 |
|---|---|
| `createIndex` | 피해자가 publisher인 index 생성 |
| `updateSubscription` | 피해자의 publisher 권한으로 attacker에게 units 부여 |
| `updateIndex` | 피해자가 publisher인 index의 indexValue 인플레이트 |
| `distribute` | 피해자 SuperToken 잔액으로 distribution 강제 |
| `claim` | (subscriber 파라미터로 attacker 지정) → 피해자 publisher의 distribution 회수 |

### 공격 체인 (멘토 힌트 + 실제 공격):
```
1. createIndex(token, indexId, fakeCtx{msgSender=victim})
   → 피해자가 publisher인 index 생성됨
2. updateSubscription(token, indexId, attacker, units, fakeCtx{msgSender=victim})
   → attacker에게 units 부여 (publisher 권한 도용)
3. updateIndex(token, indexId, BIG, fakeCtx{msgSender=victim})
   또는 distribute(token, indexId, victim_balance, fakeCtx{msgSender=victim})
   → 피해자 SuperToken 잔액 → attacker에게 분배
4. claim(token, victim, indexId, attacker, fakeCtx)
   → attacker SuperToken 잔액 증가
5. token.downgrade(amount) → ERC20 underlying
6. underlying → native (uniswap/pancakeswap)
```

핵심: fakeCtx의 msgSender만 victim으로 설정하면 됨. 다른 필드는 표준값.

---

## v2 (ch5) — 다른 필드 조작

Patch 1 적용. `authorizeTokenAccess` 가 `isCtxValid(ctx)` 호출해서 stamp 검증. **단 `claim()` 은 `authorizeTokenAccess` 호출 자체를 안 함** → ctx 검증 우회 가능. 

문제: claim 경로에서 msgSender 조작은 효과 없음.
- `claim(token, publisher, indexId, subscriber, ctx)` 에서 publisher와 subscriber는 명시 파라미터
- 금액 = `(idata.indexValue - sdata.indexValue) * sdata.units`
- 이건 체인 상태(인덱스/구독 데이터)에서 파생되므로 ctx로 직접 위조 불가

### 그럼 어떤 필드를 노릴 수 있나

`claim()` 내부 흐름:
1. `_loadAllData(token, publisher, subscriber, indexId, true)` — 구독/인덱스 데이터 로드
2. `require(vars.sdata.subId == _UNALLOCATED_SUB_ID, "IDA: E_SUBS_APPROVED")` — 미승인 구독에만 적용
3. `pendingDistribution = (idata.indexValue - sdata.indexValue) * sdata.units`
4. `cbStates = AgreementLibrary.createCallbackInputs(token, publisher, sdata.sId, "")`
5. `newCtx = ctx`
6. `if (pendingDistribution > 0) { cbStates.noopBit = BEFORE_AGREEMENT_UPDATED_NOOP; vars.cbdata = AgreementLibrary.callAppBeforeCallback(cbStates, newCtx); ... }`
7. callback 진행 → `callAppAfterCallback` 도 호출

**핵심: callback chain이 ctx를 그대로 SuperApp에 넘긴다.**

`AgreementLibrary.createCallbackInputs` → `callAppBeforeCallback` → 내부에서 `host.callAppBeforeCallback(app, callbackData, ctx)` 류의 호출. 여기서 `ctx`의 다음 필드들이 결정적:

#### `appAddress` 조작
- callback 대상 SuperApp 주소 위장. host가 이걸 어떻게 신뢰하는지에 따라 임의 컨트랙트 호출 가능
- 공격자가 자기 컨트랙트를 SuperApp으로 가장 → callback 안에서 `host.callAgreementWithContext(...)` 등으로 sub-operation 가능

#### `appCreditGranted` 조작
- callback 안에서 SuperApp이 SuperToken을 ERC20 대비 무료로 사용할 수 있는 한도
- 인플레이트 시 callback 내부에서 host에 추가 작업 발주할 때 credit 한도 우회
- 공격자: granted를 `type(uint128).max` 로 → callback 안에서 다른 SuperToken 임의로 옮김

#### `appCreditUsed` 조작
- 음수로 설정 시 (int256 음수) → "이미 빚졌음" 회계 깨짐
- 인플레이트 한도 추가 확보

#### `appCreditToken` 조작
- granted/used가 적용되는 토큰을 위장
- 공격 대상 토큰을 다른 토큰으로 바꿔서 회계 회피

### 가장 유력한 v2 공격 가설

```
1. attacker SuperApp 컨트랙트 배포
2. 피해자(superToken 보유자) 대상 createIndex/updateSubscription 정상 절차로 셋업
   (또는 v1 트릭 일부 활용)
3. claim(token, publisher, indexId, attackerSuperApp, fakeCtx)
   - fakeCtx.appAddress = attackerSuperApp
   - fakeCtx.appCreditGranted = type(uint128).max
   - fakeCtx.appCreditToken = token
   - fakeCtx.appCallbackLevel = 0  (재귀 제한 우회)
4. claim → callAppBeforeCallback(attackerSuperApp, ...)
   - attackerSuperApp의 callback에서 host.callAgreementWithContext 호출
   - granted credit 안에서 임의 SuperToken 이동/distribute 가능
5. callback 내부에서 다른 피해자/풀의 SuperToken 잔액을 attacker로 이동
6. token.downgrade → native
```

위는 가설. 정확한 흐름은 `_loadAllData` 와 `callAppBeforeCallback` 내부 검증에 따라 달라짐.

### 검증 단계 (Codex 위임 시 PoC)

1. v1 환경에서 fakeCtx 모든 필드 조작 가능 확인
2. claim 호출 시 callback이 실제로 발동하는지 (pendingDistribution > 0 조건)
3. callback 안에서 ctx 어떤 필드가 SuperApp에 전달되는지 추적
4. attackerSuperApp이 실제로 host의 sub-operation 호출할 수 있는지

---

## v2 → v1 역적용 (멘토 힌트)

> "슈퍼플루이드 두 번째 버그 익스플로잇하는 방법을 알면 같은 기법을 첫 번째 버그에서 쓸 수 있거든요."

v2의 callback chain 트릭을 v1에도 쓰면 v1의 점수도 더 짤 수 있음:
- v1에서 publisher 권한 도용으로 한 피해자 SuperToken만 빼는 게 아니라
- callback 트릭으로 한 트랜잭션 안에 여러 피해자 동시 처리
- 또는 다른 SuperToken까지 횡단 처리

이 점이 v2 우선 풀고 v1 재활용해서 점수 늘리는 전략의 근거.

---

## 핵심 컨트랙트 주소 (멘토 PPT에서)

Polygon:
- Superfluid (host): `0x3E14dC1b13c488a8d5D310918780c983bD5982E7`
- IDA: `0xB0aABBA4B2783A72C52956CDEF62d438ecA2d7a1`
- USDCx (super USDC): `0xCAa7349CEA390F89641fe306D93591f87595dc1F`
- USDC: `0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174`
- victim (실제 공격 사례): `0x2e9e3C24049655f2D8C59f08602Da3DE4aD34188`

기타 SuperToken들: `MATICx`, `DAIx`, `USDTx`, `WETHx`. recon에서 enumerate.

Fork block (실제 공격 직전): 24,684,668 (v1). v2 환경은 챌린지 RPC가 정해줌 (아마 패치 적용된 버전 배포 후).

---

## ContextUtils 사용법 (reference/IDAUsage_t.sol)

```solidity
import { ContextUtils } from "./ContextUtils.sol";

// fake ctx 만들기
ContextUtils.Context memory fakeCtx = ContextUtils.Context({
    appCallbackLevel: 0,
    callType: ContextUtils.CALL_TYPE_AGREEMENT,
    timestamp: block.timestamp,
    msgSender: VICTIM,                    // v1: publisher 도용
    agreementSelector: IDA.createIndex.selector,
    userData: "",
    appCreditGranted: 0,                  // v2: 인플레이트
    appCreditWantedDeprecated: 0,
    appCreditUsed: 0,
    appAddress: address(0),               // v2: attacker SuperApp
    appCreditToken: address(0)            // v2: attacker target
});

bytes memory packedCtx = ContextUtils.encodeContext(fakeCtx);
```

calldata 조립:
```solidity
// 정상: callAgreement(IDA, abi.encodeCall(IDA.createIndex, (token, id, new bytes(0))), "")
// 공격: callAgreement(IDA, abi.encodePacked(
//          abi.encodeCall(IDA.createIndex, (token, id, packedCtx)),
//          new bytes(32)  // 0-length placeholder. host가 이걸 교체.
//        ), "")
```

위 packed 형식은 EVM ABI 특성을 이용:
- `createIndex(token, id, ctx)` 시그니처가 `ctx` (마지막 파라미터)로 packedCtx를 인식
- host는 calldata 마지막의 `new bytes(32)` 를 자기 ctx로 교체 (그러나 createIndex는 packedCtx 자리만 본다)
- 결과: createIndex가 packedCtx를 진짜 ctx로 인식

자세한 메커니즘은 `case_superfluid_v1.md` 참조.
