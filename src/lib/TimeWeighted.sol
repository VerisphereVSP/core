// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/math/Math.sol";

/// @title TimeWeighted — per-post observations and window averages (whitepaper v17 §4.2.5)
/// @notice External library (deployed once, delegate-called) so the StakeEngine stays under the
///         EIP-170 runtime size limit. One observation per stake change: the side totals at `ts`
///         and the running integrals ∫A dt, ∫D dt up to `ts`. The time-weighted totals over any
///         window are (cum(t1) − cum(t0)) / (t1 − t0), with cum(t) extrapolated from the last
///         observation at or before t.
library TimeWeighted {
    struct Observation {
        uint64 ts;
        uint96 support;
        uint96 challenge;
        uint256 cumSupport;
        uint256 cumChallenge;
    }

    /// @dev Record the current totals at block.timestamp (same-second updates overwrite).
    /// @dev review R3 H-1: the packed fields are uint96; totals above 2^96 - 1 (~7.9e28 wei, ~79x the
    ///      supply cap) revert instead of truncating silently.
    error Fits96();

    function _fits96(uint256 x) internal pure returns (uint96) {
        if (x > type(uint96).max) {
            revert Fits96();
        }
        return uint96(x);
    }

    function observe(Observation[] storage obs, uint256 A, uint256 D) external {
        _fits96(A);
        _fits96(D);
        uint256 n = obs.length;
        if (n == 0) {
            obs.push(Observation(uint64(block.timestamp), uint96(A), uint96(D), 0, 0));
            return;
        }
        Observation storage last = obs[n - 1];
        if (last.ts == block.timestamp) {
            last.support = uint96(A);
            last.challenge = uint96(D);
            return;
        }
        uint256 dt = block.timestamp - last.ts;
        obs.push(
            Observation(
                uint64(block.timestamp),
                uint96(A),
                uint96(D),
                last.cumSupport + uint256(last.support) * dt,
                last.cumChallenge + uint256(last.challenge) * dt
            )
        );
    }

    /// @dev Seed the first observation at an earlier timestamp (legacy posts at their window start).
    function seed(Observation[] storage obs, uint256 ts, uint256 A, uint256 D) external {
        if (obs.length == 0) {
            obs.push(Observation(uint64(ts), uint96(A), uint96(D), 0, 0));
        }
    }

    /// @dev Time-weighted side totals over [t0, t1]; live totals when the window is empty or the
    ///      post has no observations yet.
    function totals(Observation[] storage obs, uint256 t0, uint256 t1, uint256 liveA, uint256 liveD)
        external
        view
        returns (uint256 support, uint256 challenge)
    {
        if (t1 <= t0 || obs.length == 0) {
            return (liveA, liveD);
        }
        (uint256 a1, uint256 d1) = _cumAt(obs, t1);
        (uint256 a0, uint256 d0) = _cumAt(obs, t0);
        uint256 span = t1 - t0;
        return ((a1 - a0) / span, (d1 - d0) / span);
    }

    /// @dev whitepaper §3.2: rBase for one settlement. verity from the effective pool (S, C),
    ///      participation from the post's direct T against sMax (clamped to 1), annual bounds
    ///      scaled to the elapsed epochs. External pure: bytes live here, not in StakeEngine.
    function rBase(
        uint256 S,
        uint256 C,
        uint256 T,
        uint256 sMax,
        uint256 rMinAnnualRay,
        uint256 rMaxAnnualRay,
        uint256 epochLength,
        uint256 epochsElapsed,
        uint256 yearLength
    ) external pure returns (uint256) {
        uint256 RAY = 1e18;
        uint256 absVS = S > C ? S - C : C - S;
        uint256 vRay = (absVS * RAY) / (S + C);
        uint256 participationRay = (T * RAY) / sMax;
        if (participationRay > RAY) {
            participationRay = RAY;
        }
        uint256 rMin = (rMinAnnualRay * epochLength * epochsElapsed) / yearLength;
        uint256 rMax = (rMaxAnnualRay * epochLength * epochsElapsed) / yearLength;
        return rMin + ((rMax - rMin) * vRay * participationRay) / (RAY * RAY);
    }

    /// @dev whitepaper §3.2: one lot's settlement delta — amount × rBase × midpoint weight, prorated by
    ///      the share of [wStart, wEnd) the lot was present for (et = amount-weighted entry time; 0 or
    ///      wEnd == 0 means no proration). Shared by settlement and projection (spec V.8).
    function lotDelta(
        uint256 amount,
        uint256 weightedPosition,
        uint256 sideTotal,
        uint256 rBase,
        uint256 et,
        uint256 wStart,
        uint256 wEnd
    ) external pure returns (uint256 delta) {
        uint256 RAY = 1e18;
        uint256 behind = weightedPosition < sideTotal ? sideTotal - weightedPosition : 0;
        uint256 midpointRate = (behind * RAY) / sideTotal;
        if (midpointRate > RAY) {
            midpointRate = RAY;
        }
        delta = Math.mulDiv(amount * rBase, midpointRate, RAY * RAY);
        if (wEnd > wStart && et > wStart) {
            uint256 present = et < wEnd ? wEnd - et : 0;
            delta = Math.mulDiv(delta, present, wEnd - wStart);
        }
    }

    /// @dev The pooled tail bucket's index after one settlement: the bucket sits at the tail midpoint,
    ///      its rate is prorated by presence like a lot (review R3 F-B), and the index floors at 1 wei
    ///      (S-01). Shared by settlement and projection.
    function bucketIndexAfter(
        uint256 ix,
        uint256 live,
        uint256 sideTotal,
        uint256 rBase,
        bool aligned,
        uint256 et,
        uint256 wStart,
        uint256 wEnd
    ) external pure returns (uint256 newIx) {
        uint256 RAY = 1e18;
        uint256 wPosB = (sideTotal - live) + live / 2;
        uint256 behind = wPosB < sideTotal ? sideTotal - wPosB : 0;
        uint256 gRay = (rBase * behind) / sideTotal;
        if (wEnd > wStart && et > wStart) {
            uint256 present = et < wEnd ? wEnd - et : 0;
            gRay = Math.mulDiv(gRay, present, wEnd - wStart);
        }
        if (aligned) {
            newIx = (ix * (RAY + gRay)) / RAY;
        } else {
            newIx = gRay >= RAY ? 0 : (ix * (RAY - gRay)) / RAY;
        }
        if (newIx == 0) {
            newIx = 1;
        }
    }

    // ── sMax tracker (moved out of StakeEngine for EIP-170; patch_settlement_snapshots) ──────────

    struct TopPost {
        uint256 postId;
        uint256 total;
    }

    /// @dev Insert/update `postId` with `postTotal` in the 10-slot descending tracker, dropping it
    ///      when the total is 0, and return the leader. Same algorithm as StakeEngine._updateSMax
    ///      had (S-03 layer iii).
    function trackerUpdate(TopPost[10] storage topPosts, uint256 postId, uint256 postTotal)
        external
        returns (uint256 leaderTotal, uint256 leaderId)
    {
        uint256 n = 10;
        uint256 slot = type(uint256).max;
        for (uint256 i = 0; i < n; i++) {
            if (topPosts[i].postId == postId && topPosts[i].total > 0) {
                slot = i;
                break;
            }
        }
        if (slot != type(uint256).max) {
            topPosts[slot].total = postTotal;
            while (slot > 0 && topPosts[slot].total > topPosts[slot - 1].total) {
                TopPost memory tmp = topPosts[slot];
                topPosts[slot] = topPosts[slot - 1];
                topPosts[slot - 1] = tmp;
                slot--;
            }
            while (slot < n - 1 && topPosts[slot].total < topPosts[slot + 1].total) {
                TopPost memory tmp = topPosts[slot];
                topPosts[slot] = topPosts[slot + 1];
                topPosts[slot + 1] = tmp;
                slot++;
            }
        } else {
            for (uint256 i = 0; i < n; i++) {
                if (postTotal > topPosts[i].total) {
                    for (uint256 j = n - 1; j > i; j--) {
                        topPosts[j] = topPosts[j - 1];
                    }
                    topPosts[i] = TopPost(postId, postTotal);
                    break;
                }
            }
        }
        for (uint256 i = 0; i < n; i++) {
            if (topPosts[i].total == 0) {
                topPosts[i] = TopPost(0, 0);
            }
        }
        return (topPosts[0].total, topPosts[0].postId);
    }

    /// @dev sMax after `elapsed` epochs of exponential decay (elapsed already capped by the caller).
    function decay(uint256 sMax, uint256 rateRay, uint256 elapsed) external pure returns (uint256 decayed) {
        decayed = sMax;
        for (uint256 i = 0; i < elapsed; i++) {
            decayed = (decayed * rateRay) / 1e18;
            if (decayed == 0) {
                break;
            }
        }
    }

    /// @dev The sMax a settlement of a post with direct total T would divide by right now: the tracker
    ///      registers T first (so the leader is at least T), then either rises to the leader or decays
    ///      toward it — exactly StakeEngine._updateSMax, read-only (spec V.8: view == materialised).
    function projectSMax(uint256 sMax, uint256 leader, uint256 T, uint256 rateRay, uint256 elapsedCapped)
        external
        pure
        returns (uint256)
    {
        if (T > leader) {
            leader = T;
        }
        if (leader >= sMax) {
            return leader;
        }
        uint256 decayed = sMax;
        for (uint256 i = 0; i < elapsedCapped; i++) {
            decayed = (decayed * rateRay) / 1e18;
            if (decayed == 0) {
                break;
            }
        }
        return decayed < leader ? leader : decayed;
    }

    /// @dev cum(t): integral of the side totals from the first observation to t.
    function _cumAt(Observation[] storage obs, uint256 t) internal view returns (uint256 cumA, uint256 cumD) {
        if (t < obs[0].ts) {
            return (0, 0); // before the post existed
        }
        uint256 lo = 0;
        uint256 hi = obs.length - 1;
        while (lo < hi) {
            uint256 mid = (lo + hi + 1) / 2;
            if (obs[mid].ts <= t) {
                lo = mid;
            } else {
                hi = mid - 1;
            }
        }
        Observation storage o = obs[lo];
        uint256 dt = t - o.ts;
        return (o.cumSupport + uint256(o.support) * dt, o.cumChallenge + uint256(o.challenge) * dt);
    }
}
