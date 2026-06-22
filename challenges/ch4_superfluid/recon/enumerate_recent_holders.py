#!/usr/bin/env python3
import json
import os
import sys
import time
import urllib.request
from pathlib import Path

TRANSFER_TOPIC = "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"
BALANCE_OF_SELECTOR = "70a08231"
TOKENS = [
    ("DAIx", "0x1305f6b6df9dc47159d12eb7ac2804d4a33173c2", 12122878),
    ("ETHx", "0x27e1e4e6bc79d93032abef01025811b7e4727e85", 12122800),
    ("MATICx", "0x3ad736904e9e65189c3000c7dd2c8ac8bb7cd4e3", 11651904),
    ("USDCx", "0xcaa7349cea390f89641fe306d93591f87595dc1f", 12122841),
    ("WBTCx", "0x4086ebf75233e8492f1bcda41c7f2a8288c2fb92", 12122910),
]


class Rpc:
    def __init__(self, url: str):
        self.url = url
        self.req_id = 0

    def call(self, payload):
        if isinstance(payload, dict):
            self.req_id += 1
            payload = {**payload, "jsonrpc": "2.0", "id": self.req_id}
        else:
            batch = []
            for item in payload:
                self.req_id += 1
                batch.append({**item, "jsonrpc": "2.0", "id": self.req_id})
            payload = batch

        req = urllib.request.Request(
            self.url,
            data=json.dumps(payload).encode(),
            headers={"content-type": "application/json"},
        )
        with urllib.request.urlopen(req, timeout=45) as resp:
            return json.loads(resp.read())


def scan_window(rpc: Rpc, token: str, start: int, end: int):
    holders = set()
    touched = 0
    block = start
    while block <= end:
        to_block = min(block + 9_999, end)
        resp = rpc.call(
            {
                "method": "eth_getLogs",
                "params": [
                    {
                        "fromBlock": hex(block),
                        "toBlock": hex(to_block),
                        "address": token,
                        "topics": [TRANSFER_TOPIC],
                    }
                ],
            }
        )
        if "result" not in resp:
            raise RuntimeError(f"eth_getLogs failed for {token} {block}-{to_block}: {resp}")

        logs = resp["result"]
        touched += len(logs)
        for log in logs:
            topics = log.get("topics", [])
            if len(topics) < 3:
                continue
            from_addr = "0x" + topics[1][-40:]
            to_addr = "0x" + topics[2][-40:]
            if int(from_addr, 16) != 0:
                holders.add(from_addr.lower())
            if int(to_addr, 16) != 0:
                holders.add(to_addr.lower())
        block = to_block + 1
    return holders, touched


def balance_of(rpc: Rpc, token: str, address: str) -> int:
    resp = rpc.call(
        {
            "method": "eth_call",
            "params": [
                {
                    "to": token,
                    "data": "0x" + BALANCE_OF_SELECTOR + address[2:].rjust(64, "0"),
                },
                "latest",
            ],
        }
    )
    if "result" not in resp:
        raise RuntimeError(f"eth_call failed for {token} {address}: {resp}")
    return int(resp["result"], 16)


def main():
    rpc_url = os.environ.get("RPC_CH4_SUPERFLUID")
    if not rpc_url:
        raise SystemExit("RPC_CH4_SUPERFLUID is not set")

    repo_root = Path(__file__).resolve().parents[3]
    output_path = repo_root / "challenges/ch4_superfluid/recon/victims.json"
    recent_span = int(os.environ.get("CH4_RECENT_SPAN", "500000"))
    deployment_window = int(os.environ.get("CH4_DEPLOY_WINDOW", "50000"))
    only_symbols_raw = os.environ.get("CH4_ONLY_SYMBOLS", "")
    only_symbols = {
        symbol.strip().lower() for symbol in only_symbols_raw.split(",") if symbol.strip()
    }

    rpc = Rpc(rpc_url)
    head_resp = rpc.call({"method": "eth_blockNumber", "params": []})
    if "result" not in head_resp:
        raise RuntimeError(f"eth_blockNumber failed: {head_resp}")
    head = int(head_resp["result"], 16)
    recent_start = max(0, head - recent_span)

    if output_path.exists():
        try:
            result = json.loads(output_path.read_text())
        except json.JSONDecodeError:
            result = {}
    else:
        result = {}

    if not isinstance(result, dict):
        result = {}
    result["fork_block"] = head
    result["generated_at"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    result["scan_strategy"] = {
        "recent_window_start": recent_start,
        "recent_window_end": head,
        "deployment_window_size": deployment_window,
    }
    result.setdefault("tokens", [])
    result.setdefault("summary", {})

    tokens = TOKENS
    if only_symbols:
        tokens = [token for token in TOKENS if token[0].lower() in only_symbols]

    for symbol, token, deploy_block in tokens:
        holders = set()
        touched = 0

        early_holders, early_touched = scan_window(
            rpc, token, deploy_block, min(head, deploy_block + deployment_window - 1)
        )
        holders |= early_holders
        touched += early_touched

        if recent_start <= head:
            recent_holders, recent_touched = scan_window(rpc, token, recent_start, head)
            holders |= recent_holders
            touched += recent_touched

        victims = []
        ordered_holders = sorted(holders)
        for addr in ordered_holders:
            balance = balance_of(rpc, token, addr)
            if balance > 0:
                victims.append({"addr": addr, "balance": str(balance)})

        victims.sort(key=lambda item: int(item["balance"]), reverse=True)
        top = victims[0] if victims else None
        print(
            f"{symbol}: touched_logs={touched} holders={len(victims)} top={top}",
            file=sys.stderr,
            flush=True,
        )

        token_entry = {
            "symbol": symbol,
            "token": token,
            "deployment_block": deploy_block,
            "touched_addresses": touched,
            "holder_count": len(victims),
            "victims": victims,
        }
        result["tokens"] = [entry for entry in result["tokens"] if entry.get("symbol") != symbol]
        result["tokens"].append(token_entry)
        result["tokens"].sort(key=lambda entry: entry.get("symbol", ""))
        result["summary"][symbol] = {
            "token": token,
            "deployment_block": deploy_block,
            "touched_addresses": touched,
            "holder_count": len(victims),
            "top_holder": top["addr"] if top else None,
            "top_balance": top["balance"] if top else "0",
        }
        output_path.write_text(json.dumps(result, indent=2) + "\n")

    output_path.write_text(json.dumps(result, indent=2) + "\n")
    print(output_path)


if __name__ == "__main__":
    main()
