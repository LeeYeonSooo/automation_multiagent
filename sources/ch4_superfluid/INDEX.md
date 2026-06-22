# ch4_superfluid Source Archive

This tree contains explorer-sourced Solidity and ABI material for the Polygon contracts named in the task prompt.

Important note: the proxy `Implementation` pointers fetched from the explorer currently resolve to newer implementation bundles than the exact historical fork discussed in [knowledge/case_superfluid_v1.md](/Users/dldustn/Desktop/AssignmentC/knowledge/case_superfluid_v1.md:1) and [analysis.md](/Users/dldustn/Desktop/AssignmentC/challenges/ch4_superfluid/analysis.md:1). Use this archive for source navigation and ABI recovery, but use the challenge analysis for the pre-patch v1 vulnerability semantics at fork block `24,684,668`.

## Extracted Contracts

| Label | Address | Contract name | Proxy | Implementation | Folder |
|---|---|---|---|---|---|
| `superfluid_host_proxy` | `0x3E14dC1b13c488a8d5D310918780c983bD5982E7` | `UUPSProxy` | yes | `0x372b31667c9ae399ff4e57c5ee0c500386681a93` | `0x3e14dc1b13c488a8d5d310918780c983bd5982e7_superfluid_host_proxy/` |
| `superfluid_host_proxy_implementation` | `0x372b31667c9ae399ff4e57c5ee0c500386681a93` | `Superfluid` | no | | `0x372b31667c9ae399ff4e57c5ee0c500386681a93_superfluid_host_proxy_implementation/` |
| `ida` | `0xB0aABBA4B2783A72C52956CDEF62d438ecA2d7a1` | `UUPSProxy` | yes | `0x86e8ac788e9997b4e0e43a4c8fb12f69ad4bacbf` | `0xb0aabba4b2783a72c52956cdef62d438eca2d7a1_ida/` |
| `ida_implementation` | `0x86e8ac788e9997b4e0e43a4c8fb12f69ad4bacbf` | `InstantDistributionAgreementV1` | no | | `0x86e8ac788e9997b4e0e43a4c8fb12f69ad4bacbf_ida_implementation/` |
| `usdcx` | `0xCAa7349CEA390F89641fe306D93591f87595dc1F` | `UUPSProxy` | yes | `0xfd83982ee75892781242141ee19e1b42428b8220` | `0xcaa7349cea390f89641fe306d93591f87595dc1f_usdcx/` |
| `maticx` | `0x3aD736904E9e65189c3000c7DD2c8AC8bB7cD4e3` | `SETHProxy` | yes | `0xfd83982ee75892781242141ee19e1b42428b8220` | `0x3ad736904e9e65189c3000c7dd2c8ac8bb7cd4e3_maticx/` |
| `daix` | `0x1305F6B6Df9Dc47159D12Eb7aC2804d4A33173c2` | `UUPSProxy` | yes | `0xfd83982ee75892781242141ee19e1b42428b8220` | `0x1305f6b6df9dc47159d12eb7ac2804d4a33173c2_daix/` |
| `ethx` | `0x27e1e4E6BC79D93032abef01025811B7E4727e85` | `UUPSProxy` | yes | `0xfd83982ee75892781242141ee19e1b42428b8220` | `0x27e1e4e6bc79d93032abef01025811b7e4727e85_ethx/` |
| `wbtcx` | `0x4086eBf75233e8492F1BCDa41C7f2A8288c2fb92` | `UUPSProxy` | yes | `0xfd83982ee75892781242141ee19e1b42428b8220` | `0x4086ebf75233e8492f1bcda41c7f2a8288c2fb92_wbtcx/` |
| `usdc_polygon` | `0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174` | `UChildERC20Proxy` | yes | `0xdd9185db084f5c4fff3b4f70e7ba62123b812226` | `0x2791bca1f2de4661ed88a30c99a7a9449aa84174_usdc_polygon/` |
| `wmatic` | `0x0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270` | `WMATIC` | no | | `0x0d500b1d8e8ef31e21c99d1db9a6444d3adf1270_wmatic/` |
| `quickswap_v2_router` | `0xa5E0829CaCEd8fFDD4De3c43696c57F7D7A678ff` | `UniswapV2Router02` | no | | `0xa5e0829caced8ffdd4de3c43696c57f7d7a678ff_quickswap_v2_router/` |

## v1 Vulnerability Entry Points

### 1. Host `_callExternalWithReplacedCtx`

- File: [Superfluid.sol](/Users/dldustn/Desktop/AssignmentC/sources/ch4_superfluid/0x372b31667c9ae399ff4e57c5ee0c500386681a93_superfluid_host_proxy_implementation/src/contracts/superfluid/Superfluid.sol:1069)
- Why it matters: this is the host-side helper that rewrites the placeholder `ctx` bytes before forwarding the agreement call. The v1 challenge analysis centers on this replacement step plus ABI trailing-bytes behavior.
- Historical note: the extracted explorer-linked implementation already contains `_isCtxValid`, so treat this file as the structural location of the bug rather than proof of the exact 2022 vulnerable body.

### 2. `AgreementLibrary.authorizeTokenAccess`

- File: [AgreementLibrary.sol](/Users/dldustn/Desktop/AssignmentC/sources/ch4_superfluid/0x86e8ac788e9997b4e0e43a4c8fb12f69ad4bacbf_ida_implementation/src/contracts/agreements/AgreementLibrary.sol:36)
- Also present in the Host implementation bundle: [AgreementLibrary.sol](/Users/dldustn/Desktop/AssignmentC/sources/ch4_superfluid/0x372b31667c9ae399ff4e57c5ee0c500386681a93_superfluid_host_proxy_implementation/src/contracts/agreements/AgreementLibrary.sol:36)
- Why it matters: `IDA.createIndex` and the related agreement entrypoints depend on this helper before trusting `context.msgSender`.
- Historical note: the current explorer-linked source includes `require(ISuperfluid(msg.sender).isCtxValid(ctx), "invalid ctx")`; the v1 bug described in the case file is that this validation was missing on the vulnerable historical path.

### 3. IDA `createIndex`

- Interface declaration: [IInstantDistributionAgreementV1.sol](/Users/dldustn/Desktop/AssignmentC/sources/ch4_superfluid/0x86e8ac788e9997b4e0e43a4c8fb12f69ad4bacbf_ida_implementation/src/contracts/interfaces/agreements/IInstantDistributionAgreementV1.sol:69)
- Implementation: [InstantDistributionAgreementV1.sol](/Users/dldustn/Desktop/AssignmentC/sources/ch4_superfluid/0x86e8ac788e9997b4e0e43a4c8fb12f69ad4bacbf_ida_implementation/src/contracts/agreements/InstantDistributionAgreementV1.sol:164)
- Why it matters: this is the agreement entrypoint used in the classic forged-context flow. It obtains `context = AgreementLibrary.authorizeTokenAccess(token, ctx)` and then derives `publisher = context.msgSender`.

## Notes

- `usdcx`, `maticx`, `daix`, `ethx`, and `wbtcx` all point at the same SuperToken implementation address `0xfd83982ee75892781242141ee19e1b42428b8220`, but only Host and IDA implementations were recursively materialized because that was the explicit task requirement.
- Each extracted contract folder contains:
  - `metadata.json`: normalized explorer metadata
  - `abi.json`: ABI from `./tools/recon.sh fetch_abi polygon <addr>`
  - `src/`: reconstructed source tree from the explorer `SourceCode` payload
- `summary.json` provides a machine-readable index of the archive contents.
