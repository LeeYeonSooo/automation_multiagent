# ch5_superfluid_v2 Patch History

This file records the implementation history for the Superfluid Host and IDA proxies in scope.

Evidence sources:

- Etherscan `getcontractcreation` for deployment block, timestamp, and creation tx
- PolygonScan proxy banners for current implementation and the single "previously recorded" implementation
- `challenges/ch5_superfluid_v2/analysis.md` for the fork-pinned implementation addresses used by the assignment harness

Important limitation:

- PolygonScan's `Historical Proxy` tab is empty for both proxies even though the proxy banner exposes a current implementation and one previous recorded implementation.
- Because of that, the dates below are deployment dates for the implementation contracts, not authoritative proxy-upgrade timestamps, unless explicitly marked otherwise.

## Host Timeline

| Date (UTC) | Address | Evidence | Interpretation |
| --- | --- | --- | --- |
| `2021-03-05 21:02:45 UTC` | `0x3E14dC1b13c488a8d5D310918780c983bD5982E7` | Proxy deployment tx `0xa9868d7788a36e1968326ef51fef7d18ed93fba212803b7a365ccbc588abb659` | Host proxy deployment |
| `2022-03-15 17:49:15 UTC` | `0x513b7C5c6B7d8b21A14d6D5536878fB0a803BeF4` | Implementation deployment tx `0x57de623bd504147bc1b3096737ab220c8c5c9fc02ad31712f524efa6e9184f4f` | Fork-era Host implementation used by the ch5 analysis; Patch-1-style `isCtxValid` is visible in source |
| `2025-09-03 10:25:30 UTC` | `0xa99a1942d71f2457a1d2dd1edcf5d9d3104f5de2` | Implementation deployment tx `0xab5f23e6a5f62f32277a09824bc927891e6bed7cfd807bf62befea753888066b`; proxy page says "Previously recorded to be on `0xa99a...`" | Public verified Host snapshot previously pointed to by the proxy |
| `2025-11-25 18:43:57 UTC` | `0x372b31667c9ae399ff4e57c5ee0c500386681a93` | Implementation deployment tx `0x8299a91386451fae42f9846b871256fcd90a1a9cfcf1c4a51801cf2c4a621b7e`; proxy metadata currently points here | Current public verified Host snapshot |

Host-side validation references:

- Fork-era Host `isCtxValid`: [Superfluid.sol](/Users/dldustn/Desktop/AssignmentC/sources/ch5_superfluid_v2/0x513b7c5c6b7d8b21a14d6d5536878fb0a803bef4_superfluid_host_impl_fork_patch1/src/contracts/superfluid/Superfluid.sol:748)
- Fork-era Host `_isCtxValid`: [Superfluid.sol](/Users/dldustn/Desktop/AssignmentC/sources/ch5_superfluid_v2/0x513b7c5c6b7d8b21a14d6d5536878fb0a803bef4_superfluid_host_impl_fork_patch1/src/contracts/superfluid/Superfluid.sol:925)
- Public Host `authorizeTokenAccess`: [AgreementLibrary.sol](/Users/dldustn/Desktop/AssignmentC/sources/ch5_superfluid_v2/0xa99a1942d71f2457a1d2dd1edcf5d9d3104f5de2_superfluid_host_impl_public_previous/src/packages/ethereum-contracts/contracts/agreements/AgreementLibrary.sol:36) and [AgreementLibrary.sol](/Users/dldustn/Desktop/AssignmentC/sources/ch5_superfluid_v2/0x372b31667c9ae399ff4e57c5ee0c500386681a93_superfluid_host_impl_public_current/src/contracts/agreements/AgreementLibrary.sol:36)

## IDA Timeline

