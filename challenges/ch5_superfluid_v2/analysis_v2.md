# ch5 Analysis v2 — Brain Direct Code Analysis

## Fork State (verified 2026-04-18)
- Host proxy: 0x3E14dC1b → impl 0x513b7C5c (Patch-1, verified source)
- IDA proxy: 0xB0aABBA4 → impl 0x848497975f (Patch-1, UNVERIFIED bytecode)
- MATICx: 0x3aD736904E (totalSupply: 210,075 MATIC)
- APP_WHITE_LISTING_ENABLED = true (can't register new SuperApp)
- anvil_setCode = blocked (PermissionError)
- Our balance: 10 MATIC (baseline)
- Leader score: 10,089.7/25,000 (someone solved it!)

## Critical Code Path Analysis

### Host._callAgreement (Superfluid.sol:573-609)
```
1. Builds ctx with msgSender = caller, sets _ctxStamp
2. Calls _replacePlaceholderCtx → replaces LAST zero-length bytes with real ctx
3. Calls agreement via low-level .call()
```

### Host.callAgreementWithContext (Superfluid.sol:676-708)
```
Line 690: oldSender = context.msgSender  (saves forged victim)
Line 691: context.msgSender = msg.sender  (OVERWRITES to calling app!)
Line 694: _updateContext → valid ctx with msgSender = app
Line 697: calls agreement with msgSender = app (NOT victim)
Line 703: context.msgSender = oldSender   (restores victim for returned ctx)
```
→ Sub-operations in callbacks always use msg.sender, NOT forged msgSender

### Host.appCallbackPush (Superfluid.sol:500-524)
```
Line 511: decodes ctx → context.msgSender = forged victim (PRESERVED!)
Line 512-514: if msgSender is SuperApp → requires composite whitelist
              if msgSender is EOA → no check! ← KEY
Line 516-522: overwrites callType, appAllowance*, appAddress
Line 523: _updateContext → NEW VALID ctx with forged msgSender!
```
→ Forged msgSender IS laundered into valid Host-stamped ctx

## Hypothesis A: Full V1 Attack (createIndex also lacks authorizeTokenAccess)

### Logic
The case file says "claim() did not invoke authorizeTokenAccess." But what if
OTHER IDA functions (createIndex, updateSubscription, updateIndex) ALSO lack it
in the fork's unverified bytecode?

If createIndex also skips authorizeTokenAccess:
1. Trailing-bytes createIndex with forged ctx (msgSender=victim) → index under victim ✓
2. Trailing-bytes updateSubscription (msgSender=victim) → attacker as subscriber ✓
3. Trailing-bytes updateIndex (msgSender=victim) → inflate index ✓
4. Normal claim → attacker claims ✓

### Test Plan
Write a Foundry test that:
1. Constructs trailing-bytes calldata for createIndex with forged ctx
2. Calls host.callAgreement with this calldata
3. Checks if index exists under victim's address

### Expected Success: createIndex creates index under victim, not reverted
### Expected Failure: createIndex reverts with "invalid ctx" (authorizeTokenAccess blocks)

## Hypothesis B: Claim callback ctx laundering → nested IDA operations

### Logic
Even if only claim() lacks authorizeTokenAccess:
1. claim() passes forged ctx to callback (appCallbackPush)
2. appCallbackPush creates VALID ctx with forged msgSender
3. But callAgreementWithContext overwrites msgSender = msg.sender for sub-ops
4. The forged msgSender doesn't reach sub-operations

### HOWEVER
After callAgreementWithContext returns, msgSender is RESTORED to oldSender (line 703).
The returned ctx has forged victim as msgSender, and it's valid (Host-stamped).

Could this valid-ctx-with-forged-sender be used for further operations outside the callback?

### Problem: callAgreementWithContext can only be called within callback frame (requires valid ctx)

## Hypothesis C: Direct trailing-bytes on ALL IDA functions simultaneously

### Logic
What if we use batchCall to call multiple IDA operations in sequence,
each with trailing-bytes trick? If batchCall doesn't re-validate ctx between ops...

### Code Path
Host.batchCall calls _callAgreement for each op separately.
Each op gets fresh ctx from _callAgreement.
→ No ctx threading between batch ops.

## Existing Subscription Data (for claim testing)

Publisher: 0xcab28480ab5c1e133e9b7fc67e030b8dcc2a1d24 (REX Market, registered SuperApp)
- MATICx indexId=1: indexValue=1218232610071381, totalUnitsApproved=4539360, totalUnitsPending=92640
- DAIx indexId=0: indexValue=2287086053237048, totalUnitsApproved=544880, totalUnitsPending=11120

Subscriber: 0x9c6b5fdc145912dfe6ee13a667af3c5eb07cbb89 (unapproved)
- units=92640, pending=89179336596046560 (~0.089 MATICx)

Publisher MATICx balance: 98968000003403822 (~0.099 MATICx)
Publisher DAIx balance: 824496000000095927 (~0.824 DAIx)

## Key Addresses
```
HOST  = 0x3E14dC1b13c488a8d5D310918780c983bD5982E7
IDA   = 0xB0aABBA4B2783A72C52956CDEF62d438ecA2d7a1
MATICx = 0x3aD736904E9e65189c3000c7DD2c8AC8bB7cD4e3
USDCx  = 0xCAa7349CEA390F89641fe306D93591f87595dc1F
DAIx   = 0x1305F6B6Df9Dc47159D12Eb7aC2804d4A33173c2
```

## Priority
Test Hypothesis A first — if it succeeds, it's the simplest and most profitable attack (full v1 replay).
If A fails, test B/C variations.
