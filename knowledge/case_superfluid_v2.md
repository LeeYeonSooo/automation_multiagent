# Case: Superfluid v2 (patched) — ch5 reach goal

## Overview

- **상태**: Patch 1 적용된 Superfluid (msgSender forge 경로 봉쇄)
- **남은 취약점**: `IDA.claim()` 함수가 `authorizeTokenAccess`를 호출하지 않음 (Patch 2 이전)
- **공격면**: ctx의 **msgSender 외 필드** (`appAllowance*`, `appAddress`, `appAllowanceToken`)
- **배점**: 25,000 (가장 높음)
- **솔버**: 이전 5개 기수 합산 1명만 풀음 (멘토 발언)

## Patch 1의 정체

Superfluid 사고 후 즉시 적용된 패치:

```solidity
function authorizeTokenAccess(ISuperfluidToken token, bytes memory ctx)
    internal view
    returns (ISuperfluid.Context memory)
{
    require(token.getHost() == msg.sender, "AgreementLibrary: unauthorized host");
+   require(ISuperfluid(msg.sender).isCtxValid(ctx), "AgreementLibrary: invalid ctx");
    return ISuperfluid(msg.sender).decodeCtx(ctx);
}

// isCtxValid 내부:
function isCtxValid(bytes memory ctx) external view returns (bool) {
    return _ctxStamp == keccak256(ctx);
}
```

이제 ctx의 keccak256이 host가 저장한 stamp랑 다르면 reject. **msgSender 위조는 stamp가 안 맞으니 봉쇄됨**.

## 두 번째 취약점

`AgreementLibrary.authorizeTokenAccess`에 검증을 넣었지만, **모든 entry에서 호출되는지는 별개**. IDA.claim()을 보면:

```solidity
function claim(
    ISuperfluidToken token,
    address publisher,
    uint32 indexId,
    address subscriber,
    bytes calldata ctx
)
    external override
    returns(bytes memory newCtx)
{
    _SubscriptionOperationVars memory vars;
    AgreementLibrary.CallbackInputs memory cbStates;
    
    (vars.iId, vars.sId, vars.idata, , vars.sdata) =
        _loadAllData(token, publisher, subscriber, indexId, true);
    // ↑ authorizeTokenAccess 미호출!
    
    require(vars.sdata.subId == _UNALLOCATED_SUB_ID, "IDA: E_SUBS_APPROVED");
    
    uint256 pendingDistribution = uint256(vars.idata.indexValue - vars.sdata.indexValue)
        * uint256(vars.sdata.units);
    
    cbStates = AgreementLibrary.createCallbackInputs(token, publisher, vars.sId, "");
    // ↑ 여기서 ctx의 callType, appAddress 등이 callback inputs에 사용
    
    newCtx = ctx;
    
    if (pendingDistribution > 0) {
        cbStates.noopBit = SuperAppDefinitions.BEFORE_AGREEMENT_UPDATED_NOOP;
        vars.cbdata = AgreementLibrary.callAppBeforeCallback(cbStates, newCtx);
        // ← here: callback chain 진입. ctx의 다른 필드들이 권한/SuperApp identity로 사용됨
        
        // ... distribute 후 ...
        
        AgreementLibrary.callAppAfterCallback(cbStates, newCtx);
    }
}
```

**관찰**: `claim()`이 `authorizeTokenAccess`를 부르지 않음 → ctx 검증 통째로 빠짐 → 공격자가 임의 ctx 주입 가능.

## msgSender는 왜 무용

claim()은 publisher와 subscriber를 **함수 인자로 받음**. ctx의 msgSender는 claim() 본문에서 직접 권한 결정에 안 쓰임. publisher/subscriber/units는 storage(loadAllData)에서 가져옴.

→ msgSender 조작해도 publisher 행세 못함.

## 진짜 공격 벡터: 다른 ctx 필드

### 후보 1: appCreditGranted / appCreditUsed
SuperApp callback에서 sub-operation 한도 결정. inflate하면 callback 안에서 host에 추가 호출 가능 → 공격자 SuperApp이 다른 SuperToken/유저 자산 탈취

### 후보 2: appAddress
현재 callback 스택의 SuperApp identity. attacker가 임의 주소 (예: victim 또는 token 컨트랙트) 지정하면 후속 권한 체크 오판

### 후보 3: appAllowanceToken
Allowance 대상 토큰. 다른 토큰으로 위장하면 cross-token 자산 이동 트리거 가능성

### 후보 4: callType
- AGREEMENT (1) / APP_ACTION (2) / APP_CALLBACK (3)
- callType=APP_CALLBACK 으로 위장하면 어떤 권한 path를 우회할 수 있는지

