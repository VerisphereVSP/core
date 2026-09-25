// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

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
    function observe(Observation[] storage obs, uint256 A, uint256 D) external {
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
