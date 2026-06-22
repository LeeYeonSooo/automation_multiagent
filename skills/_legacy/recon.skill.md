# recon.skill.md

Primary consumer: Codex (executor). Read during every `recon` task and any time you need to derive a proxy implementation, fetch a verified ABI, or pick a fork block.

The brain (Claude Code) is NOT supposed to run `forge` / `cast` / `curl` itself. Everything in this file is for Codex to execute.

---

## 1. Fast chain facts (first command every recon)

Use `tools/recon.sh` helpers before hand-rolling RPC calls — they already know the per-challenge RPC env var and redact secrets.

```bash
./tools/recon.sh chain_info ch1   # -> {challenge, chain_id, block_number, gas_limit, rpc_url_redacted}
./tools/recon.sh chain_info ch2
./tools/recon.sh chain_info ch3
./tools/recon.sh chain_info ch4
./tools/recon.sh chain_info ch5
```

Write the JSON straight to `challenges/<ch>/recon/chain_info.json`. The brain reads this to know the fork block, and PoCs use it as the `vm.createSelectFork` second argument.

Direct `cast` equivalents (when you need extras):

```bash
cast chain-id        --rpc-url "$RPC_CH1_URANIUM"
cast block-number    --rpc-url "$RPC_CH1_URANIUM"
cast block latest gasLimit    --rpc-url "$RPC_CH1_URANIUM"
cast block latest timestamp   --rpc-url "$RPC_CH1_URANIUM"
cast client          --rpc-url "$RPC_CH1_URANIUM"   # useful to tell erigon vs geth archive
```

Expected chain IDs per challenge (confirm, do not assume):

| Challenge | Chain | Expected chain_id |
|---|---|---|
| ch1_uranium | BSC | 56 |
| ch2_harvest | Ethereum | 1 |
| ch3_feirari | Ethereum | 1 |
| ch4_superfluid | Polygon | 137 |
| ch5_superfluid_v2 | Polygon | 137 |

---

## 2. Proxy detection — EIP-1967 slots

EIP-1967 reserves three well-known storage slots so proxies and tooling can agree without an interface. These are the canonical slots — memorize them:

| Slot purpose | Slot (hex) |
|---|---|
| Implementation | `0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc` |
| Admin | `0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103` |
| Beacon | `0xa3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6cb3582b35133d50` |

Each is `keccak256("eip1967.proxy.<name>") - 1`. A proxy that follows the spec stores the 20-byte implementation address right-aligned in the 32-byte slot — you pull the last 40 hex chars as the address.

Use the wrapper:

```bash
./tools/recon.sh impl_addr "$RPC_CH3_FEIRARI" 0xCFEtherProxyAddress
# prints: 0x<impl>
```

Or hand-roll:

```bash
SLOT=0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc
RAW=$(cast storage 0xProxyAddr $SLOT --rpc-url "$RPC_CH3_FEIRARI")
echo "impl = 0x${RAW:26}"
```

If the impl slot is zero:
- check the admin slot (some proxies put admin there, impl elsewhere)
- check the beacon slot; if non-zero, fetch the beacon contract and call `implementation()`
- the proxy may be EIP-897 (older). Call `proxyType()` and `implementation()` directly via `cast call`
- it may be UUPS (implementation stores upgrade logic, same 1967 slot though)
- it may be Transparent-admin (OpenZeppelin) with the same slot; admin-only `upgradeTo`
- it may be a non-standard `Diamond` (EIP-2535) — `facetAddress(bytes4)` per selector

When you're not sure, `cast code 0xProxyAddr | head -c 200` — short bytecode starting with `0x363d3d373d3d3d363d73<impl>...` is a minimal clone (EIP-1167); `impl` is literally bytes 10–29 of the runtime bytecode.

---

## 3. Verified source + ABI — Etherscan V2 multichain

Etherscan now has one unified API with a `chainid` query param. **One key works for all supported chains** (Ethereum, Polygon, BSC, Arbitrum, Base, …). Use this; do not call the legacy per-chain hosts.

