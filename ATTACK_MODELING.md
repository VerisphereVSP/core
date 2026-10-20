# VeriSphere Core — Task 3.5: Attack Modeling & Adversarial Scenarios

This document enumerates realistic attack/griefing scenarios for the on-chain core and describes mitigations.

Goal:

> **Attackers cannot extract unbounded value or destabilize the protocol.**

---

## A. Keeper / Snapshot Caller Griefing

### A.1 "No one updates posts" (liveness failure)
**Attack**
- No one calls `StakeEngine.updatePost(postId)`, so snapshots never run and the economic game stalls for that post.

**Mitigations**
- Backend keepers periodically update popular posts.
- UI-driven updates: frontends call `updatePost` (or rely on stake/withdraw triggers, which call `_maybeSnapshot` internally) before showing balances.
- View functions (`getPostTotals`, `getUserStake`, `getUserLotInfo`) project unrealized gains/losses without writing state, so reads are always current even if no snapshot has run.
- Optional on-chain incentive (future): pay the caller a small fee.

---

### A.2 "Excessive updating" (gas grief)
**Attack**
- An attacker repeatedly calls `updatePost` to waste gas and spam events.

**Mitigation**
- `_forceSnapshot` early-returns when `currentEpoch <= lastSnapshotEpoch`, so repeated calls within the same epoch are cheap (only a small read + early return). The attacker still pays gas for the call but cannot trigger work.
- `_maybeSnapshot` (called from stake/withdraw paths) only triggers a full snapshot when `snapshotPeriod` worth of epochs have elapsed.

---

## B. Stake Splitting / Queue Gaming

### B.1 Split stake into many lots to improve position weight
**Attack (intent)**
- Stake 1 token 100 times instead of 100 once, hoping to occupy multiple early positions.

**Mitigation (current implementation)**
- The StakeEngine consolidates: each user holds **at most one lot per (post, side)**. Repeated `stake()` calls by the same user on the same side merge into the existing lot. The lot's `weightedPosition` is updated as the stake-weighted average of the prior position and the new entry position.
- This prevents the splitting attack at the contract level. The user's effective position cannot be better than a single weighted-average position. Adding stake later actually drags the average toward the back of the queue.

### B.2 Sybil splitting across wallets
**Attack**
- A user spreads stake across N wallets to occupy N distinct early lots.

**Mitigations**
- Application-layer sybil resistance (optional KYC, web-of-trust badges) where appropriate.
- The economic incentive is bounded by the size of the per-side budget; N small lots collectively earn the same total as one consolidated stake of equal size on the same side, modulo the position-weight curve. The attack chiefly improves the *position* rather than the budget.
- Future hardening: per-staker aggregation across wallets (requires identity), or minimum lot size to raise the per-wallet cost.

---

## C. Link Spam / Graph Amplification

### C.1 Many incoming links to amplify a claim
**Attack**
- Create hundreds of intermediate claims linked into a target claim to amplify its effective VS.

**Mitigations**
- Stake-weighted contribution distribution (Section 4.4 of the whitepaper, "Conservation of Influence"): a parent's mass is divided across all its outgoing links, so creating more links from one parent dilutes each link's share rather than multiplying influence.
- Posting fees on every claim and link impose a non-trivial cost per node.
- Stake on the link itself is required to make it active; the activity threshold gates spam.
- **Bounded fan-in:** the ScoreEngine processes at most `maxIncomingEdges` per claim (default 64, governance-configurable). Edges beyond the cap contribute zero. This bounds gas regardless of how many links an attacker creates.
- The credibility gate ensures discredited parents and challenged links contribute nothing.
- Effective VS is clamped to `[-1, +1]`.

### C.2 Deep multi-hop amplification chain
**Attack**
- Build deep chains A→B→C→... to try to "boost" far downstream.

**Mitigations**
- Stake-weighted distribution attenuates each hop: a parent's mass is bounded by `parentVS × parentTotalStake`, and the share that flows through any one outgoing link is at most `linkStake / sumOutgoingLinkStake`.
- The credibility gate truncates chains at any node with non-positive effective VS.
- The ScoreEngine's `MAX_DEPTH = 32` hard cap returns zero from any branch deeper than 32 hops.
- The `maxOutgoingLinks` cap (default 64) bounds the share-denominator computation per parent; combined with `maxIncomingEdges`, total edge work per `effectiveVSRay` call is bounded.

