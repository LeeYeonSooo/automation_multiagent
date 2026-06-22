#!/usr/bin/env python3
"""
Enumerate ALL Fuse pools for CEther markets with significant ETH balance.
Uses batch JSON-RPC where possible, falls back to sequential.
"""

import urllib.request
import json
import sys
import os
import time

RPC = os.environ.get("RPC_CH3_FEIRARI")
if not RPC:
    print("ERROR: RPC_CH3_FEIRARI not set")
    sys.exit(1)

FUSE_POOL_DIR = "0x835482FE0532f169024d5E9410199369aAD5C77E"
BLOCK = "latest"

ALREADY_EXPLOITED = {8, 27, 36, 63, 79, 146, 156, 182}

def rpc_call_obj(method, params, id=1):
    return {"jsonrpc": "2.0", "id": id, "method": method, "params": params}

def send_single(method, params, retries=3):
    """Send a single JSON-RPC call."""
    payload = json.dumps(rpc_call_obj(method, params)).encode()
    for attempt in range(retries):
        try:
            req = urllib.request.Request(RPC, data=payload, headers={"Content-Type": "application/json"})
            resp = urllib.request.urlopen(req, timeout=30)
            return json.loads(resp.read())
        except Exception as e:
            if attempt < retries - 1:
                time.sleep(1)
                continue
            return {"error": str(e)}

def send_batch(calls, retries=3):
    """Try batch RPC. If server doesn't support it, fall back to sequential."""
    if not calls:
        return []
    payload = json.dumps(calls).encode()
    for attempt in range(retries):
        try:
            req = urllib.request.Request(RPC, data=payload, headers={"Content-Type": "application/json"})
            resp = urllib.request.urlopen(req, timeout=120)
            raw = resp.read()
            results = json.loads(raw)
            if isinstance(results, list):
                # Build map by id
                by_id = {}
                for r in results:
                    rid = r.get("id")
                    if rid is not None:
                        by_id[rid] = r
                # Return in order of calls
                ordered = []
                for c in calls:
                    cid = c["id"]
                    if cid in by_id:
                        ordered.append(by_id[cid])
                    else:
                        ordered.append({"id": cid, "error": "missing from response"})
                return ordered
            else:
                # Server returned single object - doesn't support batch
                # Fall back to sequential
                return send_sequential(calls)
        except Exception as e:
            if attempt < retries - 1:
                time.sleep(2)
                continue
            # Fall back to sequential on error
            return send_sequential(calls)

def send_sequential(calls):
    """Sequential fallback."""
    results = []
    for c in calls:
        payload = json.dumps(c).encode()
        try:
            req = urllib.request.Request(RPC, data=payload, headers={"Content-Type": "application/json"})
            resp = urllib.request.urlopen(req, timeout=30)
            r = json.loads(resp.read())
            r["id"] = c["id"]  # ensure id matches
            results.append(r)
        except Exception as e:
            results.append({"id": c["id"], "error": str(e)})
    return results

def chunked_batch(calls, chunk_size=30, delay=0.5):
    """Send calls in chunks."""
    all_results = []
    for start in range(0, len(calls), chunk_size):
        chunk = calls[start:start+chunk_size]
        results = send_batch(chunk)
        all_results.extend(results)
        if start + chunk_size < len(calls):
            time.sleep(delay)
    return all_results

