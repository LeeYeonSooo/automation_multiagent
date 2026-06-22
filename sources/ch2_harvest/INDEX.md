# ch2_harvest source archive

Generated: 2026-04-18T04:13:59.239312+00:00
Chain: ethereum (chain_id=1)
Fetch path: `tools/recon.sh src` + `tools/recon.sh fetch_abi` with Etherscan `getsourcecode` metadata.
Constraint: archive-only generation under `sources/`; no challenge RPC touched.

## Summary

- Requested contracts archived: 11
- Additional proxy implementations archived: 2
- Total archived directories: 13

## Contracts

| Label | Address | Contract | Requested | Proxy | Impl | Format | Files | Path |
| --- | --- | --- | --- | --- | --- | --- | ---: | --- |
| CurveStrategy | `0x1C47343eA7135c2bA3B2d24202AD960aDaFAa81c` | `CRVStrategyStableMainnet` | yes | no | `` | `flattened_markers` | 19 | `ch2_harvest/0x1c47343ea7135c2ba3b2d24202ad960adafaa81c_CurveStrategy` |
| HVault_fUSDT_impl | `0x9B3bE0cC5dD26Fd0254088D03d8206792715588b` | `Vault` | yes | no | `` | `flattened_markers` | 18 | `ch2_harvest/0x9b3be0cc5dd26fd0254088d03d8206792715588b_HVault_fUSDT_impl` |
| HVault_fUSDT_proxy | `0x053c80eA73Dc6941F518a68E2FC52Ac45BDE7c9C` | `VaultProxy` | yes | yes | `0x0de5f3a958f8e927c5b27d202d12b607e213d08c` | `flattened_markers` | 5 | `ch2_harvest/0x053c80ea73dc6941f518a68e2fc52ac45bde7c9c_HVault_fUSDT_proxy` |
| UniV2_Router | `0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D` | `UniswapV2Router02` | yes | no | `` | `single_file` | 1 | `ch2_harvest/0x7a250d5630b4cf539739df2c5dacb4c659f2488d_UniV2_Router` |
| UniV2_USDC_WETH_pair | `0xB4e16d0168e52d35CaCD2c6185b44281Ec28C9Dc` | `UniswapV2Pair` | yes | no | `` | `flattened_markers` | 10 | `ch2_harvest/0xb4e16d0168e52d35cacd2c6185b44281ec28c9dc_UniV2_USDC_WETH_pair` |
| UniV2_USDT_WETH_pair | `0x0d4a11d5EEaaC28EC3F61d100daF4d40471f1852` | `UniswapV2Pair` | yes | no | `` | `flattened_markers` | 10 | `ch2_harvest/0x0d4a11d5eeaac28ec3f61d100daf4d40471f1852_UniV2_USDT_WETH_pair` |
| USDC | `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48` | `FiatTokenProxy` | yes | yes | `0x43506849d7c04f9138d1a2050bbf3a0c054402dd` | `flattened_markers` | 6 | `ch2_harvest/0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48_USDC` |
| USDT | `0xdAC17F958D2ee523a2206206994597C13D831ec7` | `TetherToken` | yes | no | `` | `single_file` | 1 | `ch2_harvest/0xdac17f958d2ee523a2206206994597c13d831ec7_USDT` |
| WETH | `0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2` | `WETH9` | yes | no | `` | `single_file` | 1 | `ch2_harvest/0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2_WETH` |
| yCRV_Curve_pool_Vyper | `0xdF5e0e81Dff6FAF3A7e52BA697820c5e32D806A8` | `Vyper_contract` | yes | no | `` | `vyper_raw` | 1 | `ch2_harvest/0xdf5e0e81dff6faf3a7e52ba697820c5e32d806a8_yCRV_Curve_pool_Vyper` |
| yCurve_vault | `0x45F783CCE6B7FF23B2ab2D70e416cdb7D6055f51` | `Vyper_contract` | yes | no | `` | `vyper_raw` | 1 | `ch2_harvest/0x45f783cce6b7ff23b2ab2d70e416cdb7d6055f51_yCurve_vault` |
| HVault_fUSDT_current_impl | `0x0de5f3a958f8e927c5b27d202d12b607e213d08c` | `VaultV2` | no | no | `` | `standard_json` | 21 | `ch2_harvest/0x0de5f3a958f8e927c5b27d202d12b607e213d08c_HVault_fUSDT_current_impl` |
| USDC_impl_435068 | `0x43506849d7c04f9138d1a2050bbf3a0c054402dd` | `FiatTokenV2_2` | no | yes | `0x800c32eaa2a6c93cf4cb51794450ed77fbfbb172` | `standard_json` | 23 | `ch2_harvest/0x43506849d7c04f9138d1a2050bbf3a0c054402dd_USDC_impl_435068` |

## Notes

- `HVault_fUSDT_proxy` currently reports Etherscan implementation `0x0de5f3a958f8e927c5b27d202d12b607e213d08c`, while the assignment-relevant listed implementation is `0x9b3be0cc5dd26fd0254088d03d8206792715588b`.
- `HVault_fUSDT_current_impl` was archived recursively from proxy metadata on `HVault_fUSDT_proxy`.
- `USDC_impl_435068` was archived recursively from proxy metadata on `USDC`.
