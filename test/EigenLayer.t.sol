// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ParityTest} from "./Base.t.sol";
import {ReputationLedger} from "../src/ReputationLedger.sol";
import {ParityCrossPoolOracle} from "../src/eigenlayer/ParityCrossPoolOracle.sol";
import {IECDSAStakeRegistry} from "../src/eigenlayer/IECDSAStakeRegistry.sol";
import {MockStakeRegistry} from "./mocks/MockStakeRegistry.sol";

/// @notice EigenLayer AVS consumer integration (doc §6 partner row, §9 roadmap item 1):
///         operators of the Parity AVS co-sign cross-pool reputation attestations; the
///         consumer verifies them against the stake registry and the hook seeds fresh
///         addresses' scores once — local history always wins afterwards.
contract EigenLayerAvsTest is ParityTest {
    MockStakeRegistry registry;
    ParityCrossPoolOracle oracle;

    uint256 internal pkA;
    uint256 internal pkB;
    uint256 internal pkC;

    uint256 internal constant FRESHNESS = 50;

    function setUp() public {
        _deployParity();
        _createPoolAndSeedLiquidity(100e18);

        registry = new MockStakeRegistry();
        oracle = new ParityCrossPoolOracle(IECDSAStakeRegistry(address(registry)), FRESHNESS, address(this));
        hook.setCrossPoolOracle(oracle);

        // Three operators at 40/30/30% weight; mock quorum threshold 6667 bps requires
        // any two of them to sign.
        (pkA, pkB, pkC) = (0xA11CE, 0xB0B, 0xC0DE);
        registry.setOperator(vm.addr(pkA), vm.addr(pkA), 40e18);
        registry.setOperator(vm.addr(pkB), vm.addr(pkB), 30e18);
        registry.setOperator(vm.addr(pkC), vm.addr(pkC), 30e18);
    }

    /// @dev Signs `score` for `subject` with every operator key and submits the attestation
    ///      with operators in strictly ascending order, exactly as an operator network's
    ///      response relay would.
    function _attest(address subject, int256 score) internal {
        bytes32 domain = oracle.attestationDomain();
        uint256 nonce = oracle.nextNonce();
        bytes32 digest = keccak256(
            abi.encode(domain, block.chainid, address(oracle), subject, score, uint32(block.number), nonce)
        );

        uint256[] memory keys = keys3(pkA, pkB, pkC);

        address[] memory ops = new address[](keys.length);
        bytes[] memory sigs = new bytes[](keys.length);
        for (uint256 i; i < keys.length; ++i) {
            ops[i] = vm.addr(keys[i]);
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(keys[i], digest);
            sigs[i] = abi.encodePacked(r, s, v);
        }
        _sortPairs(ops, sigs);

        oracle.attestReputation(subject, score, uint32(block.number), nonce, ops, sigs);
    }

    function keys3(uint256 a, uint256 b, uint256 c) internal pure returns (uint256[] memory k) {
        k = new uint256[](3);
        (k[0], k[1], k[2]) = (a, b, c);
    }


    /// @dev Bubble-sorts operators ascending together with their signatures (the real
    ///      StakeRegistry reverts on unsorted signer lists).
    function _sortPairs(address[] memory ops, bytes[] memory sigs) internal pure {
        for (uint256 i; i < ops.length; ++i) {
            for (uint256 j = i + 1; j < ops.length; ++j) {
                if (ops[j] < ops[i]) {
                    (ops[i], ops[j]) = (ops[j], ops[i]);
                    (sigs[i], sigs[j]) = (sigs[j], sigs[i]);
                }
            }
        }
    }

    // ------------------------------------------------------------------
    // Seeding end-to-end: attestation -> treatment
    // ------------------------------------------------------------------

    /// @notice A quorum-attested Trusted address gets Trusted treatment from its very first
    ///     swap: the hook pulls the attested score into the ledger at beforeSwap, so a
    ///     second same-block swap succeeds — only Trusted flow bypasses the delay gate.
    function test_attested_cross_pool_score_grants_trusted_treatment() public {
        address alice = _makeSwapper(11);
        assertFalse(ledger.hasHistory(alice));
        assertEq(uint8(ledger.tierOf(alice)), uint8(ReputationLedger.Tier.Neutral));

        _attest(alice, 1000);

        _swap(alice, true, 0.05e18); // first swap: hook seeds 1000 from the oracle
        assertGt(ledger.scoreOf(alice), 700, "seeded score should carry into local state");
        _swap(alice, true, 0.05e18); // same block: Neutral flow would hit the delay gate
    }

    /// @notice Attestations expire: past the freshness window the seed no longer applies and
    ///     the address falls back to Neutral treatment (delay enforced between same-block swaps).
    function test_stale_attestation_is_ignored() public {
        address bob = _makeSwapper(12);
        _attest(bob, 900);
        (bool fresh,) = oracle.freshScore(bob);
        assertTrue(fresh, "attestation should be fresh immediately");

        vm.roll(block.number + FRESHNESS + 1);
        (fresh,) = oracle.freshScore(bob);
        assertFalse(fresh, "stale attestation must not be usable");

        _swap(bob, true, 1e18); // first swap as Neutral: allowed, records lastSwapBlock
        uint64 lastBlock = ledger.lastSwapBlock(bob);
        assertTrue(lastBlock != 0);
        _swapExpectingDelay(bob, 1e18, uint64(lastBlock + 1));
    }

    /// @notice Local history wins: once an address has been observed locally, the seed path
    ///     refuses to overwrite it with imported reputation. The oracle itself cannot even
    ///     reach the ledger — the hook (ledger authority) is the sole entry point.
    function test_local_history_cannot_be_overwritten_by_seed() public {
        address carol = _makeSwapper(13);
        _swap(carol, true, 1e18);
        int256 localScore = ledger.scoreOf(carol);

        // The oracle itself accepts the attestation…
        _attest(carol, 900);
        (int256 stored,) = oracle.latestAttestation(carol);
        assertEq(stored, 900);

        // …but the oracle has no direct ledger access.
        vm.prank(address(oracle));
        vm.expectRevert(ReputationLedger.Unauthorized.selector);
        ledger.seedExternalScore(carol, 900);

        // The hook (authority) is refused over observed history.
        vm.prank(address(hook));
        vm.expectRevert(ReputationLedger.AlreadyScoredLocally.selector);
        ledger.seedExternalScore(carol, 900);

        assertEq(ledger.scoreOf(carol), localScore);
    }

    // ------------------------------------------------------------------
    // Quorum & governance guards
    // ------------------------------------------------------------------

    /// @notice Signatures below the stake-weighted threshold are rejected by the registry,
    ///     so a lone minority operator cannot mint anyone Trusted treatment.
    function test_insufficient_quorum_reverts() public {
        address dave = _makeSwapper(14);

        uint256 nonce = oracle.nextNonce();
        bytes32 digest = keccak256(
            abi.encode(oracle.attestationDomain(), block.chainid, address(oracle), dave, 900, uint32(block.number), nonce)
        );
        address[] memory ops = new address[](1);
        bytes[] memory sigs = new bytes[](1);
        ops[0] = vm.addr(pkA); // 40% < 66.67% threshold
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pkA, digest);
        sigs[0] = abi.encodePacked(r, s, v);

        vm.expectRevert(MockStakeRegistry.InsufficientSignedStake.selector);
        oracle.attestReputation(dave, 900, uint32(block.number), nonce, ops, sigs);
    }

    /// @notice Re-delivering a previously-valid attestation reverts: the message is bound to a
    ///     nonce the contract has already consumed, so nobody can refresh a stale score's
    ///     freshness timestamp or replay an old message to overwrite a newer attestation.
    function test_replayed_attestation_is_rejected() public {
        address frank = _makeSwapper(16);

        // Capture a validly signed message before submission…
        bytes32 domain = oracle.attestationDomain();
        uint256 nonce = oracle.nextNonce();
        bytes32 digest = keccak256(
            abi.encode(domain, block.chainid, address(oracle), frank, 900, uint32(block.number), nonce)
        );

        uint256[] memory keys = keys3(pkA, pkB, pkC);
        address[] memory ops = new address[](keys.length);
        bytes[] memory sigs = new bytes[](keys.length);
        for (uint256 i; i < keys.length; ++i) {
            ops[i] = vm.addr(keys[i]);
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(keys[i], digest);
            sigs[i] = abi.encodePacked(r, s, v);
        }
        _sortPairs(ops, sigs);

        // …submit it once (accepted)…
        oracle.attestReputation(frank, 900, uint32(block.number), nonce, ops, sigs);

        // …then attempt the replay: the nonce has advanced, so the message is dead.
        vm.expectRevert(ParityCrossPoolOracle.InvalidNonce.selector);
        oracle.attestReputation(frank, 900, uint32(block.number), nonce, ops, sigs);

        // A fresh message must use the new nonce.
        (bool fresh, int256 score) = oracle.freshScore(frank);
        assertTrue(fresh, "original attestation survives the failed replay");
        assertEq(score, 900);
    }

    /// @notice The seed path is authority-gated and score-bounds-checked, and the oracle
    ///     wiring on the hook is owner-gated.
    function test_seeding_governance_guards() public {
        address erin = _makeSwapper(15);

        // Only the hook may call into the ledger's seeding path.
        vm.prank(address(this));
        vm.expectRevert(ReputationLedger.Unauthorized.selector);
        ledger.seedExternalScore(erin, 900);

        // Score bounds are enforced on the seed path.
        vm.prank(address(hook));
        vm.expectRevert(ReputationLedger.InvalidScoreBounds.selector);
        ledger.seedExternalScore(erin, 1001);

        vm.prank(_makeSwapper(98));
        vm.expectRevert(); // OwnableUnauthorizedAccount
        hook.setCrossPoolOracle(ParityCrossPoolOracle(address(1)));
    }
}