def get_all_pools():
    """Get all pool comptroller addresses from FusePoolDirectory."""
    resp = send_single("eth_call", [{"to": FUSE_POOL_DIR, "data": "0xd88ff1f4"}, BLOCK])
    data = resp["result"][2:]

    offset = int(data[0:64], 16)
    arr_start = offset * 2
    arr_len = int(data[arr_start:arr_start+64], 16)

    offsets = []
    for i in range(arr_len):
        o = int(data[arr_start+64+i*64:arr_start+128+i*64], 16)
        offsets.append(o)

    pools = []
    for idx in range(arr_len):
        struct_start = arr_start + 64 + offsets[idx]*2
        name_offset = int(data[struct_start:struct_start+64], 16)
        creator = "0x" + data[struct_start+64+24:struct_start+128]
        comptroller = "0x" + data[struct_start+128+24:struct_start+192]

        name_start = struct_start + name_offset * 2
        name_len = int(data[name_start:name_start+64], 16)
        name_hex = data[name_start+64:name_start+64+name_len*2]
        try:
            name = bytes.fromhex(name_hex).decode("utf-8", errors="replace")
        except:
            name = f"<pool {idx}>"

        pools.append({
            "index": idx,
            "name": name,
            "comptroller": comptroller.lower(),
        })

    return pools

def get_all_markets_batch(pools):
    """Batch getAllMarkets() on each comptroller."""
    calls = []
    for i, p in enumerate(pools):
        calls.append(rpc_call_obj("eth_call", [{"to": p["comptroller"], "data": "0xb0772d0b"}, BLOCK], id=i))

    results = chunked_batch(calls, chunk_size=30, delay=0.5)

    markets_map = {}
    for r in results:
        idx = r["id"]
        if "error" in r or "result" not in r:
            markets_map[idx] = []
            continue
        data = r["result"]
        if not data or data == "0x" or len(data) < 130:
            markets_map[idx] = []
            continue
        data = data[2:]
        try:
            offset = int(data[0:64], 16)
            arr_start = offset * 2
            arr_len = int(data[arr_start:arr_start+64], 16)
            addrs = []
            for j in range(arr_len):
                addr = "0x" + data[arr_start+64+j*64+24:arr_start+128+j*64]
                addrs.append(addr.lower())
            markets_map[idx] = addrs
        except:
            markets_map[idx] = []

    return markets_map

def check_is_cether(market_addrs):
    """Check underlying() on each market.
    CEther is identified by:
    - underlying() reverts (some implementations), OR
    - underlying() returns address(0) (Fuse CEther implementation)
    """
    addr_list = sorted(set(market_addrs))
    calls = []
    for i, addr in enumerate(addr_list):
        calls.append(rpc_call_obj("eth_call", [{"to": addr, "data": "0x6f307dc3"}, BLOCK], id=i))

    results = chunked_batch(calls, chunk_size=40, delay=0.5)

    cether_set = set()
    for r in results:
        idx = r["id"]
        addr = addr_list[idx]
        if "error" in r:
            # Reverted = CEther (some implementations)
            cether_set.add(addr)
        elif "result" in r:
            result = r["result"]
            if not result or result == "0x" or len(result) < 66:
                # No return data = CEther
                cether_set.add(addr)
            else:
                # Check if underlying == address(0) (Fuse CEther pattern)
                try:
                    underlying_addr = int(result, 16)
                    if underlying_addr == 0:
                        cether_set.add(addr)
                except:
                    pass

    return cether_set

def get_eth_balances_batch(addrs):
    """Get ETH balance for each address."""
    addr_list = sorted(set(addrs))
    calls = []
    for i, addr in enumerate(addr_list):
        calls.append(rpc_call_obj("eth_getBalance", [addr, BLOCK], id=i))

    results = chunked_batch(calls, chunk_size=40, delay=0.5)

    balances = {}
    for r in results:
        idx = r["id"]
        addr = addr_list[idx]
        if "result" in r and r["result"]:
            try:
                balances[addr] = int(r["result"], 16)
            except:
                balances[addr] = 0
        else:
            balances[addr] = 0

    return balances

def get_cash_batch(addrs):
    """Call getCash() on each market."""
    addr_list = sorted(set(addrs))
    calls = []
    for i, addr in enumerate(addr_list):
        calls.append(rpc_call_obj("eth_call", [{"to": addr, "data": "0x3b1d21a2"}, BLOCK], id=i))

    results = chunked_batch(calls, chunk_size=40, delay=0.5)

    cash_map = {}
    for r in results:
        idx = r["id"]
        addr = addr_list[idx]
        if "result" in r and r["result"] and len(r["result"]) >= 66:
            try:
                cash_map[addr] = int(r["result"], 16)
            except:
                cash_map[addr] = 0
        else:
            cash_map[addr] = 0

    return cash_map

