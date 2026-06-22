#!/usr/bin/env bash
# recon.sh - 컨트랙트 정보 수집 보조 (Codex가 호출)
#
# 사용:
#   ./tools/recon.sh chain_info ch1
#   ./tools/recon.sh fetch_abi <chain> <address>
#   ./tools/recon.sh impl_addr <rpc> <proxy_addr>

set -e

cd "$(dirname "$0")/.."
[ -f .env ] && { set -a; source .env; set +a; }

CMD="${1:-help}"

case "$CMD" in
    chain_info)
        CH="${2:-}"
        case "$CH" in
            ch1|ch1_uranium)        rpc="$RPC_CH1_URANIUM" ;;
            ch2|ch2_harvest)        rpc="$RPC_CH2_HARVEST" ;;
            ch3|ch3_feirari)        rpc="$RPC_CH3_FEIRARI" ;;
            ch4|ch4_superfluid)     rpc="$RPC_CH4_SUPERFLUID" ;;
            ch5|ch5_superfluid_v2)  rpc="$RPC_CH5_SUPERFLUID_V2" ;;
            *) echo "unknown challenge"; exit 1 ;;
        esac
        chain_id=$(cast chain-id --rpc-url "$rpc" 2>/dev/null)
        block=$(cast block-number --rpc-url "$rpc" 2>/dev/null)
        gas_lim=$(cast block latest gasLimit --rpc-url "$rpc" 2>/dev/null)
        cat <<EOF
{
  "challenge": "$CH",
  "chain_id": "$chain_id",
  "block_number": "$block",
  "gas_limit": "$gas_lim",
  "rpc_url_redacted": "$(echo "$rpc" | sed 's|:[a-f0-9]\{20,\}|:REDACTED|')"
}
EOF
        ;;
    
    fetch_abi)
        CHAIN="${2:-ethereum}"
        ADDR="${3:-}"
        if [ -z "$ADDR" ]; then echo "Usage: $0 fetch_abi <chain> <address>"; exit 1; fi
        
        case "$CHAIN" in
            ethereum|eth|mainnet)
                CHAIN_ID=1; KEY="$ETHERSCAN_API_KEY"
                URL="https://api.etherscan.io/v2/api?chainid=$CHAIN_ID&module=contract&action=getabi&address=$ADDR&apikey=$KEY"
                ;;
            polygon)
                CHAIN_ID=137; KEY="$ETHERSCAN_API_KEY"  # Etherscan v2 multi-chain key
                URL="https://api.etherscan.io/v2/api?chainid=$CHAIN_ID&module=contract&action=getabi&address=$ADDR&apikey=$KEY"
                ;;
            bsc)
                CHAIN_ID=56; KEY="$ETHERSCAN_API_KEY"
                URL="https://api.etherscan.io/v2/api?chainid=$CHAIN_ID&module=contract&action=getabi&address=$ADDR&apikey=$KEY"
                ;;
            *) echo "unknown chain: $CHAIN"; exit 1 ;;
        esac
        
        if [ -z "$KEY" ]; then
            echo "WARN: ETHERSCAN_API_KEY not set; rate-limited public access"
        fi
        
        curl -s "$URL" | jq -r '.result' 2>/dev/null
        ;;
    
    impl_addr)
        RPC="${2:-}"
        PROXY="${3:-}"
        if [ -z "$PROXY" ]; then echo "Usage: $0 impl_addr <rpc> <proxy_addr>"; exit 1; fi
        # EIP-1967 implementation slot
        SLOT="0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc"
        VAL=$(cast storage "$PROXY" "$SLOT" --rpc-url "$RPC" 2>/dev/null)
        # 마지막 40 hex char가 주소
        ADDR="0x${VAL:26}"
        echo "$ADDR"
        ;;
    
    src)
        CHAIN="${2:-ethereum}"
        ADDR="${3:-}"
        if [ -z "$ADDR" ]; then echo "Usage: $0 src <chain> <address>"; exit 1; fi
        case "$CHAIN" in
            ethereum) CHAIN_ID=1 ;;
            polygon)  CHAIN_ID=137 ;;
            bsc)      CHAIN_ID=56 ;;
        esac
        URL="https://api.etherscan.io/v2/api?chainid=$CHAIN_ID&module=contract&action=getsourcecode&address=$ADDR&apikey=$ETHERSCAN_API_KEY"
        curl -s "$URL" | jq -r '.result[0].SourceCode' 2>/dev/null
        ;;
    
    help|*)
        cat <<EOF
Usage: $0 <command> [args]

Commands:
  chain_info <ch>              chain_id, block_number, gas_limit
  fetch_abi <chain> <addr>     ABI from Etherscan (multi-chain v2 API)
  impl_addr <rpc> <proxy>      EIP-1967 implementation address
  src <chain> <addr>           source code

chains: ethereum polygon bsc
EOF
        ;;
esac
