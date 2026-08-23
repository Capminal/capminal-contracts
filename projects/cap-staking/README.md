# Cap Staking (`CapStaking`)

> [!WARNING]
> **Deprecated — no longer in use.** `CapStaking` is retired. All staked CAP has been withdrawn and
> the contract held no user funds as of this writing. It remains in this repository for reference
> only — do not integrate against it or deploy it.
>
> **Where staking lives now:** [`projects/capu`](../capu). The lock-duration multiplier model was
> removed rather than replaced. CAP is staked into `ScapStaking` for non-transferable **sCAP** 1:1 —
> no lock and no multiplier, a 7-day unbonding cooldown, and 100% of the streaming CAP rewards.
> Users who want compute lock sCAP to mint **CAPU**, and staked CAPU is what grants daily AI Credit
> on the Capminal LLM Gateway. Capital and compute are decoupled.
>
> The description below documents `CapStaking` as designed, for historical reference.

Lock-duration staking for the **$CAP** token. Users lock CAP for a chosen duration to receive
**shares** (used as points for off-chain reward distribution). Longer locks earn a larger share
multiplier.

- **CAP token**: `0xbfa733702305280F066D470afDFA784fA70e2649` (Base mainnet)

---

## Behavior

1. Stake CAP to receive shares.
2. Longer lock → larger share multiplier. Linear from `1x` at `1 week` to `5x` at `96 weeks`.
3. One position per user. A user can:
   - Open a new position if none exists.
   - Add more CAP to an existing position:
     - If the new lock duration is **shorter** than the existing one, the old duration is kept;
       shares are recomputed for the new total amount at the old multiplier.
     - If the new lock duration is **≥** the existing one, the lock is updated; shares are recomputed
       for the new total amount at the new multiplier, and the unlock time is extended to
       `max(oldUnlock, now + newLock)`.
4. Lock-only staking. Min `1 week`, max `96 weeks`. No flexible/unlocked stake.
5. While locked, the user **cannot** unstake by any means.
6. The owner can force-unlock any user's position (`emergencyUnlock`), which returns the principal
   AND clears the user's position in one call.
7. View functions expose user `shares`, `multiplier`, `unlockTime`, and the contract's
   `totalShares` / `totalStaked`.
8. Events (`Staked`, `Unstaked`, `EmergencyUnlock`) are emitted for subgraph indexing. Reward
   distribution itself happens **off-chain** based on the recorded shares.

---

## Contract reference

`CapStaking` is `Ownable` + `ReentrancyGuard`, built on OpenZeppelin v5.

| Function | Caller | Description |
|---|---|---|
| `stake(amount, lockWeeks)` | anyone | Open or top up a position; mints shares by multiplier |
| `unstake(amount)` | anyone | Withdraw principal once `unlockTime` has passed |
| `emergencyUnlock(user)` | owner | Force-unlock a user's position and return their principal |
| `stakeOf(user)` / `sharesOf(user)` / `multiplierOf(user)` / `unlockTimeOf(user)` | view | Position views |
| `totalShares()` / `totalStaked()` | view | Aggregate views |

See `src/CapStaking.sol` and `src/interfaces/ICapStaking.sol` for the authoritative definitions.

---

## Build & test

```bash
forge build
forge test            # runs CapStaking.t.sol
forge test -vvv       # verbose
forge test --gas-report
```

Higher fuzz/invariant runs:

```bash
forge test --profile ci
```

---

## Security notes

- `emergencyUnlock` is an owner privilege intended for migration / emergency exits. After
  deployment, transfer ownership to a multisig.
- Rewards are distributed off-chain from the on-chain `shares` accounting; this contract does not
  custody or stream reward tokens.

## License

MIT — see the [`LICENSE`](../../LICENSE) at the repo root.