def check_borrow_paused_batch(comptroller_market_pairs):
    """Check borrowGuardianPaused(address) for (comptroller, market) pairs."""
    calls = []
    pair_list = list(comptroller_market_pairs)
    for i, (comp, mkt) in enumerate(pair_list):
        data = "0x6d154ea5" + mkt[2:].lower().zfill(64)
        calls.append(rpc_call_obj("eth_call", [{"to": comp, "data": data}, BLOCK], id=i))

    results = chunked_batch(calls, chunk_size=30, delay=0.5)

    paused_map = {}
    for r in results:
        idx = r["id"]
        comp, mkt = pair_list[idx]
        if "result" in r and r["result"] and len(r["result"]) >= 66:
            try:
                val = int(r["result"], 16)
                paused_map[(comp, mkt)] = bool(val)
            except:
                paused_map[(comp, mkt)] = None
        else:
            paused_map[(comp, mkt)] = None

    return paused_map

def check_mint_paused_batch(comptroller_market_pairs):
    """Check mintGuardianPaused(address) for (comptroller, market) pairs."""
    calls = []
    pair_list = list(comptroller_market_pairs)
    for i, (comp, mkt) in enumerate(pair_list):
        # mintGuardianPaused(address) selector = 0x731f0c2b
        data = "0x731f0c2b" + mkt[2:].lower().zfill(64)
        calls.append(rpc_call_obj("eth_call", [{"to": comp, "data": data}, BLOCK], id=i))

    results = chunked_batch(calls, chunk_size=30, delay=0.5)

    paused_map = {}
    for r in results:
        idx = r["id"]
        comp, mkt = pair_list[idx]
        if "result" in r and r["result"] and len(r["result"]) >= 66:
            try:
                val = int(r["result"], 16)
                paused_map[(comp, mkt)] = bool(val)
            except:
                paused_map[(comp, mkt)] = None
        else:
            paused_map[(comp, mkt)] = None

    return paused_map