### C.3 Cycle exploitation
**Attack**
- Create a cycle (A links to B, B links to A) and attempt to inflate one or both via mutual reinforcement.

**Mitigations**
- Cycle detection at compute time: when the ScoreEngine recurses, any post already on the recursion stack contributes zero for the cycled path. A claim cannot influence its own VS through any chain of links.
- Cycles are not enforced absent at the storage layer (`LinkGraph` permits them); safety is entirely at the ScoreEngine level.
- The credibility gate further stabilizes cycles by silencing any leg whose VS is non-positive.

---

## D. Withdrawal / Snapshot Timing Attacks

### D.1 Stake right before snapshot, withdraw right after
**Attack**
- Attempt to capture reward with minimal exposure.

**Mitigation**
- Per-snapshot delta is proportional to elapsed time and to `(amount × positionWeight)`. A new lot enters at the back of the queue (`weightedPosition = sideTotal` at entry), so its `posWeight = 1 - (sideTotal / sideTotal) = 0` immediately after staking. Such a lot earns ~0 from its first snapshot.
- Snapshots run at most once per `snapshotPeriod`; very short windows yield no incremental rewards.

### D.2 Withdraw immediately before a losing snapshot
**Attack**
- A user on the losing side withdraws right before a snapshot to avoid the burn.

**Mitigation**
- The withdraw path calls `_maybeSnapshot` first, which forces a snapshot if the snapshot period has elapsed. The user thus realizes their losses up to the most recent snapshot before being able to withdraw what remains.
- Between snapshots, view-projected balances are smaller for losing positions, but the actual withdrawable amount is the *stored* lot amount; this is conservative for the protocol (the user can withdraw projected losses they have not yet realized, but they also forfeit any further potential growth).

### D.3 Transient stake that decides a settlement it does not bear (VSP-SEC-004)
**Attack**
- Stake heavily at the start of a window, withdraw before it closes. D.2 lets the leaver keep its unrealised loss; until 2026-10-14 the settlement pool was also the window *average* of the side totals, so the departed stake still chose the winner and set the rate for everyone who stayed, at no risk to itself (reported with PoCs: 36x amplification on a near-balanced post; winner flipped against the majority present).

**Mitigation**
- Ruling 2026-10-14 (option A): the pool a settlement pays on is the capital **present at settlement**, each lot prorated by its presence in the window — the same rule `TimeWeighted.lotDelta` applies to the payout — so the set that decides and the set that bears are one set. Withdrawals stay immediate. Flash stake still counts only for the seconds it stood. Regression: `test/SEC004_PresentPool.t.sol`.

### D.4 Stale position offset after a partial withdraw (VSP-SEC-003)
**Attack**
- Top up a ranked lot (its offset blends toward the tail), withdraw the top-up in the same epoch: the small remaining lot kept the large lot's offset — position weight 0.015 instead of 0.995 — and burned 1.5 % of what an identical lot burned on every losing settlement, while counting in full in the side totals and the score.

