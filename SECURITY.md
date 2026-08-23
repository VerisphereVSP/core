# Security Policy

Verisphere is pre-launch, unaudited software. We take security reports
seriously and would rather hear about a problem than not.

## Reporting a vulnerability

**Email: security@verisphere.co** — or, if you prefer GitHub, use the
repository's **Report a vulnerability** button (Security tab → Advisories),
which opens a private channel visible only to maintainers.

Please include:

- what the issue is and where (file/function/contract),
- how to reproduce it — a failing test, a transaction trace, or a script is
  ideal, but a clear written walkthrough is fine,
- what an attacker gains, and roughly how hard it is,
- your assessment of severity, if you have one.

Please **do not** open a public issue or PR for a security problem, and please
don't post it on social media before we've had a chance to respond.

## What you can expect from us

| Stage | Target |
|---|---|
| Acknowledgement that a human has read it | 3 business days |
| Initial assessment (confirmed / not reproduced / need more info) | 10 business days |
| Fix or documented mitigation for confirmed issues | as fast as the severity warrants — we'll tell you the plan |
| Public disclosure | coordinated with you, normally after a fix ships |

We will tell you honestly whether we agree with your severity rating and why.
If we disagree, we'll explain our reasoning rather than quietly downgrading it.
If we can't reproduce it, we'll say what we tried.

## Safe harbour

We will not pursue legal action against anyone who, in good faith:

- tests only against **testnet deployments** or their own local fork,
- does not access, modify, or exfiltrate other users' data or funds,
- does not degrade the service for others (no sustained load testing, no spam
  against the relay or public endpoints),
- gives us a reasonable opportunity to fix the issue before disclosing it.

If you're unsure whether something is in scope, ask first — that also counts
as good faith.

## Scope

Upgradeability, so you know what you are testing: the core protocol contracts
(StakeEngine, ScoreEngine, PostRegistry, LinkGraph, ProtocolViews) are
UUPS-upgradeable via GovernedUpgradeable, authorized through Authority, with
upgrades running through script/Upgrade.s.sol and the storage-layout check.
VSPToken and Authority themselves are not proxied.
<!-- patch_pushunblock_proxyline: added 2026-08-21; the pre-rewrite doc
     falsely claimed "No upgradeable proxies in MVP". -->

**In scope**
- Protocol contracts in `VeriSphereVSP/core` (`src/`) — token, registry,
  staking, scoring, governance, and the deployment scripts under `script/`.
- The application backend in `VeriSphereVSP/app` — the API, relay/forwarder
  path, content moderation, indexer, and rate limiting.
- The frontend in `VeriSphereVSP/frontend` and the Verity browser extension.

**Out of scope**
- `src/mock/` and anything documented as rehearsal-only infrastructure.
- Issues that require compromising a user's own device, wallet, or browser.
- Findings from automated scanners without a demonstrated impact.
- The economics of losing a stake: staking against a claim that later loses is
  the protocol working as designed, not a vulnerability.
- Third-party services (RPC providers, AMM venues, the chain itself).

## Known and accepted

- **The contracts are unaudited.** This is disclosed to users and is not itself
  a finding. Reports of specific exploitable bugs in unaudited code are very
  much welcome.
- **Governance is currently a single key** on testnet. Findings that assume a
  compromised governance key are understood; findings that let a non-governance
  actor reach governance-only behaviour are in scope and serious.

## Rewards

We do not currently run a paid bug bounty; the project is pre-revenue and we'd
rather promise nothing than promise what we can't pay. What we do offer:
public credit in the advisory and this repository (or anonymity, your choice),
and a direct line to the maintainers. If a report prevents material loss, we
will discuss a discretionary reward case by case.

## Disclosure history

| ID | Date | Summary | Status |
|---|---|---|---|
| VSP-SEC-001 | 2026-08-19 | Mid-window accrual asymmetry in `StakeEngine`: settlement scales rewards by elapsed epochs and applies them to the lot set present at settlement, so with `snapshotPeriod > EPOCH_LENGTH` a late joiner could capture a full window's rewards (and an early leaver could dodge a full window's decay). Not reachable at the deployed 1-day period. Reported by [@ibnu76](https://github.com/ibnu76). | Fixed — `MAX_SNAPSHOT_PERIOD` capped to `EPOCH_LENGTH`; regression tests added |
