# Capminal Vault (CAPU)

A two-token staking system that funds **AI compute access** on the Capminal LLM Gateway. CAP holders stake their tokens to earn yield and mint a separate **compute asset (CAPU)** that grants $1/day of AI Credit on the gateway. Burning CAPU releases the original locked stake — capital and compute are completely decoupled.

Inspired by the Venice.ai VVV / sVVV / DIEM design, hardened for Capminal's economics.

- **CAP token**: `0xbfa733702305280F066D470afDFA784fA70e2649` (Base mainnet)
- **Contracts**: this directory (`src/`, `test/`)

---

## 1. System overview

```
                            ┌──────────────────────────────────────────┐
                            │   Capminal LLM Gateway (off-chain)       │
                            │   • Indexes Capu `Staked` events         │
                            │   • Credits $1/day × stakedCapu per user │
                            └────────────────▲─────────────────────────┘
                                             │  Staked / Unstaked events
                                             │
                            ┌────────────────┴─────────────────────────┐
                            │ Capu  (ERC20 + built-in staking, UUPS)   │
                            │ • mint / burn gated by ScapStaking       │
                            │ • stake / initiateUnstake / unstake      │
                            └────────────────▲─────────────────────────┘
                                             │  mint() / burn()
                                             │
   user CAP ─stake──►  ┌────────────────────┴──────────────────────────┐
                       │ ScapStaking  (sCAP ERC20 receipt, UUPS)       │
   user CAP ◄─unstake─ │ • stake → mint sCAP 1:1                       │
                       │ • lockAndMintCapu → MintRateMath              │
                       │ • burnAndUnlockScap → exact original ratio    │
                       │ • Synthetix streaming CAP rewards (100% to stakers)│
                       └────────────────▲──────────────────────────────┘
                                        │  notifyRewardAmount(CAP)
                                        │
                                  Admin EOA / Treasury
```

## 2. Asset glossary

| Asset | Type | Issuer | Purpose |
|---|---|---|---|
| **CAP** | ERC20 (external) | Capminal — already deployed | Capital asset. Stake to earn yield + mint compute. |
| **sCAP** | ERC20 **non-transferable** receipt | `ScapStaking` proxy | 1:1 claim on staked CAP. Earns 100% of streaming CAP rewards. Only minted on stake / burned on unstake (transfers revert). |
| **CAPU** | ERC20 (mintable by ScapStaking) | `Capu` proxy | Compute asset. Stake on Capu to receive AI Credit. |
| **AI Credit** | Off-chain accounting | Capminal LLM Gateway | $1/CAPU/day, renewed at 00:00 UTC, non-accumulating. |

---

## 3. User flow

### 3.1 Stake CAP → sCAP

```solidity
CAP.approve(scapStaking, amount);
scapStaking.stake(amount);             // mints `amount` sCAP 1:1 to msg.sender
```
- `balanceOf(sCAP)` directly mirrors the user's staked CAP principal.
- sCAP is **non-transferable** — it can only be minted (on stake) and burned (on unstake). Transfers revert with `NonTransferable`. This keeps the streaming-reward accounting sound (every balance change is checkpointed).
- `stake` mints sCAP equal to the CAP **actually received** (fee-on-transfer safe), not the requested amount.

### 3.2 Earn CAP rewards (Synthetix streaming)

```solidity
scapStaking.earned(user);              // view: CAP currently claimable
scapStaking.claim();                   // pull CAP rewards to caller
```
- Rewards stream linearly over the configured `rewardsDuration` (default 7 days).
- Stakers always receive **100%** of their reward share, whether or not their sCAP is locked (no protocol cut).

### 3.3 Lock sCAP → Mint CAPU

