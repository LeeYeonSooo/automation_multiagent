# ch5_superfluid_v2 Source Archive

This archive was built from PolygonScan/Etherscan explorer data only:

- `./tools/recon.sh src polygon <addr>`
- `./tools/recon.sh fetch_abi polygon <addr>`
- Etherscan `getcontractcreation`

Per the task's archive-only constraint, this tree was written under `sources/ch5_superfluid_v2/` only. No challenge RPC was touched, and no files under `challenges/ch5_superfluid_v2/` were modified.

## Contract Inventory

| Label | Address | Contract | Notes | Folder |
| --- | --- | --- | --- | --- |
| `superfluid_host_proxy` | `0x3E14dC1b13c488a8d5D310918780c983bD5982E7` | `UUPSProxy` | Current proxy pointer is `0x372b...`; PolygonScan says it was previously recorded on `0xa99a...` | `0x3e14dc1b13c488a8d5d310918780c983bd5982e7_superfluid_host_proxy/` |
| `superfluid_host_impl_fork_patch1` | `0x513b7C5c6B7d8b21A14d6D5536878fB0a803BeF4` | `Superfluid` | Fork-era Host implementation used by the ch5 analysis | `0x513b7c5c6b7d8b21a14d6d5536878fb0a803bef4_superfluid_host_impl_fork_patch1/` |
| `superfluid_host_impl_public_previous` | `0xa99a1942d71f2457a1d2dd1edcf5d9d3104f5de2` | `Superfluid` | Public verified Host snapshot previously recorded on the proxy page | `0xa99a1942d71f2457a1d2dd1edcf5d9d3104f5de2_superfluid_host_impl_public_previous/` |
| `superfluid_host_impl_public_current` | `0x372b31667c9ae399ff4e57c5ee0c500386681a93` | `Superfluid` | Current public verified Host snapshot | `0x372b31667c9ae399ff4e57c5ee0c500386681a93_superfluid_host_impl_public_current/` |
| `ida_proxy` | `0xB0aABBA4B2783A72C52956CDEF62d438ecA2d7a1` | `UUPSProxy` | Current proxy pointer is `0x86e8...`; PolygonScan says it was previously recorded on `0x85eb...` | `0xb0aabba4b2783a72c52956cdef62d438eca2d7a1_ida_proxy/` |
| `ida_impl_fork_patch1_unverified` | `0x848497975f5757Aa1a48e13bbF46D330E62b19A7` | unverified | Fork-era IDA implementation used by the ch5 analysis; no verified source available | `0x848497975f5757aa1a48e13bbf46d330e62b19a7_ida_impl_fork_patch1_unverified/` |
| `ida_impl_public_previous` | `0x85eb36dcb5c039edd37f8859dc09756ac3a06def` | `InstantDistributionAgreementV1` | Public verified IDA snapshot previously recorded on the proxy page | `0x85eb36dcb5c039edd37f8859dc09756ac3a06def_ida_impl_public_previous/` |
| `ida_impl_public_current` | `0x86e8ac788e9997b4e0e43a4c8fb12f69ad4bacbf` | `InstantDistributionAgreementV1` | Current public verified IDA snapshot | `0x86e8ac788e9997b4e0e43a4c8fb12f69ad4bacbf_ida_impl_public_current/` |
| `usdcx_proxy` | `0xCAa7349CEA390F89641fe306D93591f87595dc1F` | `UUPSProxy` | Currently points to shared SuperToken implementation `0xfd83...` | `0xcaa7349cea390f89641fe306d93591f87595dc1f_usdcx_proxy/` |
| `maticx_proxy` | `0x3aD736904E9e65189c3000c7DD2c8AC8bB7cD4e3` | `SETHProxy` | Currently points to shared SuperToken implementation `0xfd83...` | `0x3ad736904e9e65189c3000c7dd2c8ac8bb7cd4e3_maticx_proxy/` |
| `supertoken_impl_shared` | `0xfd83982ee75892781242141ee19e1b42428b8220` | `SuperToken` | Shared implementation behind both token proxies | `0xfd83982ee75892781242141ee19e1b42428b8220_supertoken_impl_shared/` |

## v2 Attack Surface

### 1. Host-side Patch-1 context validation is present

