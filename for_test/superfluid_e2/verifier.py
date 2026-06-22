#!/usr/bin/env python3
from web3 import Web3
import os

ABI = [
    {
        "type": "function",
        "name": "isSolved",
        "inputs": [],
        "outputs": [{"name": "", "type": "bool"}],
        "stateMutability": "view",
    },
    {
        "type": "function",
        "name": "deployBlock",
        "inputs": [],
        "outputs": [{"name": "", "type": "uint256"}],
        "stateMutability": "view",
    },
]

rpc_url = os.environ["RPC_URL"]
contract_address = os.environ["SETUP_CONTRACT_ADDRESS"]

MAX_ATTACKER_TX = 2


def verify():
    w3 = Web3(Web3.HTTPProvider(rpc_url))
    assert w3.is_connected(), "RPC server must be connectable"

    contract = w3.eth.contract(address=contract_address, abi=ABI)

    deploy_block = contract.functions.deployBlock().call()
    latest = w3.eth.block_number

    attacker_tx_count = 0
    for b in range(deploy_block + 1, latest + 1):
        attacker_tx_count += w3.eth.get_block_transaction_count(b)

    if attacker_tx_count > MAX_ATTACKER_TX:
        print(f"Too many transactions: {attacker_tx_count} > {MAX_ATTACKER_TX}")
        return False

    return contract.functions.isSolved().call() == True


if __name__ == "__main__":
    if verify():
        exit(0)
    exit(1)
