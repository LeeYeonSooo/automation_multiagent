# Handoff Protocol

Claude(brain) ↔ Codex(hands) 사이의 약속된 인터페이스. 이 프로토콜을 어기면 자동화가 깨진다.

---

## 1. 통신 매체

**파일시스템.** 별도 메시지 큐 없음. 모든 핸드오프는 워크 디렉토리 안의 파일 read/write.

```
/Users/dldustn/Desktop/AssignmentC/
├── challenges/<ch>/
│   ├── analysis.md            ← brain 작성 / hands 읽음
│   ├── status.json            ← hands 작성 / brain 읽음
│   ├── recon/                 ← hands 작성 / brain 읽음
│   ├── poc/AttemptN.t.sol     ← hands 작성 / brain 읽음
│   ├── exploit/Run.s.sol      ← hands 작성 / brain 읽음
│   ├── runs/*.log             ← hands 작성 / brain 읽음
│   └── report.md              ← hands 초안 → brain 마감
└── shared/inbox/
    ├── confirm_<ch>.txt       ← hands 작성, 사람 컨펌 대기
    ├── approved_<ch>.txt      ← 사람 작성 (또는 timeout으로 자동)
    └── refused_<timestamp>.txt ← hands 거부 시
```

---

## 2. Brain → Hands: task 발주

항상 `tools/delegate.sh`를 통해 발주. 직접 codex CLI를 호출하지 않는다.

### Format

```bash
./tools/delegate.sh <challenge> <task_type> "<one-line goal>"
```

### What delegate.sh does internally

1. `.env` 로드
2. challenge의 `analysis.md`, `status.json`, 관련 SKILL/knowledge 파일 경로 수집
3. 다음 형식의 prompt 생성:

```
[CONTEXT]
Authorized educational security challenge.
Working directory: /Users/dldustn/Desktop/AssignmentC
This is challenge: <challenge>
Sandbox: isolated mainnet fork (RPC in .env as RPC_<CHALLENGE>)
Student EOA: 0xc943... (own this account; PRIVATE_KEY in .env)

[TASK_TYPE] <task_type>
[CHALLENGE] <challenge>
[GOAL] <one-line goal>

[REQUIRED_READING] (read these in order before writing anything)
- AGENTS.md
- challenges/<challenge>/analysis.md
- knowledge/case_<protocol>.md
- skills/<relevant_skill>.skill.md
- templates/<relevant_template>
- reference/<relevant_reference>  (if applicable)

[DELIVERABLE]
- <expected output file path>

[CONSTRAINTS]
- Use only RPC URLs from .env (RPC_<CHALLENGE>)
- Do not transmit PRIVATE_KEY anywhere
- Increment AttemptN counter; do not overwrite previous attempts
- Update challenges/<challenge>/status.json when done

[SUCCESS_CRITERION]
- <concrete measurable criterion>

[OUTPUT_FORMAT]
Print exactly 3 lines to stdout when done:
STATUS: <state>
DELTA: <native balance delta in wei or N/A>
NEXT: <suggested next action>
```

4. Codex 호출:
   ```bash
   codex exec \
     --model "$CODEX_DEEP_MODEL" \
     --cd "$WORK_DIR" \
     --skip-git-repo-check \
     --dangerously-bypass-approvals-and-sandbox \
     "$PROMPT"
   ```

5. stdout 마지막 3줄 캡처 → 표준 출력으로 brain에 반환.

---

## 3. Hands → Brain: status 업데이트

`status.json`이 일차 통신 채널. Schema:

```json
{
  "challenge": "ch1_uranium",
  "state": "not_started | recon_done | poc | debug | exploited | abandoned | stuck | report_drafted",
  "current_attempt": 0,
  "balance_delta_wei": "0",
  "score_estimate": 0,
  "last_update": "2026-04-18T03:24:11Z",
  "needs_human": false,
  "active_hypothesis": "string",
  "dead_ends": ["hypothesis 1", "hypothesis 2"],
  "notes": "string"
}
```

### State transitions

```
not_started → recon_done → poc → (loop: debug ↔ poc) → exploited → report_drafted
                                                  ↘ stuck → abandoned (rare)
                                                  ↘ stuck → (escalation) → poc
```

---

