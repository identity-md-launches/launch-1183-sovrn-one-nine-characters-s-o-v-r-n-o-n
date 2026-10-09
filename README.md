# SOVRN.ONE / SVO

Trading fees from the launch's SVO/IMD pool fund the inference of a voice AI. All hook fees, collected only in IMD (an ERC-20), go to one immutable LifeForceVault: 70% is earmarked for inference and 30% for manually buying SVO to burn. The vault never swaps; the REFUEL_SAFE withdraws each reserve and the operators act by hand. SVO holders receive no payouts, rewards or returns.

This project adapts IMD launch #1040, `identity-md-launches/launch-1040-og-symbol-og-the-launch-s-standard-token`, commit `c1d98b5`, under the existing MIT source licences, through IMD launch #1069 (an ETH-paired version of this code, commit `19c642a`, which this repository imported unmodified as its baseline). Changes from #1069: the fee currency is IMD instead of native ETH, the hook handles IMD as either currency0 or currency1, and the vault accounts IMD by its token balance. Changes from the original base: renamed the token and hook to SovrnToken and SovrnHook, removed the distributor, auction, NFT and team-payment paths, and routed every fee to the vault. No audit is claimed.

## Launch parameters

| Parameter | Value |
| --- | --- |
| Chain | Robinhood Chain, chain id **4663** (the contracts do not check the chain id: the launch factory alone decides the chain, and the hook and vault constructors do not require code at the IMD address) |
| Token contract | `SovrnToken`, no constructor arguments |
| Name / symbol | **SOVRN.ONE** / **SVO**; name is nine ASCII characters, dot at index 5 |
| Supply / decimals | **1,000,000,000** / **18**; exactly **10^27** minor units minted to the deployer |
| Pair | **IMD**, `0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127`, 18 decimals, a hard-coded constant |
| Currency order | `{IMD, SVO}` sorted by address: IMD is currency0 exactly when its address is lower than the token's (`hook.imdIsCurrency0()`) |
| Opening price / cap | Set by the launch factory; the hook accepts whatever it initializes. `launch.json` carries an indicative price only (3,000 IMD cap, IMD as currency0) |
| Pool LP fee / tick spacing | **12500 (1.25%)** / **60** |
| Hook flags | **10444**, hex **0x28cc**, masked to the low 14 address bits |
| Hook constructor | `(IPoolManager manager, SovrnToken token, address factory)` |
| Manifest arguments | Flat `["$poolManager", "$token", "$factory"]` |
| Child constructor | `new LifeForceVault(manager, token, address(this))` inside the hook |
| REFUEL_SAFE | **0xEb57c52272B90F989C41B739e2ccc5f00bF7697C** |
| DEAD | **0x000000000000000000000000000000000000dEaD** |

The pool LP fee is additional to the hook fee. The factory chooses the launch liquidity allocation.

The token has plain ERC-20 transfers and allowances, with no tax, owner, further minting, pause, blacklist or upgrade. A transfer to DEAD increases `totalBurned`; `totalSupply` remains 10^27. Burning here means transferring to DEAD, not reducing supply.

## IMD assumptions and risks

IMD is an independent token with its own owner and rules, which this code does not control. The contracts treat it as a plain ERC-20 and are written so that an unusual IMD cannot make them credit more than they hold, but they cannot prevent it from hurting the pool:

- If IMD refuses a transfer to the vault (a blacklist, a pause, a transfer hook), a swap whose fee is taken directly reverts. The claims fallback only runs when the manager holds less IMD than the fee, and its redemption would revert for the same reason until the vault can receive IMD. Trading on the hooked pool stops while that lasts.
- If IMD charges a transfer fee or confiscates balances, the vault's reserves shrink with its balance (see Vault accounting); withdrawals can never exceed what it actually holds. With a transfer-fee IMD every **buy** (IMD input) reverts for a standard router with `CurrencyNotSettled`, because the hook takes the full fee out of the manager while the router's transfer credits only the net amount; sells keep working. The real IMD moves exactly today (`test/Fork4663.t.sol`).
- A refusing or false-returning IMD makes the Safe's withdrawals revert and leaves the reserves unchanged.
- A reverting or non-standard `balanceOf` makes the vault's reserve views and the Safe's withdrawals revert with `TransferFailed` until it works again. A swap with a non-zero fee also depends on the manager's IMD balance; a swap whose fee is zero does not.

What the deployed IMD on chain 4663 can do (read from the chain on 2026-10-09, not controlled by this code):

