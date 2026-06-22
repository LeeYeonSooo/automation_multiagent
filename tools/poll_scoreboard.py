#!/usr/bin/env python3
"""
poll_scoreboard.py — 백그라운드 데몬

기능:
1. 5분마다 챌린지별 본인 EOA native balance 조회
2. 5분마다 외부 scoreboard에서 실제 점수 fetch → actual_scores.json 갱신
3. balance 변동 있으면 Discord 알림
4. 60분간 변동 없으면 stuck으로 표시, brain에 알림

실행:
  python3 tools/poll_scoreboard.py

주의:
- max_pts는 모름 (CLAUDE.md §5). 자체 score 추정 X.
- status.json에 score_estimate 박지 않음 (Codex의 wishful thinking 방지).
- 점수는 actual_scores.json 만 신뢰.
- scoreboard fetch는 SCOREBOARD_FETCH_URL + 선택적 SCOREBOARD_AUTH_HEADER 사용.
  endpoint 정보는 사용자가 .env에 박음. 미설정 시 fetch skip + warn.
"""

import os
import sys
import json
import time
import math
import fcntl
import subprocess
import urllib.request
import urllib.error
import re
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
os.chdir(ROOT)

# .env 로드
ENV = {}
env_file = ROOT / ".env"
if env_file.exists():
    for line in env_file.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        ENV[k.strip()] = v.strip()

CHALLENGES = {
    "ch1_uranium":        ENV.get("RPC_CH1_URANIUM", ""),
    "ch2_harvest":        ENV.get("RPC_CH2_HARVEST", ""),
    "ch3_feirari":        ENV.get("RPC_CH3_FEIRARI", ""),
    "ch4_superfluid":     ENV.get("RPC_CH4_SUPERFLUID", ""),
    "ch5_superfluid_v2":  ENV.get("RPC_CH5_SUPERFLUID_V2", ""),
}

ADDR = ENV.get("PUBLIC_ADDRESS", "0xc943edb4bb4439d65b81f2f60bc698411e910b14")
USERNAME = ENV.get("UPSIDE_USERNAME", "4gi_akali")
OUR_UUID = ENV.get("OUR_UUID", "")  # leaderboard JSON에서 우리 row 식별용
WEBHOOK = ENV.get("DISCORD_WEBHOOK_URL", "")
POLL_INT = int(ENV.get("SCORE_POLL_INTERVAL", "300"))  # 5min default
STUCK_MIN = int(ENV.get("STUCK_THRESHOLD_MIN", "60"))

SCOREBOARD_URL = ENV.get("SCOREBOARD_FETCH_URL", "")  # 사용자가 .env 에 박음
SCOREBOARD_AUTH = ENV.get("SCOREBOARD_AUTH_HEADER", "")  # 인증 불요 (anonymous OK)

# rwN -> challenge name 매핑 (leaderboard JSON의 scores 키)
RW_TO_CH = {
    "rw1": "ch1_uranium",
    "rw2": "ch2_harvest",
    "rw3": "ch3_feirari",
    "rw4": "ch4_superfluid",
    "rw5": "ch5_superfluid_v2",
}

LOG_DIR = ROOT / "logs"
LOG_DIR.mkdir(exist_ok=True)

ACTUAL_SCORES = ROOT / "actual_scores.json"
LOCK_FILE = LOG_DIR / "poll_scoreboard.lock"

# Max points per challenge (mentor-confirmed 2026-04-18). See CLAUDE.md §5.
# Score = minmax_scale(log1p(raw), 0.01, 1) × max_pts.
MAX_PTS = {
    "ch1_uranium":       10000,
    "ch2_harvest":       10000,
    "ch3_feirari":       10000,
    "ch4_superfluid":    15000,
    "ch5_superfluid_v2": 25000,
}


def log(msg):
    ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    line = f"[{ts}] {msg}"
    print(line, flush=True)
    with open(LOG_DIR / "scoreboard.log", "a") as f:
        f.write(line + "\n")


def get_balance(rpc):
    if not rpc:
        return None
    try:
        result = subprocess.run(
            ["cast", "balance", ADDR, "--rpc-url", rpc],
            capture_output=True, text=True, timeout=15
        )
        if result.returncode != 0:
            return None
        return int(result.stdout.strip())
    except (subprocess.TimeoutExpired, ValueError, FileNotFoundError):
        return None


