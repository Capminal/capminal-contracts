# Capminal Contracts

Open-source smart contracts powering the **Capminal** protocol — staking for the **$CAP** token and
the **CAPU** compute-credit system that funds AI access on the Capminal LLM Gateway.

This is a [Foundry](https://book.getfoundry.sh/) monorepo. Each module lives under `projects/` with
its own `foundry.toml`, sources, and tests.

| Module | Path | Summary |
|---|---|---|
| **Cap Staking** *(deprecated)* | [`projects/cap-staking`](./projects/cap-staking) | Retired. Lock-duration staking for $CAP with a 1×–5× share multiplier. Superseded by the CAPU Vault below — kept for reference only. |
| **CAPU Vault** | [`projects/capu`](./projects/capu) | Two-token system: stake CAP → receive non-transferable **sCAP** → lock sCAP to mint **CAPU**, a compute asset granting $1/day of AI Credit. UUPS-upgradeable, with Synthetix-style streaming CAP rewards. |

The **$CAP** token is deployed on Base mainnet at
`0xbfa733702305280F066D470afDFA784fA70e2649`.

## Repository layout

```
capminal-contracts/
├── foundry.toml            # shared Foundry defaults (extended by each project)
├── pnpm-workspace.yaml
└── projects/
    ├── cap-staking/        # CapStaking — lock-duration staking
    └── capu/               # Capu + ScapStaking — sCAP receipt + CAPU mint vault
```

## Getting started

Install [Foundry](https://book.getfoundry.sh/getting-started/installation), then pull the Solidity
dependencies (tracked as git submodules):

```bash
git clone --recurse-submodules https://github.com/Capminal/capminal-contracts.git
cd capminal-contracts
# if you already cloned without submodules:
git submodule update --init --recursive
```

### Build & test

```bash
# Cap Staking
cd projects/cap-staking && forge build && forge test

# CAPU Vault
cd projects/capu && forge build && forge test
```

Dependencies (OpenZeppelin, OpenZeppelin Upgradeable, PRBMath, forge-std) are managed via Foundry
git submodules under each project's `lib/`.

## Security

These contracts are provided as-is. Always review the source and run your own tests before
interacting with any deployment. See each module's README for detailed security notes.

Found a vulnerability? Please report it privately — see [SECURITY.md](./SECURITY.md) — rather than
opening a public issue.

## License

[MIT](./LICENSE) © 2026 404AI Labs