```bash
curl -s "https://api.etherscan.io/v2/api?chainid=1&module=contract&action=getabi&address=0xAbc&apikey=$ETHERSCAN_API_KEY" | jq -r '.result'

curl -s "https://api.etherscan.io/v2/api?chainid=137&module=contract&action=getsourcecode&address=0xAbc&apikey=$ETHERSCAN_API_KEY" | jq -r '.result[0].SourceCode'
```

Wrappers (use these by default):

```bash
./tools/recon.sh fetch_abi ethereum 0xAbc > challenges/ch2_harvest/recon/abis/0xAbc.json
./tools/recon.sh fetch_abi polygon  0xAbc > challenges/ch4_superfluid/recon/abis/0xAbc.json
./tools/recon.sh fetch_abi bsc      0xAbc > challenges/ch1_uranium/recon/abis/0xAbc.json
./tools/recon.sh src      polygon  0xAbc > challenges/ch4_superfluid/recon/src/0xAbc.sol
```

Notes:
- `getsourcecode` returns a JSON array; `[0].SourceCode` may start with `{{ ... }}` (Etherscan wraps multi-file Hardhat/Foundry projects in double braces). Strip the outer braces before `jq` parsing.
- If the contract is unverified: `cast code 0xAbc` → disassemble with `cast disassemble` or save as `.bin` and pass to `heimdall decompile` if present.
- For unverified proxies: still run `impl_addr` and try `getsourcecode` on the implementation — the impl is what's usually verified.
- Etherscan V2 has per-key rate limits (5 req/s free tier). Cache each response to `challenges/<ch>/recon/cache/<addr>.<action>.json` and reuse.

---

## 4. Finding the right fork block

The fork block determines the on-chain state your PoC sees. Wrong block = wrong liquidity, wrong storage, wrong balances. For the isolated challenge RPCs the block is already baked in — `./tools/recon.sh chain_info ch<N>` returns `block_number` which is the current tip of the fork.

When reproducing historical attacks (not the case for the five challenges, but you may reference them in analysis), the mentor's reliable trick is:

1. Find the attack transaction hash (from rekt.news, Certik post-mortem, or Etherscan "Exploits" tag).
2. On Etherscan, open the attacker EOA's history; scroll to the earliest transaction.
3. That's almost always a Tornado Cash withdrawal that funded the attack. Take its block number minus one.
4. Fork at `block - 1` — the attacker EOA has zero balance, the protocol is pristine.

Equivalent via `cast`:

```bash
# 1. find funding tx from attacker
cast tx 0xFirstFundingTxHash --rpc-url "$RPC_ETH_ARCHIVE" | grep -E '^blockNumber'
# 2. fork block = above - 1
```

For the five assignment challenges, use the block the course staff baked into the fork. Do not override.

Archive node requirement: historical forks older than ~128 blocks need an archive node. The challenge RPCs are pre-configured archive forks. If you switch RPC you may lose archive capability.

---

## 5. Contract enumeration strategy

Start from known deployment addresses listed in `knowledge/case_<protocol>.md`. Each case file has the "contracts in scope" table — use those as seed addresses.

For each seed, walk outward by:

```bash
# all addresses this contract calls in the last N blocks
cast logs --from-block $((BLOCK-1000)) --to-block $BLOCK --address 0xSeed --rpc-url "$RPC" | grep -Eo '0x[a-fA-F0-9]{40}' | sort -u
```

Record every contract you touch as `{role: address}` in `challenges/<ch>/recon/contracts.json`:

```json
{
  "vault":        "0xa0246c9032bC3A600820415aE600c6388619A14D",
  "strategy":     "0x...",
  "underlying":   "0x...",
  "curve_pool":   "0x...",
  "flashlender":  "0x...",
  "attacker_eoa": "0xc943edb4bb4439d65b81f2f60bc698411e910b14"
}
```

The brain reads this file to name contracts in analysis.md. Keep role names short and stable.

---

## 6. Victim enumeration (Superfluid-specific, ch4/ch5)