## 공격 가설 (검증 필요)

### Hypothesis A: Allowance Inflation + Callback Chain
1. 공격자: SuperApp 컨트랙트 배포 (callback 인터페이스 구현)
2. 공격자 본인을 publisher로 setup (소량 SuperToken으로): createIndex, updateSubscription (subscriber=attacker, units>0), updateIndex (작은 양 distribute)
3. **claim() 호출 with fake ctx**:
   - `appCreditGranted = type(uint128).max` (한도 무제한)
   - `appAddress = attacker_super_app`
   - msgSender, callType 등은 정상값
4. claim() → callAppBeforeCallback → attacker SuperApp의 `beforeAgreementUpdated()` 트리거
5. callback 내부에서:
   - host.callAppAction(victim_token, transferAll(victim, attacker)) 또는 비슷한 flow
   - ctx.appCreditUsed가 host에 의해 갱신되지만, 이미 작은 한도로 큰 작업 가능
6. → SuperToken 잔액 attacker로 이동
7. → downgrade

### Hypothesis B: Existing Subscription Inflation
1. 공격자: 자신을 subscriber로 등록한 popular index 찾기
   - 또는 createIndex 후 자기를 subscriber로 등록
2. **claim() 호출 with fake ctx**:
   - ctx 조작으로 callback 흐름 hijack
   - pendingDistribution 계산 자체는 storage 기반이라 못 속이지만, callback이 실행되는 컨텍스트를 조작

### Hypothesis C: Cross-token via appAllowanceToken
- ctx.appAllowanceToken을 victim의 SuperToken으로 설정
- callback 내에서 그 토큰의 transfer/distribute 권한 행사

**모든 가설은 PoC로 검증해야 함.** Codex가 각 hypothesis별 별도 Attempt 작성.

## ch5 챌린지 적용

### 시작점
1. `reference/IDAUsage_t.sol` + `reference/ContextUtils.sol` 그대로 활용
2. v1 (ch4) 공격이 먼저 작동해야 함 — ch4 마치고 ch5 시도
3. v1 인사이트로 v1 점수 더 올릴 수 있음 (멘토 명시)

### 추가 컨트랙트
- 공격자 SuperApp 컨트랙트 별도 배포 필요 (ISuperApp 인터페이스 구현)
- 적어도 `beforeAgreementUpdated`, `afterAgreementUpdated` 콜백 함수

### Foundry script 스켈레톤
```solidity
contract AttackerSuperApp is ISuperApp {
    address attacker;
    ISuperfluid host;
    
    function beforeAgreementUpdated(...) external override returns (bytes memory) {
        // 여기서 host.callAgreement / callAppAction 으로 sub-op
        // ctx.appCreditGranted 만큼 한도
        return "";
    }
    
    // ... afterAgreementUpdated, beforeAgreementCreated, etc.
}

contract SuperfluidV2Exploit is Test {
    function attack() external {
        // 1. deploy AttackerSuperApp
        // 2. register as SuperApp (host.registerApp)
        // 3. setup: become publisher, subscribe self
        // 4. craft fake ctx with allowance / appAddress fields
        // 5. claim() with crafted ctx
        // 6. drain
    }
}
```

## 점수 최적화

- v2가 풀리면 v1 점수도 같이 올라감 (멘토 발언)
- 한 번 작동하는 공격 찾으면 여러 SuperToken / victim에 적용
- MATICx → MATIC native 직접 변환 가능

## A/B/C/D 분류

- A: claim()에 authorizeTokenAccess 누락
- B: Patch 2 (claim에 한 줄 추가)
- C: Patch 1 (불완전, claim 누락)
- D: 거의 없음. SuperApp 배포 가스만

## Codex 위임 시 강조

- **창의력 필수 영역**. 단순 시도로 안 풀림. 멘토: "거의 안 풀림".
- 가설 → PoC → 실패 → 가설 재정립 사이클 반복
- 가설 3개 (A/B/C) 병렬로 시도
- callback 흐름 시뮬레이션이 핵심: SuperApp이 어떤 ctx로 호출되는지 정확히 trace

## 단서 모음

- 멘토 강의: "context의 다른 필드를 잘 바꿔서 SuperToken의 underlying 토큰을 다 빼올 수 있음"
- 멘토 강의: "v2 익스플로잇 방법을 알면 같은 기법을 v1에서도 쓸 수 있음"
- 패치 commit 2: https://github.com/superfluid-finance/protocol-monorepo/commit/84f366b3d30d242d0a9173ced45b0db227222cb3 (claim에 한 줄 추가)
- 단서: 패치가 단 한 줄이라는 건 우회 트릭이 매우 specific하다는 의미
