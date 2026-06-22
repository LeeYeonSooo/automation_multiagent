# Report Skill — 보고서 작성

> 이전의 auto_report + report_writing 통합

## 1. 증분 작성 (매 attempt마다)

### Pending note 처리 흐름
1. `challenges/<ch>/.pending_report_notes/*.note` 확인
2. 각 note에 대해:
   a. note 파일 + archived 파일 + runs/*.log 읽기
   b. report.md 열기 (없으면 §4 skeleton으로 생성)
   c. Timeline에 row 추가 + Attempts에 entry 추가
   d. note 삭제

### Triage (3-tier)

| 레벨 | 기준 | 처리 |
|---|---|---|
| **Meaningful** | 가설 전환, 첫 성공, 큰 delta, 새 attack surface | 풀 5요소 entry |
| **Minor** | 파라미터 변경, 소규모 delta, 기존 가설 반복 | 3요소 축약 (How/Result/WhyFailed) |
| **Skip** | 동일 revert 반복, 단순 typo 수정 | Timeline row만, Attempts 생략 |

### 5요소 (Meaningful entry)

```markdown
### Attempt N: [제목]
**Why**: 이전 attempt의 [X] 실패에서 [Y] 가설로 전환
**How**: [방법 + 코드 3-10줄]
**Result**: native delta = +X.XX ETH (또는 revert: "reason")
**Why succeeded/failed**: [root cause + 결정적 코드 줄]
**Thought process**: [다음 시도를 어떻게 결정했는지]
```

## 2. Report skeleton

```markdown
# Challenge Report: <ch>

## 1. TL;DR
| Metric | Value |
|---|---|
| Final score | |
| Native delta | |
| Total attempts | |
| Final tx hash | |

## 2. Vulnerability Summary
[한 단락 root cause]

## 3. Timeline
| # | Time | Action | Result |
|---|---|---|---|
<!-- TIMELINE_MARKER -->

## 4. Attempts
<!-- ATTEMPTS_MARKER -->

### Patterns observed
[cross-cutting 분석]

## 5. Final Successful Exploit
[단계별 재현]

## 6. Root Cause Analysis
[systemic 분석]

## 7. Better Patch Proposal
[minimal diff + architectural redesign]

## 8. Lessons Learned
[공격자/방어자/감사자 관점]
```

## 3. 최종 마감 체크리스트

- [ ] exploits/failed/ 의 모든 파일이 §4에 entry 있는가?
- [ ] ARCHIVE_LOG.md 의 모든 entry가 §3 Timeline에 있는가?
- [ ] 각 Meaningful entry에 5요소 모두 있는가?
- [ ] TODO 마커 모두 제거?
- [ ] reports/<ch>.md 로 최종본 복사?
