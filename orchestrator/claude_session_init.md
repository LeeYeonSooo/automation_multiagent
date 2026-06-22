# Claude Session Init Prompt

새 Claude Code 세션을 시작할 때 첫 prompt로 이걸 붙여넣어라. 짧은 버전부터.

---

## 짧은 버전 (일상)

```
@CLAUDE.md @PROGRESS.md
지금부터 작업 재개. 현재 상태 확인 후 다음 액션 진행.
```

---

## 첫 시작 버전 (한 번만)

```
@CLAUDE.md @AGENTS.md @PROGRESS.md @orchestrator/handoff_protocol.md @knowledge/scoring_model.md

이 하네스의 두뇌로 동작한다.

작업 순서:
1. CLAUDE.md §0 의 5단계 (PROGRESS.md 확인, score 확인, .env 라인 수 확인, 각 status.json 확인, handoff_protocol.md 환기) 수행.
2. ch1_uranium 부터 시작.
3. ch1 analysis.md 가 비어있으면 knowledge/case_uranium.md 읽고 analysis.md 작성.
4. tools/delegate.sh 로 ch1 recon task 발주.
5. recon 완료되면 PoC task 발주.
6. exploited 되면 ch3 으로 진행.

자율적으로 진행. 사람 컨펌은 본방 exploit 직전에만.
```

---

## 컨텍스트 압축 후 복귀 버전

```
@PROGRESS.md @CLAUDE.md
컨텍스트 압축 후 복귀. PROGRESS.md의 "컨텍스트 압축 시 보존된 정보" 섹션부터 확인.
```

---

## Stuck 알림 받았을 때

```
@PROGRESS.md @CLAUDE.md @skills/creative_escalation.skill.md
stuck 감지됨. 해당 챌린지의 shared/inbox/stuck_<ch>.txt 읽고 escalation 8단계 발동.
```

---

## 보고서 마감 모드

```
@PROGRESS.md @CLAUDE.md @templates/report.md.template
모든 챌린지의 report.md 초안을 검수하고 reports/ 로 최종본 작성.
"Failed Attempts" 섹션이 빠짐없이 들어갔는지 우선 확인.
```