| Date (UTC) | Address | Evidence | Interpretation |
| --- | --- | --- | --- |
| `2021-03-05 21:03:49 UTC` | `0xB0aABBA4B2783A72C52956CDEF62d438ecA2d7a1` | Proxy deployment tx `0xdc78cd3ba60c8a0e6366d0684d63bcce61fb5e4b01525c283a0715fd78ad8f6d` | IDA proxy deployment |
| `2022-03-15 17:49:37 UTC` | `0x848497975f5757Aa1a48e13bbF46D330E62b19A7` | Implementation deployment tx `0xaf1ecedfe0184c69eab6cf4f1c067573ff8ba5919a3ac1c9d42eead2583b77dc`; challenge analysis identifies this as the fork delegate target | Fork-era unverified IDA build; the only implementation in this archive that can still match the case file's missing-`authorizeTokenAccess` `claim()` path |
| `2025-07-03 08:27:31 UTC` | `0x85eb36dcb5c039edd37f8859dc09756ac3a06def` | Implementation deployment tx `0x97ac76352d0298ffbff2a01d8991c4b0a804713e372c8722368f2d3f07405766`; proxy page says "Previously recorded to be on `0x85eb...`" | Public verified IDA snapshot previously pointed to by the proxy |
| `2025-11-25 18:44:47 UTC` | `0x86e8ac788e9997b4e0e43a4c8fb12f69ad4bacbf` | Implementation deployment tx `0x9c2c1b87bda4b84856e6553b4c768f4beecec71f82579598e4b10c3ddd77facb`; proxy metadata currently points here | Current public verified IDA snapshot |

IDA-side `claim()` references:

- Public previous verified `claim()`: [InstantDistributionAgreementV1.sol](/Users/dldustn/Desktop/AssignmentC/sources/ch5_superfluid_v2/0x85eb36dcb5c039edd37f8859dc09756ac3a06def_ida_impl_public_previous/src/contracts/agreements/InstantDistributionAgreementV1.sol:813)
- Public current verified `claim()`: [InstantDistributionAgreementV1.sol](/Users/dldustn/Desktop/AssignmentC/sources/ch5_superfluid_v2/0x86e8ac788e9997b4e0e43a4c8fb12f69ad4bacbf_ida_impl_public_current/src/contracts/agreements/InstantDistributionAgreementV1.sol:813)
- In both verified public bundles, `claim()` calls `AgreementLibrary.authorizeTokenAccess(token, ctx)` at line `823`.
- No equivalent source line exists for the fork-era `0x8484...` build because the contract is unverified on PolygonScan.

## Token Proxy Notes

| Date (UTC) | Address | Evidence | Interpretation |
| --- | --- | --- | --- |
| `2021-03-17 10:29:04 UTC` | `0xCAa7349CEA390F89641fe306D93591f87595dc1F` | Proxy deployment tx `0xfdaac2ee85385a9d289c0e5dda91348006448e40f5713dff68e83d6e54fb39a5` | USDCx proxy deployment |
| `2021-03-05 21:47:29 UTC` | `0x3aD736904E9e65189c3000c7DD2c8AC8bB7cD4e3` | Proxy deployment tx `0x9958dcc6aaa0b3e477a305b7608b4885c48ac5164c4a8b7c087bd3cfac49c87c` | MATICx proxy deployment |
| `2024-08-05 21:02:20 UTC` | `0xfd83982ee75892781242141ee19e1b42428b8220` | Implementation deployment tx `0x4c33ebc184b41379185879693533aeae77ff6658d6260298637640f5af218349` | Shared SuperToken implementation currently pointed to by both token proxies |

## Bottom Line

- The Host-side Patch-1 validation is present in the fork-era Host source and in all public verified Host bundles archived here.
- The public verified IDA bundles `0x85eb...` and `0x86e8...` both already call `authorizeTokenAccess(...)` inside `claim()`.
- The exploit-relevant gap for ch5 therefore lives in the older unverified IDA build `0x8484...`, which the challenge harness pins at the fork block but PolygonScan no longer exposes as verified source.

