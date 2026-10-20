# VeriSphere Core

## Overview

VeriSphere is a truth-staking protocol deployed on Avalanche. This `core/` repository contains the on-chain foundation of the system:

- **VSPToken** (ERC-20) + **Authority** (role control for mint/burn)
- **PostRegistry** (claims + links as posts, duplicate detection)
- **LinkGraph** (directed evidence graph; cycles permitted)
- **StakeEngine** (consolidated lots, epoch updates, positional weighting, mint/burn settlement)
- **ScoreEngine** (pure/read-only scoring: `baseVS` and `effectiveVS`, cycle-safe)
- **ProtocolViews** (read-only aggregation convenience)

The higher-level application stack (indexer/backend/frontend) lives in other repos, but **all scoring and settlement rules that must be enforced on-chain are defined here**.

---

## 1. VeriSphere as a Truth-Staking Market

VeriSphere is a capital-weighted epistemic game:

- Users publish **claims**
- Users stake **support** (for) or **challenge** (against) — one side per post
- Stakes earn **VSP** when aligned with the claim's Verity Score, and are burned when misaligned
- Claims are connected by a directed **support/challenge graph** via link posts

There are no moderators, votes, or reputation scores in the core protocol. Outcomes emerge economically.

---

## 2. Repository Structure

```
core/
├── script/
│   ├── Deploy.s.sol
│   └── Upgrade.s.sol
├── src/
│   ├── PostRegistry.sol
│   ├── LinkGraph.sol
│   ├── StakeEngine.sol
│   ├── ScoreEngine.sol
│   ├── ProtocolViews.sol
│   ├── VSPToken.sol
│   ├── FeeCollector.sol        # relay fee spender: bounded per call/day, pausable, Timelock-governed
│   ├── authority/
│   │   └── Authority.sol
│   ├── governance/
│   │   ├── GovernedUpgradeable.sol
│   │   ├── PostingFeePolicy.sol
│   │   ├── StakeRatePolicy.sol
│   │   └── ClaimActivityPolicy.sol
│   └── interfaces/
│       ├── IPostingFeePolicy.sol
│       ├── IStakeEngine.sol
│       ├── IClaimActivityPolicy.sol
│       └── IVSPToken.sol
├── test/
│   ├── *.t.sol
│   └── mocks/
├── foundry.toml
└── README.md
```

---

## 3. Posts: Claims and Links

### 3.1 Claims

A **claim post** is a factual assertion (e.g., `"Drug X is safe"`). Claims are immutable, deduplicated via case-insensitive whitespace-normalized hashing.

### 3.2 Links

A **link post** connects two claims as evidence:

- `from → to` with `isChallenge = false`: "from" **supports** "to"
- `from → to` with `isChallenge = true`: "from" **challenges** "to"

A link post itself is stakeable: users can stake **support**/**challenge** on whether the relationship holds.

The link graph permits cycles. Two claims may challenge each other simultaneously. Cycle handling occurs at score computation time in the ScoreEngine (see §5.5).

---

## 4. Verity Score

All scores are conceptually in `[-1, +1]` (implementation uses signed fixed-point **ray** scaling, `1e18`).

Let:

- `S = total support stake` on a post
- `C = total challenge stake` on a post
- `T = S + C`

### 4.1 Base Verity Score (baseVS)

```
If S > C:   baseVS = +(S / T) × RAY
If C > S:   baseVS = -(C / T) × RAY
If S = C or T = 0: baseVS = 0
```

---

## 5. Effective Verity Score

### 5.1 Purpose

`effectiveVS(claim)` is the **display VS** that incorporates evidence from linked claims. `baseVS` is purely local; `effectiveVS` includes upstream influence.

### 5.2 Credibility gate

If `effectiveVS(parent) <= 0`, that parent contributes nothing through its outgoing links.

### 5.3 Link contribution mechanics

For each incoming edge `(parent → target)` via link post `L`:

1. Parent mass = `parentVS × parentTotalStake / RAY`
2. Distribute across parent's outgoing links by stake share
3. Multiply by link VS (base VS of the link post)
4. Challenge links invert the contribution

### 5.4 Bounded fan-in

ScoreEngine processes at most `maxIncomingEdges` (64) incoming links and `maxOutgoingLinks` (64) outgoing links per parent. Both are governance-configurable.

### 5.5 Cycle handling

The link graph permits cycles. The ScoreEngine uses stack-based cycle detection: if a post is already on the computation stack, its contribution for that path is 0. A hard depth limit of 32 provides additional safety.

---

## 6. Epoch Settlement and Mint/Burn

### 6.1 Where settlement is implemented

Epoch gains/losses and mint/burn settlement are implemented in **StakeEngine**. Stakes are consolidated (one lot per user per side per post). Positional weighting is continuous: `positionWeight = 1 - (weightedPosition / sideTotal)`.

### 6.2 Reward neutrality at VS = 0

When the VS is exactly 0, no gain/loss update occurs.

### 6.3 Position rescale

After each snapshot, positions are rescaled so that `max(weightedPosition) < sideTotal`, preventing the zero-rate edge case from withdrawal-induced position drift.

---

## 7. Developer Workflow

Build:

```bash
forge build
```

Test:

```bash
forge test -vv
```

---

## 8. License

MIT.