- It has an `owner()`, currently `0x047F606fD5b2BaA5f5C6c4aB8958E45CB6B054B7`, an address with no code, so one externally owned key. It is not a proxy.
- The owner can call `setV4Config(poolManager, gate, bool)`. It is unset today. When set for the Uniswap v4 manager, every IMD transfer **into or out of** that manager reverts unless the gate contract approves it (checked on a fork of chain 4663: the token applies the check when either the sender or the recipient is the configured manager). That would stop this pool's buys (the router's IMD settlement into the manager fails even when the hook takes no fee or falls back to claims, so the claims fallback is not a way for trading to continue), sells (the trader's IMD output), `redeemFees()`, **liquidity providers adding IMD, and liquidity providers withdrawing their IMD**. The vault's own withdrawals to the Safe are not manager transfers and would keep working.
- IMD has a `blocked(address)` blocklist (false today for the manager and the Safe). Whether and how the owner can set it, and so whether it could stop the vault's or the Safe's transfers, was **not verified** (the token's source was not available to the reviews; no owner-callable setter was found by probing). Ask the IMD owner, and record what was and was not verified.
- IMD declares itself a LayerZero OFT (`oftVersion()`, `peers`, `setPeer`, `lzReceive`). Under that standard a message from a configured peer credits IMD on this chain, and the owner can point a peer at a contract it controls, so the single owner key can in effect mint IMD without bound and sell it into this pool, diluting the IMD held by liquidity providers and by the vault. This is inferred from the declared standard, not read from verified source.
- The real PoolManager's owner (`0x2BAD8182C09F50c8318d769245beA52C32Be46CD`, no code) also owns its protocol-fee controller (`0x6d0009504D129CF5002Dba61D9Ae8575AA79314c`). That one key can set a protocol fee on this pool at any time (bounded by the vendored v4-core to 0.1% of swap input per direction, paid in IMD on buys and SVO on sells; it does not change the hook fee) and can replace the controller. It cannot pause the pool or move liquidity or vault funds.
- Before launch, ask the IMD owner whether the gate will ever be enabled and, if so, that this pool's transfers will be approved. After deployment, record `blocked()` for the hook, the vault and the Safe.

## Fees and settlement

The hook fee applies only to the single pool identified by `hook.poolKey()`. Anyone can create and fund another SVO/IMD pool without this hook; trades there pay no fee to this vault and do not use the launch buy-fee decay. Removing liquidity pays no hook fee. Adding liquidity is restricted for the first 60 minutes after initialization (`beforeAddLiquidity`): only the launch factory, or any caller in the pool's opening block (so an atomic seeding transaction works whichever contract performs it), may add. This closes the route of adding an IMD-only range just beyond the price and letting sellers move the price through it to receive SVO without the opening buy fee. After the hour anyone may add liquidity; by then the buy fee is at most 3.5%, the same as the normal fee. The factory's own seeded ranges are outside this rule. If the real factory seeds liquidity in a later block through a contract other than the `factory` argument, that seeding reverts. A **buy** pays IMD in and receives SVO; a **sell** pays SVO in and receives IMD. Every fee is paid in IMD.

Sells always pay **3.5%**. Buys begin at **50%**, decay linearly for **3,600 seconds (60 minutes)** from the successful pool initialization timestamp, and stay at **3.5%** thereafter. At elapsed **0 / 1800 / 3600 seconds** the buy fee is **50% / 26.75% / 3.5%**. A swap in the first-hour window pays the rate at the swap's block timestamp.

The rate uses WAD **10^18**: `NORMAL_FEE = 35 * 10^15`, opening rate `5 * 10^17`, and the decreasing component is `465 * 10^15 * (3600 - elapsed) / 3600`. Integer divisions round down.

| Swap mode | Fee handling (all in IMD) |
| --- | --- |
| Buy, exact IMD input | Deduct `floor(requestedIMD * rate / WAD)` before the AMM swap. A price-limit partial fill uses `floor(actualAMMIMD * rate / (WAD - rate))`. |
| Buy, exact SVO output | Charge `floor(actualAMMIMD * rate / (WAD - rate))` in IMD after the swap. |
| Sell, exact SVO input | Charge `floor(actualGrossIMD * rate / WAD)` from the actual IMD output. |
| Sell, exact IMD output | Quote `floor(requestedNetIMD * WAD / (WAD - rate))` gross IMD, then charge `floor(actualGrossIMD * rate / WAD)`. Partial fills charge only actual output. |

For IMD-specified modes, a self-only reverting quote swap measures the actual IMD delta; the actual swap must match that quote. The nested swap's state, LP accounting and logs roll back. Exact-output swaps are therefore supported in both directions. The same logic runs for both currency orders: "IMD leg" means `amount0` when IMD is currency0 and `amount1` otherwise.

**100%** of each hook fee is sent directly by `PoolManager.take` to the vault when the manager's current IMD balance covers the entire fee. Otherwise the hook mints the entire fee as ERC-6909 claims (currency id `uint160(IMD)`) and records the total in `claimFees`.

Anyone can call `redeemFees()` after settlement. It opens a manager unlock, burns all recorded claims and takes the IMD directly to the immutable vault. Failure reverts the counter reset and claim burn, permitting a later retry. The hook holds no IMD or SVO after any swap, and has no `receive()` or fallback: plain ETH sent to it reverts. Unsolicited ERC-6909 claims beyond `claimFees` sent to the hook have no forwarding or rescue function and do not divert recorded fees. The same holds for plain ERC-20 IMD or SVO sent to the hook's address by mistake: the hook has no function that moves an ERC-20 balance it holds, so such a transfer is permanently lost (a rescue function would add a privilege the design excludes).

Send voluntary funding to `hook.vault()` as an ordinary IMD transfer, then anyone may call `sync()`.

**Router ordering.** During `afterSwap` the hook takes the IMD fee out of the manager. A router that does `sync(IMD)`, transfers its IMD input, swaps and only then calls `settle()` is credited the input minus the fee and the swap reverts with `CurrencyNotSettled` on this pool, while it succeeds on a pool without the hook. The condition is where the manager's IMD snapshot is taken: `settle()` credits the manager's IMD balance minus the balance at the last `sync(IMD)`, and the hook's fee take lowers the balance during the swap. So any router that calls `sync(IMD)` **before** the swap (whether it transfers before or after the swap) is credited the input minus the fee and reverts; a router whose `sync(IMD)` and transfer both come **after** the swap (the Uniswap v4 router and the Universal Router) is unaffected, as are sells. An integration that syncs IMD before the swap must add the fee to its payment. No delivered test exercises either ordering.

## Vault accounting and callers

`INFERENCE_BPS = 7000` and `BUYBACK_BPS = 3000`. An ERC-20 gives the vault no hook on receipt, so reserves are derived from `IMD.balanceOf(vault)`: whatever arrived since the last checkpoint is split `floor(x * 3000 / 10000)` to buyback and the entire remainder to inference. Thus **1 wei → 1/0**, **10 wei → 7/3**, and **11 wei → 8/3** inference/buyback. The split applies to the unrecorded balance as a whole, not per receipt, so several small fees that arrive before a checkpoint split together.

`inferenceReserve()` plus `buybackReserve()` always equals the vault's IMD balance exactly. If the balance falls below the recorded checkpoints (an IMD transfer fee or a seizure), the views clamp to the balance and inference keeps priority: the shortfall reduces buyback first. The stored checkpoints are only ever raised, never written down: `sync()` (permissionless) and the withdrawals record new IMD, split 70/30 as a whole, and when new IMD was seen `sync()` emits `LifeForceFunded(address(0), amount, inference, buyback)`. Because a shortfall leaves the checkpoints alone, IMD that later returns restores the original split whoever called `sync()` in between. **The converse:** the vault cannot tell returning IMD from new IMD. After a loss that is never reversed (a seizure, a transfer fee, an outflow not made through the vault), every later receipt first refills the unbacked part of the stored inference checkpoint, then the unbacked buyback checkpoint, and only receipts beyond the old total are split 70/30 again. During that time `sync()` records nothing and emits no `LifeForceFunded`. No IMD is lost and the Safe can never withdraw more than the balance; an unreversed loss is in effect shared across both reserves out of future income. Withdrawals also record new IMD (split 70/30) without emitting `LifeForceFunded`, so the event is complete only if `sync()` is called before each withdrawal. A withdrawal during a shortfall pays at most the clamped view and reduces the stored reserve by exactly what it paid. There is no other sweep.

The vault has no `receive()`: a plain ETH transfer reverts. ETH forced in by selfdestruct cannot be refused and is stranded: it is not accounted and cannot be withdrawn.

| Caller | Allowed action |
| --- | --- |
| REFUEL_SAFE only | `withdrawInference(amount)` and `withdrawBuyback(amount)`, each bounded by its own reserve and paid in IMD only to REFUEL_SAFE. Both use a shared reentrancy guard, debit before payment, and revert all changes on a failed or false-returning transfer. A zero withdrawal pays nothing but emits its event. |
| Anyone | Send IMD or SVO to the vault, call `sync()`, `burn()` or `redeemFees()`, and read all public views. |
| Anyone calling `burn()` | Send the vault's **entire** SVO balance only to DEAD. Zero balance reverts. No IMD is moved, no approvals are issued, and there is no alternate token recipient. |
| Supplied factory via PoolManager | Initialize the single pool once. It must be `{IMD, SVO}` in address order, fee 12500, this hook and positive tick spacing. The first spacing is bound permanently; the manifest selects 60. Deployment, initialization and initial liquidity seeding must be atomic. |
| Supplied PoolManager only | Drive `beforeInitialize`, `beforeAddLiquidity`, `beforeSwap`, `afterSwap` and `unlockCallback`; callbacks also enforce their pool and operation state. |
| Hook itself only | Enter the reverting quote helper while a swap is active. |

Only REFUEL_SAFE has ongoing discretionary custody powers. The factory and manager have the protocol entry responsibilities above, not withdrawal authority. There are no owners, setters, upgrades, pause powers or other privileged recipients. The manager is supplied, never hardcoded; the vault checks its code at construction and does not otherwise use it. The token, IMD and a nonzero hook address are checked too; the constructing hook has no runtime code yet.

Events: token `Transfer` and `Approval`; hook `PoolOpened(timestamp)`, `FeePaid(router,buy,grossIMD,fee,asClaim)` and `ClaimsRedeemed(amount)`; vault `LifeForceFunded(from,amount,inference,buyback)` (emitted only by `sync()`, with `from` = the zero address), `InferenceWithdrawn(amount)`, `BuybackWithdrawn(amount)` and `Burned(amount)`. `FeePaid.router` identifies the calling router, not the trader. Views include `vault()`, `poolKey()`, `imdIsCurrency0()`, `launchFeeNow()`, `decayMinutesLeft()`, `claimFees()`, both reserves, `sovrnHeld()`, `imd()` and token `totalBurned()`.

## Preparation and operation

The unchanged `foundry.toml` pins **Solidity 0.8.26**, **Cancun**, optimizer **200 runs**, **via_ir = true**, and **`bytecode_hash = "none"`**. Dependencies are already ordinary vendored files in `lib/`; no new packages are needed. The hook is the base's direct v4 callback implementation, with no added base-class dependency, share tokens, transient hook storage or role framework. Enabled permissions are exactly `beforeInitialize`, `beforeSwap`, `afterSwap`, `beforeSwapReturnDelta`, `afterSwapReturnDelta`; all nine others are false.

`script/PrepareLaunch.s.sol` is an offline pure helper, with no environment reads or broadcast:

1. Supply the actual chain PoolManager, freshly deployed SovrnToken and initializing factory to `initCode(manager, token, factory)`. The token has no constructor arguments and the factory must hold its whole initial supply.
2. Hash that code and call `mine(create2Deployer, initCodeHash, firstSalt, attempts)`. The CREATE2 deployer is the actual contract executing CREATE2; it need not equal the initializing factory argument. If no match is found, continue at `firstSalt + attempts` without overflowing uint256.
3. Check `predict(create2Deployer, salt, initCodeHash)` and the low 14 bits (**10444**), then have the launch system deploy exactly that code, initialize the manifest pool and seed its initial liquidity atomically. A previous salt must be mined again for this initcode.
4. Check the factory is on chain id **4663**, constructor arguments, token identity, Safe address, vault linkage and bytecode against the prepared artifacts. `launch-attestation.json` records source hashes, compiler settings, ABIs and constructor-free creation bytecode hashes; regenerate with `python3 script/attest.py`, or verify with `python3 script/attest.py --check`. Concrete hook initcode includes the actual three arguments and cannot have one universal hash or salt.

The manifest has exactly five top-level keys: `kind`, `hook`, `token`, `pool` and `notes`. The attestation binds the manifest and every delivered test file by SHA-256, excluding disposable `test/scratch/` files.

Confirm atomic liquidity seeding in the actual factory transaction before launch. An initialized v4 pool with no liquidity permits a zero-delta swap to move its price to the caller's limit at no token cost. The hook charges zero on that zero IMD delta; deployment plus initialization alone cannot protect the opening price while liquidity is absent.

After launch, no setters or setup transactions exist. The Safe operators monitor both reserves and any claim backing, arrange permissionless redemption when needed, withdraw inference funds in IMD (and sell it for the USD that the voice provider requires), and withdraw buyback funds to acquire SVO by hand with appropriate trade limits. They transfer acquired SVO to the vault and anyone calls `burn()`. The contracts enforce the withdrawal destination and reserve bounds; they cannot enforce what the Safe does with withdrawn IMD or schedule its purchases. Operators must confirm control of the specified Safe on chain 4663, including its signing threshold, before launch. Read from the chain on 2026-10-09, the Safe is a Safe 1.5.0 proxy with three owners (all without code). Its signing threshold was 1 when the first review read it and had been raised to **2** when read again later that day. The contracts have no delay, rate limit or alternative recipient, so the Safe's signing policy is the only control over every collected fee: any two of the three keys can withdraw the entire vault.

Both reserves pay the same REFUEL_SAFE, which can withdraw their combined balance without any SVO purchase or burn. The 70/30 split is accounting only.

## Validation and scope

Run `forge build`, `forge test` and `forge fmt --check`. All integration tests use the **real vendored v4 PoolManager deployed locally**, with a minimal two-token settlement router and a **mock IMD placed at IMD's real address** with the chain id set to 4663 (`MockIMD` can be switched to refuse a recipient, return false, charge a transfer fee, or call back a target, to model a misbehaving IMD). Each fee, vault, settlement, security, lifecycle and launch suite runs in **both currency orders** (IMD below and above SVO). `Launch.t.sol` additionally mines and deploys the real CREATE2 initcode and checks child deployment, factory authorization, wrong-chain and missing-IMD rejection, local deployment gas, and EIP-170 and EIP-3860 size bounds.

Run `python3 -B -I -m unittest discover -s test -p test_attestation.py -v` for attestation regressions.

Gas on a live chain can differ greatly from a local run: on Sepolia the same contracts cost about seven times what the local EVM reports, so always estimate deployment against the target RPC. Measured with `eth_estimateGas` against Robinhood Chain (4663) on 2026-10-08: `SovrnToken` about 344,000 gas; the hook plus its vault through the standard CREATE2 deployer about 2,121,000 gas (token supplied by a state override), against the 16,777,216 per-transaction cap.

`test/Fork4663.t.sol` rehearses the real thing on a fork of Robinhood Chain: the real IMD token and the real v4 PoolManager with this hook, vault and token, in both currency orders (real IMD moves exactly, with no transfer fee, into the vault and out to the Safe; fees on the real manager in all four modes; Safe-only withdrawals; burn). It is skipped unless `FORK_4663_RPC` is set: `FORK_4663_RPC=https://rpc.mainnet.chain.robinhood.com forge test --match-contract Fork4663 -vv`. A fork uses the local gas schedule, so it checks behaviour, not gas. The real manager's protocol-fee controller assigned this pool a protocol fee of 0 at the time of the rehearsal; the controller can change a pool's protocol fee later and that is outside this code's control.

This deliverable includes no deployment transactions. Local tests and source review do not establish live-chain readiness. Commit after the second swarm review: the launch swarm's admission floor parked launch #1173 for two blocking findings (constructor chain-id and IMD-code gates; no liquidity callbacks); this revision removes the gates and adds `beforeAddLiquidity`, changing the hook flags from 8396 to 10444. These changes have not been reviewed by the swarm. A separate independent adversarial review and a chain-specific deployment rehearsal remain with the launch process; no external security certification is asserted. Static analyzers and formal verification were not run. `test/Fork4663.t.sol` was run on 2026-10-08 against `https://rpc.mainnet.chain.robinhood.com`; it is skipped in a default `forge test` (no `FORK_4663_RPC`) and must be re-run before launch. An independent audit by the IMD swarm (job `26cf0d3a-2bd3-4602-8cb8-58ba9beb5c8a`, commit `a939314`) reported six low and three informational findings; this revision addresses them. A second swarm review (job `165186a0-9696-443d-8524-caca2ea94b45`, commit `255cafb`) reported two low and six informational findings; the changes after it are documentation only. Neither report makes the code audited or secure, and no independent human audit has been done. `test/REVIEW.md` and `test/README.md` are historical records of the ETH-paired review.
