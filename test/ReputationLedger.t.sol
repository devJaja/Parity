// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ParityTest} from "./Base.t.sol";

import {ReputationLedger} from "../src/ReputationLedger.sol";
import {SignalLib} from "../src/libraries/SignalLib.sol";

contract LedgerHarness is ReputationLedger {
    constructor(address authority, address owner) ReputationLedger(authority, owner) {}

    function exposedApply(
        address swapper,
        SignalLib.Observation memory current,
        bool hadPriorOwn,
        SignalLib.Observation memory priorOwn,
        SignalLib.Observation memory priorPool
    ) external returns (int256, Tier) {
        return this.applySwapSignals(swapper, current, hadPriorOwn, priorOwn, priorPool);
    }

    function reversalWindow() external view returns (uint32) {
        return config.signals.reversalWindowBlocks;
    }
}

/// @notice Decay, clamping, tier boundaries and access control on the ledger itself,
///          exercised without the hook so every rule is observable in isolation.
contract ReputationLedgerTest is ParityTest {
    LedgerHarness harness;
    address authority = address(0xAAAA2);
    address owner = address(0xBBBB2);

    function setUp() public {
        super._deployParity();
        harness = new LedgerHarness(authority, owner);
    }

    function _obs(address who, bool zfo, uint256 impact, uint64 bn)
        internal
        pure
        returns (SignalLib.Observation memory)
    {
        return SignalLib.Observation({swapper: who, zeroForOne: zfo, amountIn: 1e18, priceImpactBps: impact, blockNumber: bn});
    }

    function test_starts_neutral_and_untrusted() public view {
        assertEq(harness.scoreOf(address(0x1)), 500);
        assertEq(uint8(harness.tierOf(address(0x1))), uint8(ReputationLedger.Tier.Neutral));
    }

    function test_only_authority_can_apply_signals() public {
        vm.prank(owner);
        vm.expectRevert(ReputationLedger.Unauthorized.selector);
        harness.applySwapSignals(address(0x1), _obs(address(0x1), true, 10, 1), false, _obs(address(0), true, 0, 0), _obs(address(0), true, 0, 0));
    }

    function test_first_swap_initializes_at_neutral() public {
        vm.prank(authority);
        (int256 score, ReputationLedger.Tier tier) =
            harness.applySwapSignals(address(0x42), _obs(address(0x42), true, 10_000, 5), false, _obs(address(0), true, 0, 0), _obs(address(0), true, 0, 0));
        // Heavy-impact swap from a fresh account: neutral minus impact penalty only.
        assertEq(score, 500 - 70);
        assertTrue(uint8(tier) <= uint8(ReputationLedger.Tier.Neutral) + 1); // sanity
        assertEq(harness.lastSwapBlock(address(0x42)), 5);
    }

    function test_decay_toward_neutral_over_blocks() public {
        vm.startPrank(authority);
        harness.applySwapSignals(address(0x42), _obs(address(0x42), true, 10_000, 5), false, _obs(address(0), true, 0, 0), _obs(address(0), true, 0, 0));
        int256 afterHit = harness.scoreOf(address(0x42)); // 430
        assertEq(afterHit, 430);

        // 30 blocks later, one point per block of the 70-point drift has decayed.
        vm.roll(35);
        assertEq(harness.scoreOf(address(0x42)), 460);
        vm.roll(200); // fully settled back to neutral
        assertEq(harness.scoreOf(address(0x42)), 500);
        vm.stopPrank();
    }

    function test_decay_persists_through_update() public {
        vm.startPrank(authority);
        harness.applySwapSignals(address(0x42), _obs(address(0x42), true, 10_000, 5), false, _obs(address(0), true, 0, 0), _obs(address(0), true, 0, 0));
        vm.roll(100); // fully decayed to neutral before next swap (needs >= 70 blocks)
        harness.applySwapSignals(address(0x42), _obs(address(0x42), false, 10_000, 101), true, _obs(address(0x42), true, 10_000, 5), _obs(address(0x42), true, 10_000, 5));
        // penalties: impact -70; reversal window elapsed → 0; rapid fire → 0; correlation same swapper → 0
        assertEq(harness.scoreOf(address(0x42)), 500 - 70);
        vm.stopPrank();
    }

    function test_reversal_penalty_applies_within_window() public {
        vm.startPrank(authority);
        harness.applySwapSignals(address(0x42), _obs(address(0x42), true, 10, 5), false, _obs(address(0), true, 0, 0), _obs(address(0), true, 0, 0));
        // benign first swap earns bonus: 500 + 6
        assertEq(harness.scoreOf(address(0x42)), 506);

        vm.roll(6);
        harness.applySwapSignals(address(0x42), _obs(address(0x42), false, 10, 6), true, _obs(address(0x42), true, 10, 5), _obs(address(0x42), true, 10, 5));
        // lazy decay of +1 (one block of the +6 drift), then: bonus +6, rapid-fire -18, reversal -35
        // → 506 - 1 + 6 - 18 - 35 = 458
        assertEq(harness.scoreOf(address(0x42)), 458);
        vm.stopPrank();
    }

    function test_reversal_penalty_at_window_boundary() public {
        uint64 gap = uint64(harness.reversalWindow());
        vm.startPrank(authority);
        harness.applySwapSignals(address(0x42), _obs(address(0x42), true, 10, 5), false, _obs(address(0), true, 0, 0), _obs(address(0), true, 0, 0));
        vm.roll(5 + gap);
        harness.applySwapSignals(address(0x42), _obs(address(0x42), false, 10, 5 + gap), true, _obs(address(0x42), true, 10, 5), _obs(address(0x42), true, 10, 5));
        // exactly at the window edge the flip is still penalized:
        // decayed 506-gap, +bonus, -reversal (rapid-fire window already elapsed)
        int256 decayed = 506 - int256(uint256(gap));
        assertEq(harness.scoreOf(address(0x42)), decayed + 6 - 35);
        vm.stopPrank();
    }

    function test_reversal_penalty_elapsed_after_window() public {
        uint64 gap = uint64(harness.reversalWindow()) + 1;
        vm.startPrank(authority);
        harness.applySwapSignals(address(0x42), _obs(address(0x42), true, 10, 5), false, _obs(address(0), true, 0, 0), _obs(address(0), true, 0, 0));
        vm.roll(5 + gap);
        harness.applySwapSignals(address(0x42), _obs(address(0x42), false, 10, 5 + gap), true, _obs(address(0x42), true, 10, 5), _obs(address(0x42), true, 10, 5));
        // past the window the flip is benign: decayed 506-gap, +bonus only, no reversal penalty
        int256 decayed = 506 - int256(uint256(gap));
        assertEq(harness.scoreOf(address(0x42)), decayed + 6);
        vm.stopPrank();
    }

    function test_clamped_at_zero_and_thousand() public {
        vm.startPrank(authority);
        // Drive far below zero with repeated worst-case swaps.
        for (uint64 i = 1; i <= 8; ++i) {
            harness.applySwapSignals(address(0x99), _obs(address(0x9999), true, 10_000, i * 10), i > 1, _obs(address(0x99), true, 10_000, (i - 1) * 10), _obs(address(0x8888), true, 10_000, (i - 1) * 10));
        }
        assertEq(harness.scoreOf(address(0x99)), 0);
        vm.stopPrank();

        vm.startPrank(owner);
        harness.forceSetScore(address(0x77), 1000);
        assertEq(harness.scoreOf(address(0x77)), 1000);
        vm.stopPrank();
    }

    function test_tier_boundaries() public {
        vm.startPrank(owner);
        harness.forceSetScore(address(0x1), 299);
        assertTrue(uint8(harness.tierOf(address(0x1))) == uint8(ReputationLedger.Tier.Flagged));
        harness.forceSetScore(address(0x1), 300);
        assertTrue(uint8(harness.tierOf(address(0x1))) == uint8(ReputationLedger.Tier.Neutral));
        harness.forceSetScore(address(0x1), 699);
        assertTrue(uint8(harness.tierOf(address(0x1))) == uint8(ReputationLedger.Tier.Neutral));
        harness.forceSetScore(address(0x1), 700);
        assertTrue(uint8(harness.tierOf(address(0x1))) == uint8(ReputationLedger.Tier.Trusted));
        vm.stopPrank();
    }

    function test_force_set_score_bounds() public {
        vm.startPrank(owner);
        vm.expectRevert(ReputationLedger.InvalidScoreBounds.selector);
        harness.forceSetScore(address(0x1), 1001);
        vm.expectRevert(ReputationLedger.InvalidScoreBounds.selector);
        harness.forceSetScore(address(0x1), -1);
        harness.forceSetScore(address(0x1), 700);
        assertEq(uint8(harness.tierOf(address(0x1))), uint8(ReputationLedger.Tier.Trusted));
        vm.stopPrank();

        vm.prank(address(0xDEAD));
        vm.expectRevert();
        harness.forceSetScore(address(0x1), 100);
    }
}