def main():
    print("=" * 100)
    print("FUSE POOL CETHER ENUMERATION (ch3_feirari)")
    print("=" * 100)

    # Step 1: Get all pools
    print("\n[1/6] Fetching all pools from FusePoolDirectory...")
    pools = get_all_pools()
    print(f"      Found {len(pools)} pools")

    # Step 2: Get markets for each pool
    print("\n[2/6] Fetching markets for each comptroller...")
    markets_map = get_all_markets_batch(pools)

    all_markets = set()
    pool_to_markets = {}
    for i, p in enumerate(pools):
        mkts = markets_map.get(i, [])
        pool_to_markets[i] = mkts
        all_markets.update(mkts)

    total_markets = sum(len(v) for v in pool_to_markets.values())
    print(f"      Total market instances: {total_markets}, Unique addresses: {len(all_markets)}")

    # Step 3: Identify CEther markets
    print("\n[3/6] Checking underlying() to identify CEther markets...")
    cether_set = check_is_cether(all_markets)
    print(f"      Found {len(cether_set)} unique CEther addresses")

    # Step 4: Get ETH balances and getCash
    print("\n[4/6] Fetching ETH balance and getCash for CEther markets...")
    eth_balances = get_eth_balances_batch(cether_set)
    cash_values = get_cash_batch(cether_set)

    # Step 5: Build per-pool results (filter > 0.01 ETH)
    print("\n[5/6] Building per-pool results...")
    results = []
    comp_mkt_pairs = []

    for i, p in enumerate(pools):
        mkts = pool_to_markets.get(i, [])
        for mkt in mkts:
            if mkt in cether_set:
                bal = eth_balances.get(mkt, 0)
                cash = cash_values.get(mkt, 0)
                effective = max(bal, cash)
                if effective > 0.01e18:
                    entry = {
                        "pool_index": i,
                        "pool_name": p["name"],
                        "comptroller": p["comptroller"],
                        "cether": mkt,
                        "eth_balance_wei": bal,
                        "eth_balance": bal / 1e18,
                        "getCash_wei": cash,
                        "getCash": cash / 1e18,
                        "already_exploited": i in ALREADY_EXPLOITED,
                    }
                    results.append(entry)
                    comp_mkt_pairs.append((p["comptroller"], mkt))

    # Step 6: Check borrow and mint guardian paused
    print(f"\n[6/6] Checking borrowGuardianPaused and mintGuardianPaused for {len(comp_mkt_pairs)} markets...")
    borrow_paused = check_borrow_paused_batch(comp_mkt_pairs)
    mint_paused = check_mint_paused_batch(comp_mkt_pairs)

    for r in results:
        key = (r["comptroller"], r["cether"])
        r["borrow_paused"] = borrow_paused.get(key)
        r["mint_paused"] = mint_paused.get(key)

    # Sort by ETH balance descending
    results.sort(key=lambda x: x["eth_balance_wei"], reverse=True)

    # Output
    print("\n" + "=" * 100)
    print("RESULTS: CEther markets with > 0.01 ETH")
    print("=" * 100)
    print(f"{'Pool':>5} {'ETH Bal':>12} {'getCash':>12} {'BorPsd':>7} {'MntPsd':>7} {'Status':>10}  Name")
    print("-" * 100)

    total_eth = 0
    total_unexploited = 0
    unexploited_entries = []

    for r in results:
        status = "DONE" if r["already_exploited"] else "NEW"
        bp = "Y" if r["borrow_paused"] else ("N" if r["borrow_paused"] is False else "?")
        mp = "Y" if r["mint_paused"] else ("N" if r["mint_paused"] is False else "?")
        print(f"{r['pool_index']:>5} {r['eth_balance']:>12.4f} {r['getCash']:>12.4f} {bp:>7} {mp:>7} {status:>10}  {r['pool_name'][:45]}")
        print(f"      cether={r['cether']}  comptroller={r['comptroller']}")
        total_eth += r["eth_balance"]
        if not r["already_exploited"]:
            total_unexploited += r["eth_balance"]
            unexploited_entries.append(r)

    print("-" * 100)
    print(f"\nSUMMARY:")
    print(f"  Total pools with CEther > 0.01 ETH:  {len(results)}")
    print(f"  Total ETH across all CEther markets:  {total_eth:.4f} ETH")
    print(f"  Already exploited:                    {len(results) - len(unexploited_entries)} pools")
    print(f"  NEW (unexploited):                    {len(unexploited_entries)} pools")
    print(f"  Total unexploited ETH:                {total_unexploited:.4f} ETH")

    if unexploited_entries:
        print(f"\n{'='*100}")
        print("UNEXPLOITED POOLS (sorted by ETH balance):")
        print(f"{'='*100}")
        for r in unexploited_entries:
            bp = "Y" if r["borrow_paused"] else ("N" if r["borrow_paused"] is False else "?")
            mp = "Y" if r["mint_paused"] else ("N" if r["mint_paused"] is False else "?")
            print(f"  Pool #{r['pool_index']:>3}: {r['eth_balance']:>10.4f} ETH (cash={r['getCash']:.4f})  bor={bp} mnt={mp}  {r['pool_name'][:50]}")
            print(f"            cether={r['cether']}  comptroller={r['comptroller']}")

    # Save JSON
    json_path = "/Users/dldustn/Desktop/AssignmentC/challenges/ch3_feirari/cether_enumeration.json"
    with open(json_path, "w") as f:
        json.dump(results, f, indent=2, default=str)
    print(f"\nJSON saved to {json_path}")

if __name__ == "__main__":
    main()
