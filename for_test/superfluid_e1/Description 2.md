## Description

MATICx SuperToken이 보유하고 있는 MATIC 잔고를 0으로 만드세요!

```solidity
// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

contract Setup {
    address constant MATICx = 0x3aD736904E9e65189c3000c7DD2c8AC8bB7cD4e3;

    function isSolved() public view returns (bool) {
        require(MATICx.balance == 0, "MATICx has not been fully drained");
        return true;
    }
}
```

```python
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
    }
]

rpc_url = os.environ["RPC_URL"]
contract_address = os.environ["SETUP_CONTRACT_ADDRESS"]


def verify():
    w3 = Web3(Web3.HTTPProvider(rpc_url))
    assert w3.is_connected(), "RPC server must be connectable"

    contract = w3.eth.contract(address=contract_address, abi=ABI)
    return contract.functions.isSolved().call() == True


if __name__ == "__main__":
    if verify():
        exit(0)
    exit(1)
```



Superfluid E1 (Full Drain MATICx)
RPC: https://REDACTED.example.invalid/9211c782-ae68-44dd-96a4-6a307c4e3091/rpc/4gi_akali:575d580ce56856c4751f2afb8daf13cc21c4eefd48958f1734e36a44d5f23734
Reset: https://REDACTED.example.invalid/9211c782-ae68-44dd-96a4-6a307c4e3091/rpc/4gi_akali:575d580ce56856c4751f2afb8daf13cc21c4eefd48958f1734e36a44d5f23734
Contract Address: https://REDACTED.example.invalid/9211c782-ae68-44dd-96a4-6a307c4e3091/contract_address/4gi_akali:575d580ce56856c4751f2afb8daf13cc21c4eefd48958f1734e36a44d5f23734
Flag: https://REDACTED.example.invalid/9211c782-ae68-44dd-96a4-6a307c4e3091/flag/4gi_akali:575d580ce56856c4751f2afb8daf13cc21c4eefd48958f1734e36a44d5f23734