```solidity
uint256 capu = scapStaking.lockAndMintCapu(scapAmount, minCapuOut); // reverts if capu < minCapuOut
```
- `minCapuOut` is a slippage guard: the mint rate depends on the *current global* CAPU supply, which other txs can move in the same block.
- Locks `scapAmount` of the caller's sCAP (cannot be unstaked while locked).
- Mints CAPU via the dynamic [mint rate formula](#5-mint-rate-formula).
- `lockedScap[user] += scapAmount`, `mintedCapuOf[user] += capu`.

### 3.4 Stake CAPU → Earn AI Credit

```solidity
Capu.stake(capuAmount);                // emits Staked event the gateway watches
```
- Gateway indexer credits `$1 × stakedCapu / day` of AI usage to the wallet.
- AI Credit does not accumulate — unused credit at 00:00 UTC is lost.
- Unstake: `Capu.initiateUnstake(amount)` → wait `cooldownDuration` → `Capu.unstake()`.

### 3.5 Burn CAPU → Unlock original sCAP

```solidity
uint256 scap = scapStaking.burnAndUnlockScap(capuAmount);
```
- Burns the user's CAPU (must be unstaked first).
- Unlocks `lockedScap[user] × (capuAmount / mintedCapuOf[user])` sCAP — **independent of the current mint rate**, protecting early minters.

### 3.6 Unstake sCAP → CAP

```solidity
scapStaking.initiateUnstake(amount);   // burns sCAP, starts cooldown
// wait unbondingDuration (default 7 days)
scapStaking.finalizeUnstake();         // transfers CAP back
```

### 3.7 Buying CAPU on DEX (skip staking)

Users who only need AI Credit can buy CAPU directly from a secondary market (CAP/CAPU pool) and stake on `Capu`. They never have to touch sCAP. This is the fast path for non-token-holders.

---

## 4. Reward economics

### 4.1 Streaming admin funding

Admin tops up CAP rewards in batches. The contract spreads them linearly:

```solidity
CAP.approve(scapStaking, capAmount);
scapStaking.notifyRewardAmount(capAmount);
```

- If the current period has ended: `rewardRate = capAmount / rewardsDuration`.
- If the period is still running: `rewardRate = (capAmount + leftover) / rewardsDuration` (extends period).
- Admin can change period length via `setRewardsDuration(d)` only when no period is active.

Recommended operational cadence: weekly top-ups in line with `rewardsDuration = 7 days`. Forgetting a top-up does **not** revert anything — `rewardRate` simply decays to zero and no reward accrues until the next call.

### 4.2 No protocol cut — 100% to stakers

Stakers receive **100%** of streamed CAP rewards regardless of whether their sCAP is locked.
There is no protocol cut. Per-block accounting (inside `updateReward`) is simply:

```
totalAccrued = balance × Δacc
user gets    = totalAccrued
```

(The earlier 80/20 `protocolYieldBps` / `withdrawProtocolFee` mechanism has been removed.)

---

## 5. Mint rate formula

```
mintRate = baseMintRate × exp( adjustmentPower × (currentCapuSupply / targetCapuSupply)³ )
capuMinted = scapLocked / mintRate
```

Implemented in [`src/libraries/MintRateMath.sol`](./src/libraries/MintRateMath.sol) using PRBMath `UD60x18`.

### 5.1 Curve behaviour

| Supply / Target | mintRate / baseRate | Notes |
|---:|---:|---|
| 0 | 1.000 | Cheapest possible mint |
| 0.25 | 1.032 | Curve still nearly flat |
| 0.50 | 1.284 | Starts to noticeably rise |
| 0.75 | 2.325 | Costs ~2.3× more sCAP per CAPU |
| 1.00 (target) | 7.389 (= e²) | "Knee" of the curve |
| 1.50 | 7,944 | Effectively prohibitive |
| > ~1.9 | revert `ExponentTooLarge` | Hard ceiling |

### 5.2 Production calibration (Base mainnet defaults)

Chosen for **30-day payback** at CAP price ≈ $0.0006812 and ~80% of 300M CAP locked at curve target:

| Parameter | Value | Reasoning |
|---|---:|---|
| `baseMintRate` | 44,040 × 1e18 | = 30 days × $1/day ÷ $0.0006812 → locking ≈ $30 worth of CAP mints 1 CAPU at supply=0 |
| `adjustmentPower` | 2 × 1e18 | Matches reference exponent |
| `targetCapuSupply` | 2,725 × 1e18 | = 240M CAP ÷ (2 × baseMintRate) → curve hits the e² knee when ~80% of stakeable CAP is locked |

### 5.3 Recalibrating

When CAP price moves significantly, admin updates parameters live (no upgrade needed):

```solidity
scapStaking.setMintRateParams(newBaseRate, newPower, newTargetSupply);
```

Recommended re-derivation:

```
newBaseMintRate   = paybackDays / currentCapPriceUsd
newTargetSupply   = (expectedMaxStakeableCap × utilizationTarget) / (2 × newBaseMintRate)
```

### 5.4 Sample evolution (production defaults)

How much CAPU is minted and what is the marginal rate as sCAP is progressively locked:

| sCAP locked | CAPU minted | Marginal rate (CAP/CAPU) | AI capacity ceiling |
|---:|---:|---:|---:|
| 5M | ~113 | ~44,047 | $113/day |
| 25M | ~566 | ~44,231 | $566/day |
| 50M | ~1,128 | ~44,790 | $1,128/day |
| 100M | ~2,201 | ~47,020 | $2,201/day |
| 240M (target) | ~2,725 | ~325,500 (= 44,040 × e²) | **$2,725/day peak** |
| > ~290M | revert | — | Hard ceiling |

(Approximate — produced by numerical integration of the curve.)

---

## 6. Contract reference

### 6.1 `Capu` (CAPU token + AI Credit staking)

UUPS upgradeable ERC20 with built-in staking. AI Credit accounting lives off-chain in the LLM Gateway; the contract only emits events.

| Function | Caller | Description |
|---|---|---|
| `mint(to, amount)` | `MINTER_BURNER_ROLE` (only ScapStaking) | Issue new CAPU |
| `burn(from, amount)` | `MINTER_BURNER_ROLE` | Destroy CAPU |
| `stake(amount)` | anyone | Lock CAPU → emit `Staked` (indexer credits AI) |
| `initiateUnstake(amount)` | anyone | Start cooldown |
| `unstake()` | anyone | Finalize after cooldown |
| `setCooldownDuration(d)` | `DEFAULT_ADMIN_ROLE` | Tune cooldown |
| `pause / unpause` | `DEFAULT_ADMIN_ROLE` | Halt user mutations |
| `upgradeToAndCall` | `DEFAULT_ADMIN_ROLE` | UUPS upgrade |

Default `cooldownDuration` = **1 day**.

### 6.2 `ScapStaking` (sCAP receipt + CAPU mint vault)

UUPS upgradeable ERC20 (sCAP = transferable receipt token).

| Function | Caller | Description |
|---|---|---|
| `stake(capAmount)` | anyone | Pull CAP, mint sCAP 1:1 |
| `initiateUnstake(amount)` | anyone | Burn sCAP from unlocked balance, start 7-day cooldown |
| `finalizeUnstake()` | anyone | Transfer CAP back to caller |
| `lockAndMintCapu(scapAmount, minCapuOut)` | anyone | Lock sCAP, mint CAPU via `MintRateMath` (reverts if minted < `minCapuOut`) |
| `burnAndUnlockScap(capuAmount)` | anyone | Burn CAPU, unlock original sCAP proportionally (not pausable) |
| `claim()` | anyone | Pull streaming CAP rewards (not pausable) |
| `notifyRewardAmount(capAmount)` | `DEFAULT_ADMIN_ROLE` | Top up reward pool, restart streaming (sizes stream by CAP actually received) |
| `setRewardsDuration(d)` | `DEFAULT_ADMIN_ROLE` (only when no period active) | Change period length |
| `setUnbondingDuration(d)` | `DEFAULT_ADMIN_ROLE` | Tune unbonding |
| `setMintRateParams(base, power, target)` | `DEFAULT_ADMIN_ROLE` | Recalibrate the curve |
| `pause / unpause` | `DEFAULT_ADMIN_ROLE` | Halt value-adding mutations (exits stay open) |
| `upgradeToAndCall` | `DEFAULT_ADMIN_ROLE` | UUPS upgrade |

Default `unbondingDuration` = **7 days**.

### 6.3 ERC20 transfer semantics for sCAP

```solidity
function _update(from, to, value) internal override {
    if (from != 0 && to != 0) revert NonTransferable();
    super._update(from, to, value);
}
```

- Mints (`from == 0`, on stake) and burns (`to == 0`, on unstake) are allowed.
- All user-to-user transfers / `transferFrom` revert with `NonTransferable`.
- Rationale: sCAP is the Synthetix reward share. Making it non-transferable guarantees every
  balance change is checkpointed by `stake`/`initiateUnstake`, so a transfer can never move
  un-snapshotted reward entitlement (which would otherwise let a fresh receiver drain the pool).

---

## 7. Build, test, deploy

### 7.1 Build & test

```bash
forge build
forge test -vvv
forge test --gas-report
```

Test suites:
- `MintRate.t.sol` — formula correctness, monotonicity, boundary reverts (fuzz)
- `Capu.t.sol` — role gating, stake/unstake/cooldown, pause
- `ScapStaking.t.sol` — stake/lock/mint/burn/unlock, reward streaming, protocol cut, locked-transfer guard
- `Integration.t.sol` — full E2E user journey

### 7.2 Deployment overview

> **Note:** Deployment / upgrade scripts are not part of this public repository. The intended
> deployment sequence is documented below for reference.

A first-time deploy:
1. Deploys `Capu` implementation + `ERC1967Proxy` with `initialize(admin, capuCooldown)`.
2. Deploys `ScapStaking` implementation + `ERC1967Proxy` with the full initializer (admin, CAP, Capu,
   durations, mint-rate params).
3. Grants `MINTER_BURNER_ROLE` on Capu to the ScapStaking proxy.

### 7.3 Funding rewards after deploy

```bash
# Example: 100,000 CAP streamed over 30 days
cast send <CAP> "approve(address,uint256)" <staking> 100000000000000000000000
cast send <staking> "setRewardsDuration(uint256)" 2592000     # only if no period active
cast send <staking> "notifyRewardAmount(uint256)" 100000000000000000000000
```

### 7.4 UUPS upgrade

`Capu` and `ScapStaking` are UUPS-upgradeable; upgrades are authorized by `DEFAULT_ADMIN_ROLE` via
`upgradeToAndCall`. Always run `forge test` against the new implementation before broadcasting, and
verify storage layout compatibility (no removed/reordered state variables).

---

## 8. Secondary market guidance

Liquidity for CAP/CAPU on a DEX lets users acquire compute without minting (and lets minters realize CAP without unstaking).

| Anchor | Value |
|---|---|
| Mint cost ceiling (at supply=0) | 44,040 CAP/CAPU ≈ $30 |
| Mint cost ceiling (at target) | 325,500 CAP/CAPU ≈ $222 |
| Utility-floor (30-day holding) | ~44,040 CAP/CAPU ≈ $30 |

Recommended initial pool price for a launch where mint = 0: **slightly above mint cost** (e.g. +8%, ≈ 47,500 CAP/CAPU). Early arbitrageurs mint at $30 and sell on the pool, naturally deepening liquidity. Concentrated-liquidity (Uniswap V3) ranges between ~30,000 and ~70,000 CAP/CAPU give the best capital efficiency at launch.

LPs should understand the trade-off: CAPU sitting in a pool **is not staked**, so it earns no AI Credit. Providing liquidity converts AI Credit yield into trading-fee yield.

---

## 9. Security posture (V1)

| Concern | V1 setting | Rationale |
|---|---|---|
| Admin authority | **EOA of deployer** | Fast iteration during launch; migrate to multisig + timelock once TVL is meaningful |
| Timelock on upgrades | **None** | Same as above. UUPS upgrade is instant; key compromise → instant takeover risk |
| Reward token | **Only CAP** | Minimal state, smallest attack surface. Multi-token can be added via UUPS upgrade |
| Pause scope | **Both contracts** | Admin halts user mutations on Capu and ScapStaking independently |
| Mint rate guards | None on `setMintRateParams` (any value accepted) | Admin trusted; add `minBaseRate` guard rails in V2 |

**Tech debt to address before mainnet TVL > $1M or external audit:**

1. Migrate `DEFAULT_ADMIN_ROLE` on both proxies to an OpenZeppelin `TimelockController` (24–48h delay) owned by a Gnosis Safe.
2. External audit of: dynamic mint rate edge cases (dust, large supply), reward streaming math during transfers, UUPS upgrade authorization, role rotation flow.
3. Add bounded setters (e.g. enforce `baseMintRate ≥ minBaseRate`) so a compromised admin cannot instantly drain via degenerate params.

---

## 10. Directory layout

```
projects/capu/                                    ← you are here
├── README.md                                     ← canonical spec (this file)
├── foundry.toml, package.json, .env.example
├── src/
│   ├── Capu.sol                                  ← CAPU token + staking
│   ├── ScapStaking.sol                           ← sCAP receipt + mint vault
│   ├── libraries/MintRateMath.sol                ← exponential mint rate
│   └── interfaces/{ICapu,IScapStaking}.sol
├── test/
│   ├── MintRate.t.sol, Capu.t.sol
│   ├── ScapStaking.t.sol, Integration.t.sol, FeeOnTransfer.t.sol
│   └── helpers/{Fixture,MockERC20,MockTaxERC20}.sol
└── lib/                                          ← OZ upgradeable, PRBMath, forge-std
```

---

## 11. License

MIT — see contract source headers.
