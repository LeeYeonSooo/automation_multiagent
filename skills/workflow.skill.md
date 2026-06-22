# Workflow Skill — 전체 파이프라인

> 이전의 recon + foundry_fork + native_conversion + score_check + reset_rpc 통합

## 1. Recon

### Chain 정보 수집
```bash
cast chain-id --rpc-url $RPC
cast block-number --rpc-url $RPC
cast block latest --rpc-url $RPC  # timestamp, gasLimit
```

### Proxy 탐지
```bash
# EIP-1967 implementation slot
cast storage <proxy> 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc --rpc-url $RPC
```

### Contract enumeration
- knowledge/case_<protocol>.md에서 주소 목록 가져오기
- 각 주소: `cast code` → bytecode 확인
- Verified source 있으면 sources/ 에서 읽기

### Victim enumeration (Superfluid)
```bash
# Transfer event scan
cast logs --from-block 0 --to-block latest \
  --address <supertoken> \
  "Transfer(address,address,uint256)" \
  --rpc-url $RPC
```

## 2. Foundry 설정

### Fork test 실행
```bash
forge test --match-path challenges/<ch>/poc/AttemptN.t.sol \
  --fork-url $RPC -vvv 2>&1 | tee challenges/<ch>/runs/attemptN.log
```

### Script broadcast
```bash
# Dry-run
forge script challenges/<ch>/exploit/Run.s.sol \
  --rpc-url $RPC --private-key $PRIVATE_KEY -vvvv

# Broadcast
forge script challenges/<ch>/exploit/Run.s.sol \
  --rpc-url $RPC --private-key $PRIVATE_KEY --broadcast -vvvv
```

### 일반 revert 원인

| Selector | 의미 |
|---|---|
| `0x08c379a0` | Error(string) |
| `0x4e487b71` | Panic(uint256) |
| `0x` (empty) | out of gas 또는 fallback |

## 3. Native 변환

### Per-chain recipes

**Ethereum (ch2, ch3)**:
```solidity
IWETH(WETH).withdraw(amount);  // WETH → ETH
IRouter(UNISWAP_V2).swapExactTokensForETH(amount, 0, path, to, deadline);
```

**Polygon (ch4, ch5)**:
```solidity
// MATICx → native MATIC
ISuperToken(MATICx).downgradeToETH(amount);  // Superfluid 전용
// WMATIC → MATIC
IWMATIC(WMATIC).withdraw(amount);
// ERC20 → MATIC via QuickSwap
IRouter(QUICKSWAP).swapExactTokensForETH(amount, 0, path, to, deadline);
```

**BSC (ch1)**:
```solidity
IWBNB(WBNB).withdraw(amount);  // WBNB → BNB
IPancakeRouter(ROUTER).swapExactTokensForETH(amount, 0, path, to, deadline);
```

### 변환 우선순위
1. wrapped native → unwrap (가스 최소)
2. major stable → direct swap to native
3. exotic token → stable 거쳐서 native (2-hop)

## 4. 점수 확인

```bash
./tools/score.sh                    # 전체 표
cat actual_scores.json | jq '.'     # raw JSON
```

공식: `minmax_scale(log1p(raw), 0.01, 1) × max_pts`
- 상대 평가 (다른 팀 raw 영향)
- **유일한 전략 = vault 전체 drain**

## 5. Reset

```bash
./tools/reset.sh <ch>  # GET on reset endpoint
```

- **무료** — 점수 = historical max balance (reset으로 안 줄어듦)
- RPC 불안정, 상태 꼬임, 실수 시 자유롭게 사용
- exploit 실패 후 reset → 재시도 가능
- 반복 drain 가능한 챌린지 (ch2): reset → exploit → reset → exploit