For ctx-forgery exploits the profit is bounded by the balance of the account whose ctx you forge. You want the top holders of the SuperToken in scope.

Strategy:

```bash
# 1. find the SuperToken address from contracts.json (e.g., MATICx on Polygon)
SUPER_TOKEN=0x3aD736904E9e65189c3000c7DD2c8AC8bB7cD4e3

# 2. scan Transfer events over a broad range (fork block back ~500k blocks).
#    Transfer topic = 0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef
cast logs \
  --from-block $((BLOCK-500000)) \
  --to-block   $BLOCK \
  --address    $SUPER_TOKEN \
  0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef \
  --rpc-url    "$RPC_CH4_SUPERFLUID" \
  > /tmp/transfers.log

# 3. extract unique `to` addresses (topic[2])
grep -Eo '"topics":\[[^]]+\]' /tmp/transfers.log | python3 -c '
import sys, re, json
addrs=set()
for line in sys.stdin:
    t=re.findall(r"0x[a-fA-F0-9]{64}", line)
    if len(t)>=3: addrs.add("0x"+t[2][-40:])
print("\n".join(addrs))' | sort -u > /tmp/holders.txt

# 4. batch balanceOf
while read addr; do
  bal=$(cast call $SUPER_TOKEN "balanceOf(address)(uint256)" $addr --rpc-url "$RPC_CH4_SUPERFLUID")
  echo "$bal $addr"
done < /tmp/holders.txt | sort -rn | head -50 > challenges/ch4_superfluid/recon/victims.json.raw
```

Then convert `victims.json.raw` to real JSON (address + balance, top 50 sorted desc). AGENTS.md §3.6 requires `{address, balance_wei, balance_formatted}`.

If the range is too wide and RPC refuses, chunk it: 100k blocks at a time, dedupe the union. For low-activity SuperTokens, go back to token deployment block — the `GenesisAccount`-style large holders rarely move, so they may appear only once near the start.

---

## 7. Decoding calldata / selectors when source isn't verified

```bash
# 1. selector -> function signature (local DB + 4byte.directory)
cast 4byte 0x70a08231   # -> "balanceOf(address)"
# or multiple signatures:
cast 4byte 0xa9059cbb   # may return several; pick by context

# 2. decode calldata against a guessed signature
cast 4byte-decode 0xa9059cbb0000...

# 3. trace an existing tx to discover the call tree without source
cast run 0xTxHash --rpc-url "$RPC" --quick
cast run 0xTxHash --rpc-url "$RPC" --debug   # step-by-step
```

If `cast 4byte` misses: fall back to `curl https://www.4byte.directory/api/v1/signatures/?hex_signature=0x70a08231`, which is what `cast` queries.

---

## 8. Output files Codex must produce per recon task

| File | Content |
|---|---|
| `challenges/<ch>/recon/chain_info.json` | chain_id, block, gas_limit |
| `challenges/<ch>/recon/contracts.json` | `{role: address}` map, at least 3 roles |
| `challenges/<ch>/recon/abis/<addr>.json` | ABI for each role (if verified) |
| `challenges/<ch>/recon/src/<addr>.sol` | source for each role (if verified) |
| `challenges/<ch>/recon/victims.json` | only for ch4/ch5, top 50 SuperToken holders |
| `challenges/<ch>/status.json` | `state: "recon_done"` after completion |

Sample `contracts.json` for ch1_uranium (Uranium Finance):

```json
{
  "factory":        "0xA943eA143cd7E79806d670f4a7cf08F8922a454F",
  "router":         "0x80C8DD39Fe0a93d2290dA3a18d5226F04FC0B60D",
  "pair_WBNB_USDT": "0x...",
  "pair_WBNB_BUSD": "0x...",
  "attacker_eoa":   "0xc943edb4bb4439d65b81f2f60bc698411e910b14"
}
```

Always end with the 3-line status protocol:

```
STATUS: recon_done
DELTA: N/A
NEXT: brain should review contracts.json and confirm hypothesis in analysis.md
```
