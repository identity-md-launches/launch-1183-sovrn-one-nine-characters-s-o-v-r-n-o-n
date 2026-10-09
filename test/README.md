> **Historical.** This file records the swarm's review of the ETH-paired Sepolia delivery (IMD launch 1069). The contracts were then changed to an IMD pair (see the top-level README); the numbers, ETH references and chain id below describe the earlier ETH version and are kept as evidence, not as current documentation.

# SOVRN.ONE test coverage

This contribution extends the accepted tests for the IMD launch #1040 adaptation described in [the project README](../README.md). It changes only tests and test documentation. All integration fixtures deploy the **real vendored Uniswap v4 PoolManager locally**. No mock manager, live fork, network access, new dependency, environment injection, or configuration change is required.

The existing [prepare script](../script/PrepareLaunch.s.sol), [manifest](../launch.json), and [launch attestation](../launch-attestation.json) belong to the accepted implementation. The retained `LaunchTest` exercises the script's real CREATE2 mining, constructor deployment, child linkage and initialization. This contribution does not regenerate these artifacts or make a deployment or audit claim.

## Parameters and authority covered

| Requirement | Expected value |
| --- | --- |
| Token name / symbol | `SOVRN.ONE` / `SVO`; nine name bytes, one full stop at index 5 |
| Supply / decimals | 1,000,000,000 / 18, or `10^27` units minted to the constructor caller |
| Chain | Sepolia rehearsal, `11155111` |
| Pair | Native ETH as currency0; SVO as currency1 |
| Opening price | `sqrtPriceX96 = 792281625142643375935439503360000`, 100,000,000 SVO per ETH, opening cap 10 ETH |
| LP fee / tick spacing | `12500` (1.25%) / `60` |
| Hook fee | Sells 3.5%; buys 50% → 26.75% → 3.5% at elapsed 0 / 1800 / 3600 seconds |
| Decay minutes remaining | 60 / 30 / 0; incomplete minutes round up |
| Hook permissions | Exactly beforeInitialize, beforeAddLiquidity, beforeSwap, afterSwap, beforeSwapReturnDelta, afterSwapReturnDelta; flags `10444` / `0x28cc` |
| Fee destination | 100% to the constructor-created immutable vault; direct ETH if manager balance covers the fee, otherwise the whole fee as native ERC-6909 claims, id `0` |
| Vault split | `INFERENCE_BPS = 7000`, `BUYBACK_BPS = 3000`; buyback gets `floor(value × 3000 / 10000)`, inference gets the remainder |
| Rounding examples | 1 wei → 1/0; 10 wei → 7/3; 11 wei → 8/3 inference/buyback |
| REFUEL_SAFE | `0xb1eC9d1C36974d05eb9889eBf8A150b05791E559` |
| DEAD | `0x000000000000000000000000000000000000dEaD`; transfers increase `totalBurned` without reducing supply |
| Constructors | Token: no arguments. Hook: `(manager, token, factory)`, flat manifest arguments `["$poolManager", "$token", "$factory"]`. Vault is deployed by the hook and absent from the manifest deployment list. |
| Preserved compiler settings | Solidity 0.8.26, Cancun, optimizer 200, via IR, `bytecode_hash = "none"` |

Only REFUEL_SAFE may withdraw either reserve, always to itself and never above that category's available amount. Both methods share a reentrancy guard. A failed payment restores all state. Anyone may donate ETH or SVO, burn the vault's entire SVO balance to DEAD, or redeem all recorded fee claims to the vault. Burning an empty balance reverts. Holders receive no payouts; the Safe pays for inference and performs manual buybacks outside the vault.

Only the supplied PoolManager drives hook callbacks. Only the supplied factory, through the manager, may initialize the one bound pool. Only the hook itself may enter its active quote helper. There are no owners, setters, token minting after construction, pauses, blacklists, token rescue routes, vault swaps, upgrades, or additional withdrawal recipients. Existing tests cover these restrictions and all fourteen permission booleans.

## Added adversarial coverage

