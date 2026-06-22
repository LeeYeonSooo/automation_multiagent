# Analysis Skill — Brain의 코드 분석 프로토콜

> 이전의 deep_analysis + hypothesis_quality + creative_escalation 통합

## 1. 분석 순서 (Brain이 직접)

### Phase 1: 코드 읽기 (위임 전 필수)

```bash
# 1. 소스 인덱스 확인
cat sources/<ch>/INDEX.md

# 2. 핵심 컨트랙트 소스 읽기 (Read 도구 사용)
# — entry point부터 시작, call chain 따라가기

# 3. verified vs unverified 차이 확인 (ch5 등)
cast code <addr> --rpc-url $RPC  # 실제 배포 bytecode
# vs sources/<ch>/verified/ 의 소스코드

# 4. on-chain 상태 조회
cast call <addr> "function()" --rpc-url $RPC
cast storage <addr> <slot> --rpc-url $RPC
```

### Phase 2: 관찰 기록

`analysis.md`에 **"## Code Observations (Attempt N)"** 섹션 작성:
- 최소 500 단어
- 스트림 형식 — "이 함수에서 X가 눈에 띈다", "Y 검증이 빠져 있다"
- 의문점, 이상한 점, 가정 위반 모두 기록
- **구체적 file:line 인용 필수**

### Phase 3: 가설 트리 구축

`analysis.md`에 **"## Hypothesis Tree (Attempt N)"** 작성:

```markdown
### HypA: [이름]
- **코드 경로**: contract.sol:L123 → contract.sol:L456
- **왜 exploitable**: [논리적 근거]
- **예상 성공 시나리오**: [구체적]
- **예상 실패(revert) 시나리오**: [어디서 revert될 수 있는지]
- **검증 방법**: [1줄 테스트 계획]
- **우선순위 근거**: [코드 증거 강도]

### HypB: [이름]
...

### HypC: [이름]
...
```

**최소 3개 가설.** 단일 가설에 올인하지 마라.

### Phase 4: 자기 비판

**"## Self-Critique (Attempt N)"** 작성:
- 각 가설에 대해 3개 이상의 반론
- "내가 놓친 방어 메커니즘이 있는가?"
- "이 가설이 fork 상태에 의존하는가?"

---

## 2. 가설 품질 최소 기준

| 요소 | 요구 |
|---|---|
| 코드 경로 | file:line 2개 이상 인용 |
| 논리적 근거 | "왜" exploitable한지 2문장 이상 |
| 공격 단계 | 번호 매긴 3단계 이상 |
| 제약 조건 | flash loan/gas/상태 의존성 명시 |
| 성공 판정 | 구체적 수치 (cast balance 기준) |

**이 기준 미달 시 Codex 위임 거부.**

---

## 3. Stuck 대응 (창의적 에스컬레이션)

60분간 진전 없으면:

### Level 1: 다른 각도로 코드 재독해
- 같은 컨트랙트를 "공격자 관점"으로 재독해
- 모든 external function 리스트업 → caller validation 누락 찾기
- storage layout 분석 → 슬롯 충돌/오염 가능성

### Level 2: Cross-challenge 패턴 탐색
- ch1-ch5의 취약점 유형 비교
- "ch3의 reentrancy 패턴이 ch5에도 적용 가능한가?"
- 다른 챌린지에서 사용한 기법의 변형

### Level 3: 멘토 힌트 재독해
- knowledge/mentor_hints.md 다시 읽기
- 힌트의 "숨은 의미" 재해석
- external_refs.md의 패치 커밋 diff 분석

### Level 4: 바이트코드 분석
```bash
# fork의 실제 bytecode vs verified source
cast code <addr> --rpc-url $RPC > /tmp/live.hex
# heimdall decompile 또는 수동 4byte 분석
cast 4byte-decode <selector>
```

### Level 5: 새로운 attack surface
- 지금까지 분석하지 않은 컨트랙트 탐색
- proxy implementation 변경 이력 확인
- 다른 프로토콜과의 composition (composability attack)

---

## 4. Dead End 기록 형식

```markdown
## DEAD_END: [가설 이름] (Attempt N)
- **가설**: ...
- **시도한 코드 경로**: file:line
- **실패 원인**: 정확한 revert reason + 코드 줄
- **왜 수정 불가능한가**: [근본적 차단 이유]
- **재시도 가치 없는 이유**: [논리적]
- **이 실패에서 배운 것**: [다음 가설에 어떻게 반영할지]
```

---

## 5. Anti-patterns (하지 마라)

1. **1-3줄 가설로 위임** — 코드 경로 없는 가설은 가설이 아니라 소망
2. **같은 가설 파라미터만 바꿔서 재시도** — parameter tuning은 가설 확인 후에만
3. **"이미 다 해봤다"** — 코드는 무한히 깊다. 바이트코드를 읽었나?
4. **Codex에게 분석 맡기기** — Codex는 구현 도구, 분석 도구가 아님
5. **dead end를 무시하고 같은 방향 고집** — 3번 실패하면 무조건 방향 전환