def update_status_balance_only(ch, balance_wei):
    """status.json 의 balance_delta_wei + last_update만 갱신. score_estimate 안 박음."""
    sf = ROOT / "challenges" / ch / "status.json"
    sf.parent.mkdir(parents=True, exist_ok=True)
    data = {}
    if sf.exists():
        try:
            data = json.loads(sf.read_text())
        except Exception:
            pass
    data["challenge"] = ch
    data["balance_delta_wei"] = str(balance_wei)
    data["last_update"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    # 폐기된 필드 제거
    data.pop("score_estimate", None)
    sf.write_text(json.dumps(data, indent=2))


def notify(msg, level="info"):
    flag = ""
    if level == "warn": flag = "--warn"
    elif level == "critical": flag = "--critical"
    args = ["bash", str(ROOT / "tools" / "notify.sh"), msg]
    if flag:
        args.append(flag)
    try:
        subprocess.run(args, timeout=10, capture_output=True)
    except Exception as e:
        log(f"notify failed: {e}")


def fetch_scoreboard_html(url, auth_header=""):
    """Scoreboard HTML/JSON 가져오기. 인증 헤더 선택적."""
    req = urllib.request.Request(url)
    if auth_header:
        # "HeaderName: Value" 또는 "Cookie: session=..."
        if ":" in auth_header:
            k, v = auth_header.split(":", 1)
            req.add_header(k.strip(), v.strip())
    req.add_header("User-Agent", "Mozilla/5.0 (poll_scoreboard)")
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            return resp.read().decode("utf-8", errors="replace")
    except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError) as e:
        log(f"scoreboard fetch failed: {e}")
        return None


def parse_scoreboard(content, our_uuid):
    """
    Upside leaderboard 응답 파싱:
    {
      "users": [
        {"user_uuid": "...", "total": ..., "scores": {"rw1": ..., "rw2": ..., ...},
         "last_score_time_ns": ...},
        ...
      ]
    }
    """
    if not content:
        return None
    try:
        data = json.loads(content)
    except json.JSONDecodeError as e:
        log(f"scoreboard JSON decode failed: {e}")
        return None

    users = data.get("users") or []
    if not users:
        log("scoreboard JSON has no 'users' field")
        return None

    # 우리 row 찾기
    our_row = next((u for u in users if u.get("user_uuid") == our_uuid), None)
    if our_row is None:
        log(f"our_uuid {our_uuid[:16]}... not in leaderboard (size={len(users)})")
        # uuid 매칭 실패 시에도 leader 정보는 반환하도록 계속 진행
        our_row = {"scores": {}}

    # 각 챌린지별 leader 찾기
    result = {}
    for rw, ch in RW_TO_CH.items():
        our_score = our_row.get("scores", {}).get(rw)
        # leader = scores[rw] 최댓값
        best_score = -1.0
        best_uuid = None
        for u in users:
            s = u.get("scores", {}).get(rw)
            if s is None:
                continue
            if s > best_score:
                best_score = s
                best_uuid = u.get("user_uuid")
        leader_label = "us" if best_uuid == our_uuid else (best_uuid[:12] + "..." if best_uuid else None)
        gap = (best_score - our_score) if (our_score is not None and best_score >= 0) else None
        result[ch] = {
            "score": our_score,
            "leader": leader_label,
            "leader_uuid": best_uuid,
            "leader_score": best_score if best_score >= 0 else None,
            "gap_to_leader": gap,
        }

    # total 정보도 함께
    our_total = our_row.get("total")
    leader_total = max((u.get("total", 0) for u in users), default=0)
    leader_total_uuid = next((u.get("user_uuid") for u in users if u.get("total", -1) == leader_total), None)
    result["_total"] = {
        "us": our_total,
        "leader_total": leader_total,
        "leader_uuid": leader_total_uuid,
        "is_us_leader": (leader_total_uuid == our_uuid),
    }
    return result


def update_actual_scores(parsed):
    """parsed 결과로 actual_scores.json 갱신. 기존 메타데이터/note 보존."""
    if not parsed:
        return False

    cur = {}
    if ACTUAL_SCORES.exists():
        try:
            cur = json.loads(ACTUAL_SCORES.read_text())
        except Exception:
            pass

    changed = False
    ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    for ch, info in parsed.items():
        if ch.startswith("_"):
            continue  # _total 같은 메타
        new_score = info.get("score")
        if new_score is None:
            continue
        # round to 2 decimals for clean storage
        new_score_r = round(new_score, 2)
        old = cur.get(ch, {})
        old_score = old.get("score")
        leader_score = info.get("leader_score")
        leader_score_r = round(leader_score, 2) if leader_score is not None else None
        gap = info.get("gap_to_leader")
        gap_r = round(gap, 2) if gap is not None else None

        if old_score != new_score_r:
            changed = True
            log(f"{ch}: score {old_score} -> {new_score_r} (leader_gap={gap_r})")

        max_pts = MAX_PTS.get(ch)
        potential = round(max_pts - new_score_r, 2) if max_pts is not None and new_score_r is not None else None
        cur[ch] = {
            "score": new_score_r,
            "max_pts": max_pts,
            "potential": potential,
            "leader": info.get("leader"),
            "leader_uuid": info.get("leader_uuid"),
            "leader_score": leader_score_r,
            "gap_to_leader": gap_r,
            "note": old.get("note", ""),
        }

    # Total 메타데이터
    tot = parsed.get("_total", {})
    if tot:
        cur["_total_us"] = round(tot.get("us") or 0, 2)
        cur["_total_leader"] = round(tot.get("leader_total") or 0, 2)
        cur["_total_leader_uuid"] = tot.get("leader_uuid")
        cur["_we_are_total_leader"] = tot.get("is_us_leader", False)
        cur["_total_gap_to_leader"] = round((tot.get("leader_total") or 0) - (tot.get("us") or 0), 2)

    cur["_last_updated"] = ts
    cur["_last_updated_by"] = "poll_scoreboard.py"

    # 항상 write (changed 여부와 무관 — last_updated/total 갱신 필요)
    ACTUAL_SCORES.write_text(json.dumps(cur, indent=2, ensure_ascii=False))
    return changed