| File | Added checks |
| --- | --- |
| `FeeDifferential.t.sol` | Four exact modes against an equally seeded unhooked pool at the launch price; all three required decay times; partial fills and tiny amounts; exact trader, manager and vault movements; LP growth, price, liquidity and protocol-fee rollback; no unsettled deltas after unlock. |
| `SettlementFailures.t.sol` | Empty manager, one wei below the fee, exactly the fee and one wei above; no mixed partial payment; permissionless claim redemption; underpaid ETH and unapproved SVO input roll back prior fees and AMM state; nested-unlock redemption and bad quote limits recover cleanly. Revision additions check accumulated dust-claim rounding, repeated redemption, zero-fee trades with pending claims, and failed settlement preserving earlier claims in both payment modes. |
| `TokenFailurePaths.t.sol` | Finite allowance rollback when balance or recipient checks fail; deployer cannot spend another holder's balance; overwrite and revocation; delegated self-transfer; zero transfers; unlimited allowance through burns and failed spends. |
| `VaultCallbackBoundaries.t.sol` | Full uint256 receipt arithmetic including the maximum, checked against full-precision `FullMath`; a Safe refunds ETH and burns SVO during either withdrawal; same-function and cross-function reentry; a later Safe rejection rolls back those nested actions; counterfactual prefunding and forced dust. |
| `VaultModelInvariants.t.sol` | Independent ledgers for each reserve, withdrawals, forced ETH, held SVO and burns; random donations, both withdrawals, overdraws, unauthorized calls, rejecting receivers, SVO transfers and burns. |
| `AdversarialFees.t.sol` | Extend each independently malformed pool-key case to check `afterSwap` as well as `beforeSwap`. |

Fee comparisons use actual unhooked AMM deltas rather than treating hook events as the oracle. For exact-input buys, the reference input excludes `floor(requestedETH × rate / 10^18)`; partial fills charge `floor(actualAMMETH × rate / (10^18 − rate))`. Exact-output buys use the latter formula. Exact-input sells charge `floor(actualGrossETH × rate / 10^18)`. Exact-output sells quote `floor(requestedNetETH × 10^18 / (10^18 − rate))` and charge on actual gross output. These are the specified base formulas.

The differential fixture additionally enables distinct protocol fees, 500 and 1000 in v4's directional fee units. They are test inputs for detecting a persisted quote, not changes to the launch manifest.

The added rounding regression executes opening buys of 6, 18 and 54 wei, collecting fees of 3, 9 and 27 wei. Direct receipts allocate 29/10 wei to inference/buyback; redeeming all 39 wei together allocates 28/11. This follows the specified split per vault receipt. Both paths deliver all fees to the vault, and repeating redemption changes no balances. A separate regression starts with an existing 0.0005 ETH claim, fails settlement of a later 0.005 ETH fee in each payment mode, then retries and redeems the full 0.0055 ETH.

## Stateful checking and execution

The added invariant campaign runs **256 sequences of 96 actions**, with unexpected reverts failing the campaign. Its action bounds derive from independent model ledgers, not the vault's reserve getters. It checks each reserve separately, actual Safe receipts, ETH conservation, fixed token supply, full burns and absence of vault approvals. Each sequence ends by withdrawing both reserves and burning the remaining SVO. Forced ETH is accumulated separately until a successful withdrawal checkpoints it, matching the implementation's documented treatment of ETH delivered without `receive()`.

The retained lifecycle campaign also runs 256 × 96 actions and covers real swaps, fee claims, redemption, decay and vault operations. Arithmetic and new token property tests use inline **1000-run** settings; no `foundry.toml` edits are needed.

Run the submitted suite with `forge build` and `forge test`. For scratch-local artifacts, the equivalent commands are:

```sh
forge build --out test/scratch/out --cache-path test/scratch/cache
forge test --out test/scratch/out --cache-path test/scratch/cache
```

No submitted test imports from `test/scratch/` or `.imd/reads/`. The pinned protected suites were read as task inputs; their environment-dependent wrappers are not copied into the offline suite. These tests do not verify live Sepolia Safe ownership, RPC state, or externally supplied deployment addresses.

Local revision verification: `forge build` succeeded; the full `forge test` run reported **71 passed, 0 failed, 0 skipped** across 16 suites. Both invariant campaigns completed 256 runs of 96 calls each (24,576 handler calls per campaign) with zero unexpected reverts. Formatting checks passed for the changed Solidity file. This revision adds three tests to the existing settlement suite; no implementation defect was reproduced.