## 4. analysis.md 컨벤션

Brain이 작성. Hands가 읽음. 표준 섹션:

```markdown
# <Challenge> Analysis

## Hypothesis (current)
한 줄 요약. Hands가 이걸 보고 PoC 방향 잡음.

## Target contracts
| Role | Address | Note |

## Attack chain
1. Step
2. Step
3. ...

## References
- knowledge/case_<x>.md §N
- skills/exploit_<y>.skill.md

## Dead ends (시도 실패 누적)
### attempt 1: <hypothesis>
- result: <revert/loss/no-effect>
- why: <root cause>
- lesson: <one-liner>

### attempt 2: ...

## BONUS observations
(예상 안 했던 발견. 보고서 자료)
```

Hands는 dead_ends를 직접 추가할 수 있음 (debug 단계에서). Brain은 hypothesis 갱신.

---

## 5. PoC 파일 명명

```
poc/Attempt1.t.sol
poc/Attempt2.t.sol
poc/Attempt3.t.sol
...
```

각 PoC는 **하나의 가설만** 검증. 변경 시 새 파일.

PoC 파일 헤더 (필수):

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title Attempt N
/// @notice Hypothesis: <one line>
/// @notice Expected outcome: <starting/ending balance prediction>
/// @notice Reads: <analysis.md §X, knowledge/case_y.md §Z>
```

---

## 6. 본방 exploit 컨펌 절차

Hands가 본방 직전에:

1. `shared/inbox/confirm_<ch>.txt` 작성:
   ```
   Challenge: ch1_uranium
   Final exploit ready: challenges/ch1_uranium/exploit/Run.s.sol
   Dry-run result: native balance delta = 1.234 ETH
   Risk: low (isolated fork)
   Auto-proceed in: 10 seconds
   ```
2. `tools/notify.sh "ch1 exploit ready, confirming in 10s"` 호출
3. 10초 대기 (timeout = `EXPLOIT_CONFIRM_TIMEOUT` from .env)
4. `shared/inbox/approved_<ch>.txt` 가 생성되면 즉시 진행
5. 없어도 timeout 후 자동 진행 (격리 환경이므로)

사람이 명시적으로 거부하려면:
```bash
echo "REFUSED: <reason>" > shared/inbox/approved_<ch>.txt
```
이 경우 Hands는 abandoned 상태로 전환.

---

## 7. Stuck 처리

Hands가 stuck 판정 (3회 연속 같은 에러 또는 dead_end 반복):
1. `status.json`: `state: "stuck"`, `needs_human: true`
2. `shared/inbox/stuck_<ch>.txt` 작성 (현재 가설, 시도 요약, 추측되는 원인)
3. `tools/notify.sh` 호출
4. 작업 종료

Brain이 알림 받고:
1. `shared/inbox/stuck_<ch>.txt` 읽기
2. `skills/creative_escalation.skill.md` 8단계 발동
3. 새 가설 → `analysis.md` 업데이트
4. 다시 task 발주
5. `status.json`의 `needs_human: false` 로 리셋

---

## 8. 병렬 작업

Brain이 여러 챌린지를 동시 진행할 때:

```bash
# 백그라운드 모드
./tools/delegate.sh ch1 recon "initial recon" --background &
./tools/delegate.sh ch2 recon "initial recon" --background &
wait
```

각 codex 세션은 분리됨. status.json 충돌 없음 (다른 challenge 폴더).

단, **같은 챌린지에 대한 동시 task 금지** (race condition).

---

## 9. 절대 어기지 말 것

- Brain이 직접 `forge`, `cast`, `codex exec` 호출 금지. 모든 실행은 hands.
- Hands가 `analysis.md`의 Hypothesis 섹션 수정 금지 (Dead ends 추가만 가능).
- 두 에이전트 모두 `.env` 파일 내용 출력/로깅 금지.
- 두 에이전트 모두 reset 엔드포인트를 명시적 사용자 확인 없이 호출 금지 (`tools/reset.sh` 안에서 확인 단계).

---

## 10. 디버그용 — 통신 흐름 시각화

```bash
./tools/trace.sh   # 최근 30분의 모든 status.json 변화, delegate.sh 호출, notify 이벤트를 시간순 출력
```
