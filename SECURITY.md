# Security Policy

## Reporting a vulnerability

Please report security issues **privately**. Do not open a public issue, pull request, or
discussion for anything security-relevant.

Use [**GitHub Private Vulnerability Reporting**](https://github.com/Capminal/capminal-contracts/security/advisories/new).
Reports filed there stay private, are tracked alongside the code, and let us credit you in the
resulting advisory.

A useful report includes:

- affected contract and file/line, and the commit you reviewed
- the impact you believe it has, and the conditions required to reach it
- a proof of concept where possible (a Foundry test is ideal)
- any deployment addresses or parameters you tested against

Please tell us which parameters you tested with. Contracts in this repository are configured at
deploy time and several are tuned live by the admin, so figures in a README are not necessarily the
values running in production — reading them from the deployed contract avoids conclusions that do
not apply to the live system.

## What to expect

| | |
|---|---|
| Acknowledgement | within 3 business days |
| Initial triage | within 10 business days |
| Status updates | at least every 2 weeks while open |

We will tell you plainly whether we consider a finding valid, and if we disagree we will explain
why with reproducible numbers. We ask that you hold public disclosure until a fix has shipped, or
until we have jointly agreed that no fix is required. We are happy to review a draft write-up for
factual accuracy before you publish, and we credit reporters in the published advisory unless you
prefer otherwise.

We do not currently run a paid bug bounty.

## Scope

In scope — contracts under `projects/*/src/`:

- `projects/capu/src/` — `Capu`, `ScapStaking`, `MintRateMath`
- the deployed Base mainnet instances of the above

Out of scope:

- `projects/cap-staking/` — **deprecated and holding no funds** (see its README)
- the `$CAP` token itself, which is third-party and outside this repository
- off-chain infrastructure (LLM Gateway, front-ends, RPC providers)
- findings that require a compromised admin key, or that depend on parameter values not actually
  configured on the deployed contracts
- automated scanner output submitted without a working proof of concept

## Safe harbour

We will not pursue or support legal action against anyone who reports in good faith under this
policy, provided they do not access user funds or data, do not degrade the service for others, and
give us a reasonable window to respond before disclosing publicly.
