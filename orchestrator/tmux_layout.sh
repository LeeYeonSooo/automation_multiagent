#!/usr/bin/env bash
# tmux_layout.sh - 3-pane 레이아웃 자동 구성
#
# 레이아웃:
#   ┌────────────────────────────────────┬───────────────┐
#   │  pane 0: Claude Code (brain)       │  pane 2:      │
#   ├────────────────────────────────────┤  monitor      │
#   │  pane 1: Codex (hands, 수동 호출)  │               │
#   └────────────────────────────────────┴───────────────┘
#
# 노트북 뚜껑 닫아도 tmux 세션은 살아있음.
# 다시 들어가려면: tmux a -t upside

set -e

cd "$(dirname "$0")/.."
WORK_DIR="$(pwd)"

if ! command -v tmux >/dev/null 2>&1; then
    echo "ERROR: tmux가 설치되어 있지 않다."
    echo "  brew install tmux"
    exit 1
fi

# .env 로드
if [ -f .env ]; then
    set -a; source .env; set +a
else
    echo "ERROR: .env 파일이 없다. ./bootstrap.sh 먼저 실행해라."
    exit 1
fi

SESSION="${TMUX_SESSION:-upside}"

# 이미 있으면 첨부만
if tmux has-session -t "$SESSION" 2>/dev/null; then
    echo "기존 tmux 세션 [$SESSION] 발견. 첨부한다..."
    tmux a -t "$SESSION"
    exit 0
fi

# 새 세션 생성 (detached)
tmux new-session -d -s "$SESSION" -c "$WORK_DIR" -n main

# pane 0 (왼쪽 위): Claude Code
tmux send-keys -t "$SESSION:main.0" "clear" C-m
tmux send-keys -t "$SESSION:main.0" "echo '=== Brain pane (Claude Code) ==='" C-m
tmux send-keys -t "$SESSION:main.0" "echo '시작: claude'" C-m
tmux send-keys -t "$SESSION:main.0" "echo '첫 prompt 추천: @CLAUDE.md 읽고 PROGRESS.md 확인 후 ch1_uranium 시작'" C-m
tmux send-keys -t "$SESSION:main.0" "echo ''" C-m

# 가로 분할 (위/아래)
tmux split-window -v -t "$SESSION:main.0" -c "$WORK_DIR"

# pane 1 (왼쪽 아래): Codex 수동 호출용 (대화형, 백그라운드 모드 시 추가 세션 spawn됨)
tmux send-keys -t "$SESSION:main.1" "clear" C-m
tmux send-keys -t "$SESSION:main.1" "echo '=== Hands pane (Codex 수동 모드) ==='" C-m
tmux send-keys -t "$SESSION:main.1" "echo '대부분 Brain의 delegate.sh가 자동 호출.'" C-m
tmux send-keys -t "$SESSION:main.1" "echo '수동으로 codex 부르고 싶을 때 여기서 직접 실행.'" C-m
tmux send-keys -t "$SESSION:main.1" "echo ''" C-m

# 세로 분할 (오른쪽 영역 만들기)
tmux split-window -h -t "$SESSION:main.0" -c "$WORK_DIR"
# 위 명령으로 pane 2가 생김 (오른쪽). 비율 조정
tmux resize-pane -t "$SESSION:main.2" -x 60

# pane 2 (오른쪽 전체): monitor
tmux send-keys -t "$SESSION:main.2" "clear" C-m
tmux send-keys -t "$SESSION:main.2" "echo '=== Monitor pane ==='" C-m
tmux send-keys -t "$SESSION:main.2" "echo '점수 + 진행 상황 1분마다 갱신'" C-m
tmux send-keys -t "$SESSION:main.2" "echo ''" C-m
# 모니터 루프 시작
tmux send-keys -t "$SESSION:main.2" "while true; do clear; ./tools/score.sh 2>/dev/null; echo; ./tools/status.sh 2>/dev/null | head -50; echo; echo '(refresh: 60s)'; sleep 60; done" C-m

# 별도 윈도우: 점수 폴링 (백그라운드 데몬)
tmux new-window -t "$SESSION" -n poller -c "$WORK_DIR"
tmux send-keys -t "$SESSION:poller" "clear" C-m
tmux send-keys -t "$SESSION:poller" "echo '=== Score poller ==='" C-m
tmux send-keys -t "$SESSION:poller" "echo '5분마다 외부 scoreboard 폴링. stuck 감지 시 알림.'" C-m
tmux send-keys -t "$SESSION:poller" "python3 tools/poll_scoreboard.py" C-m

# 메인 윈도우로 복귀, claude 시작
tmux select-window -t "$SESSION:main"
tmux select-pane -t "$SESSION:main.0"

# Claude Code 자동 시작 — --dangerously-skip-permissions로 개별 툴 컨펌 스킵.
# 안전장치는 hooks/pre_tool_use.sh가 계속 담당 (rm 외부경로, git push, mainnet RPC 차단 등).
tmux send-keys -t "$SESSION:main.0" "claude --dangerously-skip-permissions" C-m

# 첨부
tmux a -t "$SESSION"