**Mitigation**
- `_decreaseUser` scales `posOffset` with the remaining amount (ruling 1c's stated rule, previously unimplemented); a full exit clears it. Regression: `test/SEC003_PosOffsetScale.t.sol`.

---

## E. Authority / Token Role Misconfiguration

### E.1 StakeEngine cannot mint/burn because roles missing
**Attack / failure mode**
- Snapshots that should mint to winners or burn from losers will revert, freezing post evolution.

**Mitigation**
- Deployment scripts must set Authority roles before any user staking:
  - StakeEngine is granted both minter and burner roles.
  - PostRegistry is granted the burner role for posting fee burns.
- Integration tests should assert role assignment at deploy time.

---

## F. Gas / DoS via Large Arrays

### F.1 Many lots make snapshots expensive
**Attack**
- Spam tiny lots so snapshot loops over huge arrays.

**Mitigations**
- Consolidation (B.1): one lot per user per (post, side) caps the lot count at the number of distinct stakers per side.
- Sybil-distributed stakes still produce many lots, but each lot represents real economic exposure — the attacker pays gas to stake and risks the stake itself.
- Governance-controlled `compactLots(postId, side)` removes burned-out (zero-amount) lots via swap-and-pop, reducing snapshot gas on long-lived posts.
- Future: aggregation, partial settlement, or batching.

### F.2 High-fan-in claims make `effectiveVSRay` expensive
**Attack**
- Create many incoming evidence links to a claim to make every score read costly.

**Mitigations**
- Bounded fan-in: `maxIncomingEdges` (default 64) and `maxOutgoingLinks` (default 64) cap the work per `effectiveVSRay` call. Both are governance-configurable.
- Edges beyond the cap are silently skipped in insertion order.

---

## G. sMax Manipulation

### G.1 Pump-and-dump against sMax
**Attack**
- An attacker stakes massively on a post to push sMax up, then withdraws, hoping to leave smaller posts with a large sMax denominator and therefore low participation factors.

**Mitigations**
- The top-3 leader tracker snaps `sMax` to the new leader's total as soon as the attacker withdraws below the second-place post. There is no slow decay during normal operation; suppression ends with the attacker's exit transaction. A governance-configurable fallback exponential decay (currently 10% per epoch capped at 30 epochs) only runs if every post on the protocol unwinds completely, so even in that pathological case `sMax` cannot stay frozen forever.
- During the brief window when the attacker is still the leader, the new staker pays the cost of the inflated denominator. After the withdrawal the cost vanishes immediately.
- Governance can call `rescanSMax` to rebuild the tracker if state diverges from reality (e.g., after upgrades or extreme griefing).

### G.2 Link-spam against bounded fan-out
**Attack**
- An attacker creates many low-stake outgoing links from a credible parent claim, hoping that each link will earn a share of the parent's mass against the same denominator (or that links beyond the cap will silently steal influence without being summed in the denominator).

**Mitigations**
- ScoreEngine v2.1 enforces conservation of influence under the outgoing fan-out cap: only the parent's top-`maxOutgoingLinks` outgoing links by stake (with linkPostId-ascending tiebreak) participate in the distribution. Links outside that top-N contribute zero — they neither appear in the parent's denominator nor produce a numerator.
- As a result, link spam past the cap has zero economic effect: the attacker burns the posting fee plus any link stake, and gets no influence in return. To displace one of the top-N, an attacker must outstake the smallest existing top-N entry (or, in case of a tie, the one with the largest linkPostId).
- Within the cap, conservation of influence is preserved: the sum of `linkShare` across all top-N outgoing links is ≤ 1.0, so a parent's mass is fully and exclusively distributed among them.

---

## H. Relay Fee Collection (off-protocol, FeeCollector) <!-- patch_fee_collector -->

### H.1 A compromised relay key drains users' fee allowances
**Attack**
- The relay charges its gas-indexed fee in VSP after a user's gasless action confirms, drawing on a standing allowance the user signed (100 VSP). With the relay's own wallet as the spender, a stolen relay key could `transferFrom` the whole allowance of every user at once, and wallets showed the permission as a spending cap to an unverified plain address.

**Mitigations**
- `src/FeeCollector.sol` is the spender users permit. Only registered collectors (the relay wallets) can call `collect(user, amount, ref)`, and every call is bounded on chain: `maxFeePerCollect` (deployed at 5 VSP, the relay's own per-action cap) and `maxPerUserPerDay` (25 VSP per user per UTC day). A stolen key is limited to the daily cap per user, not the allowance.
- The Guardian Safe pauses collection instantly; only governance (the TimelockController, 48 h) unpauses, changes limits, the treasury or the collector set. Fees move straight from the user to the treasury; the contract never holds funds.
- `ref` (the relayed transaction hash) is indexed on `FeeCollected`, so every fee is attributable to the action it paid for.
- The relay's off-chain rule is unchanged: charge the lower of the quoted and the recomputed fee, never for a failed action. The contract only caps what the key can do; it does not price anything.
- Slither (gate baseline, reviewed 2026-10-20): `arbitrary-send-erc20` on `collect` is the design — the `from` is the user whose allowance and daily window bound the call, and only a registered collector can reach it; `timestamp`/`incorrect-equality` are the UTC-day bucket (`block.timestamp / 1 days`), where a validator's few-second skew can only move a day boundary, never the caps.