- Fork-era Host `0x513b...` exposes `isCtxValid(bytes)` at [Superfluid.sol](/Users/dldustn/Desktop/AssignmentC/sources/ch5_superfluid_v2/0x513b7c5c6b7d8b21a14d6d5536878fb0a803bef4_superfluid_host_impl_fork_patch1/src/contracts/superfluid/Superfluid.sol:748) and implements `_isCtxValid` at [Superfluid.sol](/Users/dldustn/Desktop/AssignmentC/sources/ch5_superfluid_v2/0x513b7c5c6b7d8b21a14d6d5536878fb0a803bef4_superfluid_host_impl_fork_patch1/src/contracts/superfluid/Superfluid.sol:925).
- Public verified Host bundles `0xa99a...` and `0x372b...` both keep the same guard inside `AgreementLibrary.authorizeTokenAccess(...)`, with the `isCtxValid(ctx)` requirement at [AgreementLibrary.sol](/Users/dldustn/Desktop/AssignmentC/sources/ch5_superfluid_v2/0xa99a1942d71f2457a1d2dd1edcf5d9d3104f5de2_superfluid_host_impl_public_previous/src/packages/ethereum-contracts/contracts/agreements/AgreementLibrary.sol:41) and [AgreementLibrary.sol](/Users/dldustn/Desktop/AssignmentC/sources/ch5_superfluid_v2/0x372b31667c9ae399ff4e57c5ee0c500386681a93_superfluid_host_impl_public_current/src/contracts/agreements/AgreementLibrary.sol:41).

Interpretation: Patch 1 is visible on the Host side. The ch5 surface is therefore not "host still accepts arbitrary ctx"; it is "IDA claim path on the fork-era IDA build still matters even after the Host-side validation exists."

### 2. Public verified IDA builds already guard `claim()`

- Public previous verified IDA `0x85eb...` calls `AgreementLibrary.authorizeTokenAccess(token, ctx)` inside `claim()` at [InstantDistributionAgreementV1.sol](/Users/dldustn/Desktop/AssignmentC/sources/ch5_superfluid_v2/0x85eb36dcb5c039edd37f8859dc09756ac3a06def_ida_impl_public_previous/src/contracts/agreements/InstantDistributionAgreementV1.sol:823).
- Current public verified IDA `0x86e8...` does the same at [InstantDistributionAgreementV1.sol](/Users/dldustn/Desktop/AssignmentC/sources/ch5_superfluid_v2/0x86e8ac788e9997b4e0e43a4c8fb12f69ad4bacbf_ida_impl_public_current/src/contracts/agreements/InstantDistributionAgreementV1.sol:823).
- Both verified IDA bundles use the same `AgreementLibrary.authorizeTokenAccess(...)` helper with the `isCtxValid(ctx)` check at [AgreementLibrary.sol](/Users/dldustn/Desktop/AssignmentC/sources/ch5_superfluid_v2/0x85eb36dcb5c039edd37f8859dc09756ac3a06def_ida_impl_public_previous/src/contracts/agreements/AgreementLibrary.sol:41) and [AgreementLibrary.sol](/Users/dldustn/Desktop/AssignmentC/sources/ch5_superfluid_v2/0x86e8ac788e9997b4e0e43a4c8fb12f69ad4bacbf_ida_impl_public_current/src/contracts/agreements/AgreementLibrary.sol:41).

Important: the two public verified IDA snapshots in this archive do not expose the vulnerable `claim()` behavior described in the case file. They are useful for ABI and structure recovery, but they are not source-identical to the ch5 fork's live IDA implementation.

### 3. The unresolved fork-only surface is the unverified IDA build `0x8484...`

- The ch5 analysis identifies the live fork delegate target as `0x848497975f5757Aa1a48e13bbF46D330E62b19A7`.
- Explorer metadata for that address is unverified: [metadata.json](/Users/dldustn/Desktop/AssignmentC/sources/ch5_superfluid_v2/0x848497975f5757aa1a48e13bbf46d330e62b19a7_ida_impl_fork_patch1_unverified/metadata.json:1).
- The archive note for that address is here: [UNVERIFIED.md](/Users/dldustn/Desktop/AssignmentC/sources/ch5_superfluid_v2/0x848497975f5757aa1a48e13bbf46d330e62b19a7_ida_impl_fork_patch1_unverified/src/UNVERIFIED.md:1).

Interpretation: because both public verified IDA builds already guard `claim()`, the only implementation in scope that can still match the case file's "claim() did not invoke authorizeTokenAccess" description is the older unverified fork-era build `0x8484...`.

## Read Order

1. [PATCH_HISTORY.md](/Users/dldustn/Desktop/AssignmentC/sources/ch5_superfluid_v2/PATCH_HISTORY.md:1)
2. [UNVERIFIED.md](/Users/dldustn/Desktop/AssignmentC/sources/ch5_superfluid_v2/0x848497975f5757aa1a48e13bbf46d330e62b19a7_ida_impl_fork_patch1_unverified/src/UNVERIFIED.md:1)
3. Fork Host ctx validation in [Superfluid.sol](/Users/dldustn/Desktop/AssignmentC/sources/ch5_superfluid_v2/0x513b7c5c6b7d8b21a14d6d5536878fb0a803bef4_superfluid_host_impl_fork_patch1/src/contracts/superfluid/Superfluid.sol:748)
4. Public IDA `claim()` guard in [InstantDistributionAgreementV1.sol](/Users/dldustn/Desktop/AssignmentC/sources/ch5_superfluid_v2/0x86e8ac788e9997b4e0e43a4c8fb12f69ad4bacbf_ida_impl_public_current/src/contracts/agreements/InstantDistributionAgreementV1.sol:813)

