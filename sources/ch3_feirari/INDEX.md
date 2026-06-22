# ch3_feirari Source Archive

Archive-only reconstruction from Etherscan mainnet metadata and verified sources. No challenge RPC calls were used for this tree.

## Primary Targets

| Address | Label | Contract | Path | Notes |
|---|---|---|---|---|
| `0xc54172e34046c1653d1920d40333dd358c7a1af4` | `Unitroller_proxy_FuseR1Pool8` | `Unitroller` | `sources/ch3_feirari/0xc54172e34046c1653d1920d40333dd358c7a1af4_unitroller_proxy_fuser1pool8` | proxy -> 0xe16db319d9da7ce40b666dd2e365a4b8b3c18217 |
| `0xbb025d470162cc5ea24daf7d4566064ee7f5f111` | `fETH_CEther` | `CEtherDelegator` | `sources/ch3_feirari/0xbb025d470162cc5ea24daf7d4566064ee7f5f111_feth_cether` | proxy -> 0xbdaddc6a1321ed458b53ab9e51dc0de8dba78d43 |
| `0x7e9ce3caa9910cc048590801e64174957ed41d43` | `fDAI` | `CErc20Delegator` | `sources/ch3_feirari/0x7e9ce3caa9910cc048590801e64174957ed41d43_fdai` | proxy -> 0x67db14e73c2dce786b5bbbfa4d010deab4bbfcf9 |
| `0x6b175474e89094c44da98b954eedeac495271d0f` | `DAI` | `Dai` | `sources/ch3_feirari/0x6b175474e89094c44da98b954eedeac495271d0f_dai` | primary archive |
| `0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2` | `WETH` | `WETH9` | `sources/ch3_feirari/0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2_weth` | primary archive |
| `0xba12222222228d8ba445958a75a0704d566bf2c8` | `BalancerVault` | `Vault` | `sources/ch3_feirari/0xba12222222228d8ba445958a75a0704d566bf2c8_balancervault` | primary archive |
| `0x60594a405d53811d3bc4766596efd80fd545a270` | `UniV3_DAI_WETH_005pct` | `UniswapV3Pool` | `sources/ch3_feirari/0x60594a405d53811d3bc4766596efd80fd545a270_univ3_dai_weth_005pct` | primary archive |

## Derived Implementations

| Address | Label | Derived From | Path |
|---|---|---|---|
| `0xe16db319d9da7ce40b666dd2e365a4b8b3c18217` | `Unitroller_proxy_FuseR1Pool8_Comptroller_impl` | `0xc54172e34046c1653d1920d40333dd358c7a1af4` | `sources/ch3_feirari/0xe16db319d9da7ce40b666dd2e365a4b8b3c18217_unitroller_proxy_fuser1pool8_comptroller_impl` |
| `0x67db14e73c2dce786b5bbbfa4d010deab4bbfcf9` | `fDAI_impl` | `0x7e9ce3caa9910cc048590801e64174957ed41d43` | `sources/ch3_feirari/0x67db14e73c2dce786b5bbbfa4d010deab4bbfcf9_fdai_impl` |
| `0xbdaddc6a1321ed458b53ab9e51dc0de8dba78d43` | `fETH_CEther_impl` | `0xbb025d470162cc5ea24daf7d4566064ee7f5f111` | `sources/ch3_feirari/0xbdaddc6a1321ed458b53ab9e51dc0de8dba78d43_feth_cether_impl` |

## Key Vulnerability Entry Points

- `Unitroller Comptroller impl exitMarket`: `sources/ch3_feirari/0xe16db319d9da7ce40b666dd2e365a4b8b3c18217_unitroller_proxy_fuser1pool8_comptroller_impl/src/Comptroller.sol:172` -> `function exitMarket(address cTokenAddress) external returns (uint) {`
- `fETH impl borrowFresh`: `sources/ch3_feirari/0xbdaddc6a1321ed458b53ab9e51dc0de8dba78d43_feth_cether_impl/src/contracts/CToken.sol:755` -> `function borrowFresh(address payable borrower, uint borrowAmount) internal returns (uint) {`
- `Archived CEther doTransferOut (Unitroller bundle)`: `sources/ch3_feirari/0xc54172e34046c1653d1920d40333dd358c7a1af4_unitroller_proxy_fuser1pool8/src/CEther.sol:142` -> `(bool success, ) = to.call.value(amount)("");`
- `Archived CEther doTransferOut (Comptroller impl bundle)`: `sources/ch3_feirari/0xe16db319d9da7ce40b666dd2e365a4b8b3c18217_unitroller_proxy_fuser1pool8_comptroller_impl/src/CEther.sol:138` -> `(bool success, ) = to.call.value(amount)("");`

## Notes

- `metadata.json` captures compiler settings, verification state, and any Etherscan `Implementation` pointer.
- `abi.json` is sourced from `./tools/recon.sh fetch_abi ethereum <addr>` for each archived contract address.
- Proxy contracts discovered through Etherscan were archived recursively into their own address-labelled directories.
- The direct `fETH` implementation pointer (`0xbdaddc6a...`) resolves to a `CEtherDelegate` bundle where `CEther.sol` still shows `to.transfer(amount)`, while the broader Fuse source bundles archived from Unitroller and Comptroller include the vulnerable `to.call.value(amount)("")` variant. This archive preserves that discrepancy rather than normalizing it away.
