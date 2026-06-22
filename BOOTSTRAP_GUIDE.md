# BOOTSTRAP_GUIDE.md

압축 풀고 30분 안에 첫 챌린지 시도까지 가는 절차.

---

## 0. 사전 조건

- macOS (zsh)
- Foundry 설치됨 (`~/.foundry/bin/forge` 존재)
- Codex CLI 설치됨 (`/opt/homebrew/bin/codex`)
- Claude Code 설치됨 (`which claude`)
- Homebrew 사용 가능

---

## 1. 압축 풀기

```bash
cd ~/Desktop
tar -xzf upside-c.tar.gz
mv upside-c AssignmentC   # 기존 폴더명에 맞춤
cd AssignmentC
ls
```

---

## 2. Bootstrap 실행

```bash
./bootstrap.sh
```

이게 처리하는 것:
1. 모든 .sh / .py 파일에 실행 권한 부여
2. forge / cast / jq / python3 / curl 설치 확인
3. tmux 미설치 시 `brew install tmux` 안내 (또는 자동 설치)
4. Codex / Claude CLI 설치 확인
5. `.env.template` → `.env` 복사 (RPC, private key, Discord webhook 모두 미리 채워져 있음)
6. .env의 RPC 5개 ping (chain_id 응답 확인)
7. Discord webhook ping (Discord 채널에 메시지 도달 확인)

`.env`의 값들은 **이미 너의 입력 기반으로 채워져 있다.** Etherscan API key 같은 옵션 항목만 비어 있으니 필요 시 직접 추가.

---

## 3. Health check (한 번 더)

```bash
./tools/health_check.sh
```

이 명령으로:
- 모든 도구의 버전 출력
- 5개 RPC 각각 chain_id 출력
- Discord webhook 도달 여부
- 본인 EOA 잔액 (5개 fork 모두)

문제 없으면 다음으로.

---

## 4. tmux 세션 시작

```bash
./orchestrator/tmux_layout.sh
```

자동으로 생성되는 4개 영역:
- **pane 0** (왼쪽 위): Claude Code 자동 실행. 너가 prompt 입력하는 곳
- **pane 1** (왼쪽 아래): Codex 수동 호출용 (대부분 사용 안 함; delegate.sh가 자동)
- **pane 2** (오른쪽): 점수 + 진행 상황 60초마다 갱신
- **window "poller"**: 점수 폴링 데몬 (백그라운드)

pane 이동: `Ctrl-b` 누른 후 화살표
window 이동: `Ctrl-b` 누른 후 `n`(다음) / `p`(이전)
세션 분리: `Ctrl-b d` (세션은 살아있음)
세션 다시 들어가기: `tmux a -t upside`

---

## 5. Claude에게 첫 prompt

pane 0 (`claude` 실행됨)에서:

```
@CLAUDE.md @AGENTS.md @PROGRESS.md @orchestrator/handoff_protocol.md @knowledge/scoring_model.md

이 하네스의 두뇌로 동작한다.

작업 순서:
1. CLAUDE.md §0 5단계 수행
2. ch1_uranium 부터 시작
3. analysis.md 작성 후 tools/delegate.sh 로 ch1 recon 위임
4. recon 완료되면 PoC 위임
5. exploited 되면 ch3 으로

자율 진행. 사람 컨펌은 본방 exploit 직전에만.
```

이걸 그대로 붙여넣어라. (`orchestrator/claude_session_init.md`에 저장된 템플릿)

---

## 6. 노트북 닫고 자도 OK

tmux 세션은 백그라운드에서 살아있다. 노트북 뚜껑만 닫고 외부 모니터 분리해도 OK. 다음날 다시 들어갈 때:

```bash
cd ~/Desktop/AssignmentC
tmux a -t upside
```

세션이 죽었다면 (드물지만) 다음으로 부활:
```bash
./orchestrator/tmux_layout.sh   # 같은 세션명이면 첨부, 없으면 신규 생성
```

---

## 7. Discord 알림 확인

`bootstrap.sh` 실행 후 Discord 채널에 "🚀 Bootstrap complete..." 메시지가 즉시 와야 한다. 안 오면:
- webhook URL이 만료/취소된 경우 (Discord에서 새로 만들어 .env 업데이트)
- 네트워크 문제

---

## 8. 처음 1시간에 봐야 할 것

| 시점 | 확인 |
|---|---|
| +5분 | ch1 status.json에 `state: "recon_done"` 으로 업데이트되었는가 |
| +15분 | ch1 poc/Attempt1.t.sol 생성되어 있는가 |
| +30분 | ch1 status.json `state: "exploited"` 또는 `debug` |
| +60분 | Discord에 알림 와 있는가 (점수 변동 또는 완료) |

전부 충족되면 ch3으로 자동 넘어간다. 안 되면 `./tools/trace.sh 60` 으로 최근 1시간 활동 확인.

---

## 트러블슈팅

### Codex가 task에 응답 안 함
```bash
# delegate prompt 확인
ls -t logs/delegate_*.prompt | head -1 | xargs cat
# 그 prompt를 직접 codex에 붙여넣어 결과 확인
```

### Foundry 컴파일 에러
```bash
cd challenges/ch1_uranium/poc
forge install foundry-rs/forge-std --no-commit
```

### RPC 끊김
```bash
./tools/health_check.sh
# RPC 응답 없으면 .env의 URL 확인 (만료 가능성). chainlight 사이트에서 새 URL 발급
```

### tmux 세션 안 보임
```bash
tmux ls
# 세션이 정말 없으면
./orchestrator/tmux_layout.sh
```

### Discord 알림 안 옴
```bash
./tools/notify.sh "test"
# HTTP 404/410 떨어지면 webhook URL 만료. Discord 서버에서 재발급
```

---

## 끝

이 가이드대로 진행하면 30분 안에 첫 챌린지 시도까지 가능하다.