def poll_scoreboard_once():
    """1회 scoreboard fetch + actual_scores.json 갱신. archive.sh successful 직후 즉시 호출 가능."""
    if not SCOREBOARD_URL:
        log("SCOREBOARD_FETCH_URL not set in .env — skipping scoreboard poll")
        return False
    if not OUR_UUID:
        log("OUR_UUID not set in .env — cannot identify our row")
        return False
    content = fetch_scoreboard_html(SCOREBOARD_URL, SCOREBOARD_AUTH)
    if not content:
        return False
    parsed = parse_scoreboard(content, OUR_UUID)
    if not parsed:
        log("scoreboard parse failed (format mismatch)")
        return False
    return update_actual_scores(parsed)


def main():
    # 단일 실행 모드 (archive.sh hook 등에서 사용). lock 안 잡음 — 짧고 동시 실행 가능.
    if "--once" in sys.argv:
        ok = poll_scoreboard_once()
        sys.exit(0 if ok else 1)

    # Daemon mode: exclusive flock to prevent duplicate instances.
    lock_fh = open(LOCK_FILE, "w")
    try:
        fcntl.flock(lock_fh.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        log(f"another poll_scoreboard instance alive (lock held at {LOCK_FILE}); exiting")
        sys.exit(0)
    lock_fh.write(f"{os.getpid()}\n")
    lock_fh.flush()

    log(f"poll_scoreboard started; interval={POLL_INT}s, stuck_threshold={STUCK_MIN}min, pid={os.getpid()}")
    log(f"scoreboard fetch: {'enabled' if SCOREBOARD_URL else 'DISABLED (set SCOREBOARD_FETCH_URL in .env)'}")
    notify("Scoreboard poller started")

    last_balance = {ch: 0 for ch in CHALLENGES}
    last_change = {ch: time.time() for ch in CHALLENGES}
    stuck_notified = {ch: False for ch in CHALLENGES}

    while True:
        # 1. balance 폴링
        for ch, rpc in CHALLENGES.items():
            if not rpc:
                continue

            bal = get_balance(rpc)
            if bal is None:
                log(f"{ch}: balance fetch failed")
                continue

            update_status_balance_only(ch, bal)

            if bal != last_balance[ch]:
                delta = bal - last_balance[ch]
                delta_eth = delta / 1e18
                log(f"{ch}: balance changed by {delta} wei ({delta_eth:+.4f} native)")
                if last_balance[ch] > 0 or bal > 0:
                    notify(f"{ch}: Δ {delta_eth:+.4f} native (실제 점수는 actual_scores.json 참고)")
                last_balance[ch] = bal
                last_change[ch] = time.time()
                stuck_notified[ch] = False
            else:
                idle_min = (time.time() - last_change[ch]) / 60
                if idle_min >= STUCK_MIN and not stuck_notified[ch]:
                    sf = ROOT / "challenges" / ch / "status.json"
                    if sf.exists():
                        try:
                            d = json.loads(sf.read_text())
                            state = d.get("state", "")
                            if state not in ("exploited", "abandoned", "report_drafted"):
                                d["needs_human"] = True
                                d["notes"] = (d.get("notes", "") + f" | STUCK: {int(idle_min)}min no balance change").strip()
                                sf.write_text(json.dumps(d, indent=2))
                                notify(f"STUCK: {ch} ({int(idle_min)}min no change). Trigger creative escalation.", level="warn")
                                stuck_notified[ch] = True
                        except Exception as e:
                            log(f"stuck check fail for {ch}: {e}")

        # 2. scoreboard 폴링 (실제 점수)
        try:
            poll_scoreboard_once()
        except Exception as e:
            log(f"scoreboard poll exception: {e}")

        time.sleep(POLL_INT)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        log("poll_scoreboard stopped")
