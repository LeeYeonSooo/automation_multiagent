# 멀티에이전트 DeFi 익스플로잇 하네스

Claude(두뇌)와 Codex(손)를 파일시스템으로 묶어, 실제 DeFi 해킹 사건 5개를 자동으로 익스플로잇하고 챌린지별 보고서까지 작성하는 무인 하네스다.

스택: Claude Code, Codex CLI, Foundry(forge, cast, anvil)

## 한눈에

- 5개 챌린지(Uranium, Harvest, Fei-Rari, Superfluid v1, Superfluid v2)를 격리된 메인넷 포크에서 자동 공략
- 담당한 Exercise 1, 4, 5 결과: ch1 10000/10000 단독 1등, ch4 14985/15000, ch5 24241/25000
- 의도된 취약점 외에 Burger Swap 재진입 0day를 추가 발굴

## 어떻게 동작하나

- 두뇌(Claude): 온체인 상태와 Solidity 소스를 분석해 취약점 경로를 file:line 단위로 추적하고 가설과 보고서를 작성
- 손(Codex): forge, cast, anvil로 익스플로잇을 작성하고 실행
- 위임 게이트: 코드 경로, 근거, 공격 단계, 제약, 성공 판정 다섯 가지를 모두 채워야 손에게 위임 가능
- 파일 IPC: analysis.md(두뇌에서 손으로)와 status.json(손에서 두뇌로), 시도는 번호를 증분해 모든 기록을 증거로 보존
- 정책 훅: 손익분기 미달이면 broadcast 거부, 60분 정체 시 전제를 뒤집는 사고 전환을 강제
- tmux 무인 운영과 5분 주기 점수 폴링

## 디렉터리

- `challenges/` 챌린지별 작업 폴더(analysis.md, poc, exploit, report.md)
- `tools/delegate.sh` 오케스트레이션(task 유형별 프롬프트 자동 조립)
- `.claude/`, `hooks/`, `policy/`, `schemas/` 에이전트 정의와 정책 게이트
- `reports/` 챌린지별 보고서와 마스터 보고서

## 실행

```bash
./bootstrap.sh                 # 환경 셋업 (상세는 BOOTSTRAP_GUIDE.md)
./orchestrator/tmux_layout.sh  # 두뇌, 손, 모니터 3분할 세션
./tools/score.sh               # 현재 점수 확인
```

## 보안과 면책

- 학습과 연구 목적이다. 격리된 fork RPC를 대상으로 한 익스플로잇 코드를 포함한다.
- `.env`(개인키, RPC, 웹훅 등) 같은 민감정보는 커밋하지 않는다(.gitignore로 제외됨).
