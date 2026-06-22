#!/usr/bin/env python3
import json
import os
import sys
import urllib.request
from pathlib import Path


TRANSFER_TOPIC = "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"
BALANCE_OF_SELECTOR = "70a08231"


class Rpc:
    def __init__(self, url: str):
        self.url = url
        self.req_id = 0

    def call(self, payload: dict) -> dict:
        self.req_id += 1
        req = urllib.request.Request(
            self.url,
            data=json.dumps({**payload, "jsonrpc": "2.0", "id": self.req_id}).encode(),
            headers={"content-type": "application/json"},
        )
        with urllib.request.urlopen(req, timeout=45) as resp:
            return json.loads(resp.read())


def main() -> None:
    if len(sys.argv) != 5:
        raise SystemExit("usage: scan_wrapper_holders.py <token> <symbol> <deploy_block> <out_path>")

    rpc_url = os.environ["RPC_CH4_SUPERFLUID"]
    token = sys.argv[1]
    symbol = sys.argv[2]
    deploy_block = int(sys.argv[3])
    out_path = Path(sys.argv[4])

    rpc = Rpc(rpc_url)
    head_resp = rpc.call({"method": "eth_blockNumber", "params": []})
    head = int(head_resp["result"], 16)

    holders = set()
    touched = 0
    start = deploy_block
    chunk = 10_000

    while start <= head:
        end = min(start + chunk - 1, head)
        resp = rpc.call(
            {
                "method": "eth_getLogs",
                "params": [
                    {
                        "fromBlock": hex(start),
                        "toBlock": hex(end),
                        "address": token,
                        "topics": [TRANSFER_TOPIC],
                    }
                ],
            }
        )
        logs = resp.get("result", [])
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
        if ((start - deploy_block) // chunk) % 50 == 0:
            print(
                f"scan_progress|symbol={symbol}|from={start}|to={end}|logs={len(logs)}|holders={len(holders)}",
                flush=True,
            )
        start = end + 1

    rows = []
    for idx, address in enumerate(sorted(holders), 1):
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
        bal = int(resp["result"], 16)
        if bal > 0:
            rows.append({"addr": address, "balance": str(bal)})
        if idx % 200 == 0:
            print(
                f"balance_progress|symbol={symbol}|checked={idx}|positive={len(rows)}",
                flush=True,
            )

    rows.sort(key=lambda row: int(row["balance"]), reverse=True)
    payload = {
        "token": token,
        "symbol": symbol,
        "deployment_block": deploy_block,
        "fork_block": head,
        "touched_logs": touched,
        "holder_count": len(rows),
        "holders": rows,
    }
    out_path.write_text(json.dumps(payload, indent=2) + "\n")
    print(
        f"scan_done|symbol={symbol}|holders={len(rows)}|top_balance={rows[0]['balance'] if rows else 0}|path={out_path}",
        flush=True,
    )


if __name__ == "__main__":
    main()
