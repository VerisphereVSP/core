// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/governance/TimelockController.sol";
// patch_oneshot_genesis: audited linear lock for the genesis treasury tranche
import "@openzeppelin/contracts/finance/VestingWallet.sol";

import "../src/authority/Authority.sol";
import "../src/VSPToken.sol";
import "../src/PostRegistry.sol";
import "../src/LinkGraph.sol";
import "../src/StakeEngine.sol";
import "../src/ScoreEngine.sol";
import "../src/ProtocolViews.sol";

import "../src/governance/ProtocolPolicy.sol";

/// @title Deploy
/// @notice Deploys the full VeriSphere protocol.
///         Environment-aware: if PRODUCTION=true, deploys a TimelockController
///         and initiates two-step ownership transfer from deployer to timelock.
///         Otherwise, deployer EOA retains ownership for fast iteration.
contract Deploy is Script {
    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);
        bool isProduction = vm.envOr("PRODUCTION", false);

        vm.startBroadcast(pk);

        // In dev, gov = deployer. In prod, gov = TimelockController (deployed below).
        address gov = deployer;

        Authority authority = new Authority(gov);

        // Forwarder is deployed separately (see app/contracts/VerisphereForwarder.sol).
        // Pass its address via FORWARDER_ADDRESS env var.
        // Use address(0) if no forwarder is needed (direct wallet interaction only).
        address forwarder = vm.envOr("FORWARDER_ADDRESS", address(0));

        // Deploy TimelockController for policy contracts (and Authority in prod).
        //
        // PROD: proposer/executor = the Ops Safe (required SAFE_ADDRESS), admin = 0.
        //   The Safe is the ONLY actor that can schedule or execute timelock ops, and
        //   the timelock is self-administered (admin=0) — its own config can only be
        //   changed via the Safe→schedule→delay→execute path. No deployer backdoor,
        //   no "renounce later" straggler. Losing the Safe (2-of-3) bricks governance
        //   by design; that risk is mitigated by signer seed backups, not by an admin.
        // DEV: proposer/executor/admin = deployer, minDelay 0, for fast iteration.
        //
        // NOTE: this deploy performs NO governance handoff. Every contract is left
        //   deployer-owned. The handoff (deployer proposes -> Safe accepts via the
        //   timelock) is a separate, gated, Safe-driven step: tools/vsp-governance-handoff.sh.
        address timelockController = deployer; // dev: deployer is proposer/executor/admin
        if (isProduction) {
            timelockController = vm.envAddress("SAFE_ADDRESS"); // reverts if unset in prod
            require(timelockController != address(0), "Deploy: SAFE_ADDRESS required when PRODUCTION=true");
        }
        address[] memory proposers = new address[](1);
        proposers[0] = timelockController;
        address[] memory executors = new address[](1);
        executors[0] = timelockController;

        // Prod Timelock minDelay: default 2 days, overridable via TIMELOCK_MIN_DELAY_SECONDS
        // (e.g. 120 for a fast Fuji rehearsal). HARD FLOOR on mainnet: chain 43114 can never
        // go below 2 days regardless of the override — a rehearsal-speed delay must never
        // reach production. Dev (non-prod) is always 0 for fast iteration.
        uint256 prodDelay = vm.envOr("TIMELOCK_MIN_DELAY_SECONDS", uint256(2 days));
        require(block.chainid != 43114 || prodDelay >= 2 days, "Deploy: mainnet Timelock minDelay floor is 2 days");
        uint256 minDelay = isProduction ? prodDelay : 0;

        TimelockController timelock = new TimelockController(
            minDelay, // prod: TIMELOCK_MIN_DELAY_SECONDS (default 2 days, mainnet floor 2 days); dev: 0
            proposers, // prod: [Safe]; dev: [deployer]
            executors, // prod: [Safe]; dev: [deployer]
            isProduction ? address(0) : deployer // prod: self-administered (no admin); dev: deployer
        );

        // Bundled policy: stake rates + posting fee + claim activity threshold.
        // Constructor: (timelock, rateMinRay, rateMaxRay, postingFee, minTotalStakeVSP)
        ProtocolPolicy protocolPolicy = new ProtocolPolicy(
            address(timelock),
            0, // rateMin: 0% APR floor
            693805319167998976, // rateMax: 100% max APY (1->2 VSP) daily-compounded ~ln2
            1e18, // postingFee: 1 VSP (within [1e15, 100e18])
            1e18 // minTotalStake: 1 VSP (within [0, 10000e18])
        );

        // patch_stakeengine_exempt_precompute: single-pass wiring of VSPToken's cap-exemption
        // target = the StakeEngine proxy, precomputed by nonce offset from this getNonce().
        // patch_oneshot_genesis (2026-07-29): offset is +3 — the treasury-worker
        // minter/burner grants that sat between the token proxy and the StakeEngine
        // deploy are REMOVED (worker decommissioned with the public-AMM pivot; no
        // standing non-protocol minter exists under the one-shot supply model).
        // Full nonce accounting from this getNonce():
        //   +0 VSPToken impl (CREATE)     +1 token proxy (CREATE)
        //   +2 StakeEngine impl (CREATE)  +3 StakeEngine proxy (CREATE)  <- exemption target
        // The require() after the StakeEngine deploy still fails loud if this ever drifts.
        address predictedStakeProxy = vm.computeCreateAddress(deployer, vm.getNonce(deployer) + 3);
        VSPToken tokenImpl = new VSPToken(
            // patch_bundle10_5_part1_fixup_doc_sync_sol: DO NOT CHANGE the address(0) below.
            // VSPToken MUST NOT trust any ERC-2771 forwarder. The Forwarder
            // calls vspToken.safeTransferFrom(user, treasury, fee) directly in
            // _collectFee — a plain ERC20 call, NOT a meta-tx with an appended
            // user address. If trustedForwarder != 0x0, VSPToken's ERC2771
            // _msgSender() pulls the trailing 20 bytes of calldata as the
            // spender (garbage, since this is a plain transferFrom), the
            // allowance check fails, and EVERY meta-tx through the Forwarder
            // reverts at ~77K gas. Confirmed on Fuji 2026-05-29 (Bundle 10.5
            // Part 1 fixup ceremony — see THREAT-MODEL §4.6 F11/G-47).
            // The post-deploy require() below enforces this at deploy time.
            address(0),
            // patch_oneshot_genesis: defaults changed for the one-shot supply model.
            // INCEPTION_SUPPLY defaults to the full genesis supply and GROWTH_BASE
            // defaults to 1e18 (1x/yr = FLAT cap): after the genesis mint fills the
            // curve exactly, capped minters have ZERO headroom forever — even a
            // wrongly-granted future minter cannot mint. StakeEngine (exempt) is
            // the only address that can move supply, per protocol staking mechanics.
            vm.envOr("VSP_INCEPTION_TIMESTAMP", uint256(1778544000)),
            vm.envOr("VSP_INCEPTION_SUPPLY", uint256(1_000_002_000 * 1e18)),
            vm.envOr("VSP_GROWTH_BASE_PER_YEAR", uint256(1e18)),
            predictedStakeProxy // patch_bundle10_5_part2a_stakeengine_exempt
        ); // patch_bundle10_5_part2a_timecap: 4-arg constructor
        ERC1967Proxy tokenProxy =
            new ERC1967Proxy(address(tokenImpl), abi.encodeCall(VSPToken.initialize, (address(authority))));
        VSPToken token = VSPToken(address(tokenProxy));

        // patch_bundle10_5_part1_fixup_doc_sync_sol: deploy-time tripwire for the bug fixed on Fuji 2026-05-29.
        // If a future change to the constructor arg above ever sets a non-zero
        // forwarder, the deploy itself reverts here. See THREAT-MODEL §4.6 F11/G-47.
        require(token.trustedForwarder() == address(0), "Deploy: VSPToken must not trust any forwarder");

        // patch_oneshot_genesis: the treasury-worker minter/burner grants are REMOVED.
        // Under the one-shot supply model there is no standing non-protocol minter:
        // the entire tradable/treasury supply is minted once, below, inside this
        // deploy (while the deployer still holds the Authority-constructor auto-grant,
        // revoked at the end of this script). MM_TREASURY_WORKER_ADDRESS is no longer
        // read; fundmm.sh / fund-prelaunch.sh remain non-functional by design.

        // Implementation contracts take forwarder in constructor (OZ 5.5 immutable pattern)
        StakeEngine stakeImpl = new StakeEngine(forwarder);
        ERC1967Proxy stakeProxy = new ERC1967Proxy(
            address(stakeImpl), abi.encodeCall(StakeEngine.initialize, (gov, address(token), address(protocolPolicy)))
        );
        StakeEngine stake = StakeEngine(address(stakeProxy));
        // patch_prC_rulings S-09: the decay backstop is 10%/day (9e17) BY DESIGN;
        // the old docstring claiming 0.5%/day was the bug. Set it explicitly when
        // the deployer holds governance (dev path), and pin it unconditionally so
        // any drift fails the deploy loudly on every path.
        if (stake.governance() == deployer) {
            stake.setSMaxDecayRate(9e17);
        }
        require(stake.sMaxDecayRateRay() == 9e17, "Deploy: sMaxDecayRateRay != 9e17 (10%/day, S-09)");
        // patch_stakeengine_exempt_precompute: fail loud if the nonce offset above ever drifts,
        // rather than silently deploying VSPToken with a wrong exemption target.
        require(
            address(stake) == predictedStakeProxy,
            "Deploy: StakeEngine proxy != precomputed VSPToken exemption target (nonce offset drift)"
        );

        authority.setMinter(address(stake), true);
        authority.setBurner(address(stake), true);

        PostRegistry registryImpl = new PostRegistry(forwarder);
        ERC1967Proxy registryProxy = new ERC1967Proxy(
            address(registryImpl),
            abi.encodeCall(PostRegistry.initialize, (gov, address(token), address(protocolPolicy)))
        );
        PostRegistry registry = PostRegistry(address(registryProxy));

        // PostRegistry needs burner role to burn posting fees
        authority.setBurner(address(registry), true);

        LinkGraph graphImpl = new LinkGraph(forwarder);
        ERC1967Proxy graphProxy = new ERC1967Proxy(address(graphImpl), abi.encodeCall(LinkGraph.initialize, (gov)));
        LinkGraph graph = LinkGraph(address(graphProxy));

        graph.setRegistry(address(registry));
        registry.setLinkGraph(address(graph));

        ScoreEngine scoreImpl = new ScoreEngine(forwarder);
        ERC1967Proxy scoreProxy = new ERC1967Proxy(
            address(scoreImpl),
            abi.encodeCall(
                ScoreEngine.initialize,
                (
                    gov,
                    address(registry),
                    address(stake),
                    address(graph),
                    address(protocolPolicy),
                    address(0) // reserved (was activityPolicy pre-Patch-17)
                )
            )
        );
        ScoreEngine score = ScoreEngine(address(scoreProxy));

        ProtocolViews viewsImpl = new ProtocolViews(forwarder);
        ERC1967Proxy viewsProxy = new ERC1967Proxy(
            address(viewsImpl),
            abi.encodeCall(
                ProtocolViews.initialize,
                (gov, address(registry), address(stake), address(graph), address(score), address(protocolPolicy))
            )
        );

        // ── patch_oneshot_genesis: ONE-SHOT GENESIS MINT + LOCK ──
        // The full supply is minted here, once, split liquid/locked:
        //   liquid  -> GENESIS_TREASURY (LP seed + board-authorized ops/grants)
        //   locked  -> OZ VestingWallet (linear release to GENESIS_TREASURY)
        // The deployer can mint ONLY inside this script (Authority constructor
        // auto-grant, revoked at the end). Liquid+locked must equal
        // VSP_INCEPTION_SUPPLY so the flat cap is filled exactly: any later
        // capped mint of even 1 wei reverts MintExceedsTimeWindowCap.
        address genesisTreasury = vm.envOr("VSP_GENESIS_TREASURY", deployer);
        uint256 genesisLiquid = vm.envOr("VSP_GENESIS_LIQUID_SUPPLY", uint256(100_002_000 * 1e18));
        uint256 genesisLocked = vm.envOr("VSP_GENESIS_LOCKED_SUPPLY", uint256(900_000_000 * 1e18));
        require(
            genesisLiquid + genesisLocked == token.INCEPTION_SUPPLY(),
            "Deploy: genesis liquid+locked must equal VSP_INCEPTION_SUPPLY (fill the flat cap exactly)"
        );
        uint64 vestStart = uint64(vm.envOr("VSP_VESTING_START_TS", uint256(token.INCEPTION_TIMESTAMP())));
        uint64 vestDuration = uint64(vm.envOr("VSP_VESTING_DURATION_SECONDS", uint256(4 * 365 days)));
        VestingWallet vestingWallet = new VestingWallet(genesisTreasury, vestStart, vestDuration);
        token.mint(genesisTreasury, genesisLiquid);
        token.mint(address(vestingWallet), genesisLocked);
        require(token.totalSupply() == token.INCEPTION_SUPPLY(), "Deploy: genesis mint != inception supply");
        console.log("GENESIS: total supply (wei):", token.totalSupply());
        console.log("GENESIS: liquid -> treasury:", genesisTreasury);
        console.log("GENESIS: locked -> VestingWallet:", address(vestingWallet));
        console.log("GENESIS: vesting start / duration (s):", vestStart, vestDuration);

        vm.label(address(registry), "PostRegistry");
        vm.label(address(graph), "LinkGraph");
        vm.label(address(stake), "StakeEngine");
        vm.label(address(score), "ScoreEngine");
        vm.label(address(viewsProxy), "ProtocolViews");

        // ── Production: NO handoff here (deliberate) ──
        // Deploy leaves ALL contracts deployer-owned. Governance handoff to the
        // timelock is a SEPARATE, gated, Safe-driven step (tools/vsp-governance-handoff.sh):
        // deployer proposes on each consumer + Authority; the Ops Safe then schedules
        // and executes the accept* batch through this timelock. The Forwarder goes to
        // the Safe directly (fast rescue). Keeping deploy and handoff separate makes the
        // single most dangerous step reviewable, gateable, and rehearsable on its own.
        if (isProduction) {
            console.log("");
            console.log("PRODUCTION MODE: deployed. ALL contracts are deployer-owned.");
            console.log("TimelockController (proposer/executor = Ops Safe, admin = 0):", address(timelock));
            console.log("Ops Safe:", timelockController);
            console.log("");
            console.log("NO governance handoff was performed by this deploy (by design).");
            console.log("NEXT: run tools/vsp-preceremony-probe.sh, then tools/vsp-governance-handoff.sh.");
        }

        // patch_worker_minter_revoke: Authority's constructor auto-grants its owner (the
        // deployer) mint+burn (Authority.sol:32-33). The deploy itself never mints/burns, and
        // no human EOA should be a standing minter — so revoke the deployer here, at the end of
        // setup. Leaves the minter set as exactly {StakeEngine (gain-mints), treasury worker
        // (MM liquidity)}. Dev and prod identical. acceptOwner() does NOT re-grant, so the
        // governance handoff stays clean. After the StakeEngine proxy, so the +5 exemption
        // precompute is unaffected.
        authority.setMinter(deployer, false);
        authority.setBurner(deployer, false);

        vm.stopBroadcast();

        string memory json = string.concat(
            '{"Authority":"',
            vm.toString(address(authority)),
            '","TimelockController":"',
            vm.toString(address(timelock)),
            '","VSPToken":"',
            vm.toString(address(token)),
            '","PostRegistry":"',
            vm.toString(address(registry)),
            '","LinkGraph":"',
            vm.toString(address(graph)),
            '","StakeEngine":"',
            vm.toString(address(stake)),
            '","ScoreEngine":"',
            vm.toString(address(score)),
            '","ProtocolViews":"',
            vm.toString(address(viewsProxy)),
            '","ProtocolPolicy":"',
            vm.toString(address(protocolPolicy)),
            '","VestingWallet":"',
            vm.toString(address(vestingWallet)),
            '"}'
        );

        vm.writeFile(string.concat("broadcast/Deploy.s.sol/", vm.toString(block.chainid), "/addresses.json"), json);
    }
}
