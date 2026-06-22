# Unverified Fork-Era IDA Implementation

Address: `0x848497975f5757Aa1a48e13bbF46D330E62b19A7`

Why this file exists:

- Explorer source lookup returned no verified source for this address.
- The archive metadata therefore marks this contract as `verified: false` and `source_format: unverified`; see [metadata.json](/Users/dldustn/Desktop/AssignmentC/sources/ch5_superfluid_v2/0x848497975f5757aa1a48e13bbf46d330e62b19a7_ida_impl_fork_patch1_unverified/metadata.json:1).
- `challenges/ch5_superfluid_v2/analysis.md` identifies this address as the IDA implementation actually reached by the ch5 fork.

Explorer facts captured during recon:

- Creator: `0xd15d5d0f5b1b56a4daef75cfe108cb825e97d015` (`Superfluid Finance: Deployer`)
- Creation tx: `0xaf1ecedfe0184c69eab6cf4f1c067573ff8ba5919a3ac1c9d42eead2583b77dc`
- Creation block: `25976459`
- Creation time: `2022-03-15 17:49:37 UTC`
- PolygonScan page: `https://polygonscan.com/address/0x848497975f5757Aa1a48e13bbF46D330E62b19A7#code`
- Bytecode decompiler entrypoint: `https://polygonscan.com/bytecode-decompiler?a=0x848497975f5757Aa1a48e13bbF46D330E62b19A7`

Why it matters for ch5:

- The current public IDA proxy `0xB0aA...` now points to verified `0x86e8...`.
- PolygonScan also says the proxy was previously recorded on verified `0x85eb...`.
- Both of those verified public snapshots already call `AgreementLibrary.authorizeTokenAccess(token, ctx)` inside `claim()`.
- The challenge writeup for ch5 says the exploitable path is specifically that `claim()` did not invoke `authorizeTokenAccess`.

Practical conclusion:

- The public verified IDA source is structurally useful, but it is not source-identical to the ch5 fork's live IDA implementation.
- Treat `0x8484...` as the fork-only implementation gap that must be validated from fork traces and harness analysis rather than from PolygonScan source lines.

Bytecode note:

- PolygonScan does expose deployed runtime bytecode for this address on the unverified code page.
- The runtime bytecode begins with `0x608060405234801561001057600080fd5b50600436106101215760003560e01c80637730599e...`
- This archive does not attempt a decompilation because the task was source-archive focused and explorer-only.

