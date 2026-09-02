// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {SignalLib} from "../src/libraries/SignalLib.sol";

/// @notice Unit coverage for the four behavioral signals across their full input space,
///         plus property fuzzing (monotonicity, boundary behavior).
contract SignalLibTest is Test {
    using SignalLib for SignalLib.Observation;

    SignalLib.SignalConfig c;

    function setUp() public {
        c = SignalLib.defaultConfig();
    }

    function _obs(address who, bool zfo, uint256 impactBps_, uint64 blockNumber)
        internal
        pure
        returns (SignalLib.Observation memory)
    {
        return SignalLib.Observation({swapper: who, zeroForOne: zfo, amountIn: 1e18, priceImpactBps: impactBps_, blockNumber: blockNumber});
    }

    // ------------------------------------------------------------------
    // Signal 1 — swap-to-depth
    // ------------------------------------------------------------------

    function test_impact_tiers_exact_boundaries() public view {
        // At or below benign: bonus.
        assertEq(SignalLib.swapToDepthAdjustment(0, c), c.benignBonus);
        assertEq(SignalLib.swapToDepthAdjustment(30, c), c.benignBonus);
        // Strictly above thresholds: escalating penalties.
        assertEq(SignalLib.swapToDepthAdjustment(31, c), 0);
        assertEq(SignalLib.swapToDepthAdjustment(81, c), c.impactPenalty1);
        assertEq(SignalLib.swapToDepthAdjustment(201, c), c.impactPenalty2);
        assertEq(SignalLib.swapToDepthAdjustment(501, c), c.impactPenalty3);
    }

    function testFuzz_impact_monotonic_nonincreasing(uint256 impactA, uint256 impactB) public view {
        impactA = bound(impactA, 0, 100_000);
        impactB = bound(impactB, 0, 100_000);
        int16 adjA = SignalLib.swapToDepthAdjustment(impactA, c);
        int16 adjB = SignalLib.swapToDepthAdjustment(impactB, c);
        if (impactB >= impactA) {
            assertTrue(adjB <= adjA, "adjustment must not increase with impact");
        }
    }

    function testFuzz_impact_bounded(uint256 impact) public view {
        impact = bound(impact, 0, type(uint256).max / 10_000 - 1);
        int16 adj = SignalLib.swapToDepthAdjustment(impact, c);
        assertTrue(adj <= c.benignBonus && adj >= c.impactPenalty3, "adjustment escapes configured range");
    }

    // ------------------------------------------------------------------
    // Signal 2 — directional correlation
    // ------------------------------------------------------------------

    function test_correlation_penalized_same_direction_follow() public view {
        SignalLib.Observation memory prev = _obs(address(0xA11CE), true, 10, 100);
        SignalLib.Observation memory curr = _obs(address(0xB0B), true, 10, 101); // next block, same dir
        assertEq(
            SignalLib.directionalCorrelationAdjustment(prev, curr, c),
            c.correlationPenalty,
            "piling on should be penalized"
        );
    }

    function test_correlation_zero_for_opposite_direction() public view {
        SignalLib.Observation memory prev = _obs(address(0xA11CE), true, 10, 100);
        SignalLib.Observation memory curr = _obs(address(0xB0B), false, 10, 100);
        assertEq(SignalLib.directionalCorrelationAdjustment(prev, curr, c), 0, "opposite direction is not correlation");
    }

    function test_correlation_zero_for_same_swapper() public view {
        address a = address(0xA11CE);
        SignalLib.Observation memory prev = _obs(a, true, 10, 100);
        SignalLib.Observation memory curr = _obs(a, true, 10, 100);
        assertEq(SignalLib.directionalCorrelationAdjustment(prev, curr, c), 0, "same swapper handled by other signals");
    }

    function test_correlation_zero_after_window() public view {
        SignalLib.Observation memory prev = _obs(address(0xA11CE), true, 10, 100);
        SignalLib.Observation memory curr = _obs(address(0xB0B), true, 10, 102); // two blocks later
        assertEq(SignalLib.directionalCorrelationAdjustment(prev, curr, c), 0, "stale follow is not correlated");
    }

    // ------------------------------------------------------------------
    // Signal 3 — rapid fire
    // ------------------------------------------------------------------

    function test_rapid_fire_within_window() public view {
        assertEq(SignalLib.rapidFireAdjustment(100, 102, c), c.rapidFirePenalty, "re-swap inside window penalized");
    }

    function test_rapid_fire_outside_window_and_first_swap() public view {
        assertEq(SignalLib.rapidFireAdjustment(100, 103, c), 0, "outside window clean");
        assertEq(SignalLib.rapidFireAdjustment(0, 1, c), 0, "first-ever swap clean");
    }

    function testFuzz_rapid_fire_boundary(uint64 gap) public view {
        gap = uint64(bound(gap, 0, 50));
        int16 expected = gap <= c.rapidWindowBlocks ? c.rapidFirePenalty : int16(0);
        assertEq(SignalLib.rapidFireAdjustment(1000, 1000 + gap, c), expected);
    }

    // ------------------------------------------------------------------
    // Helper — impact math
    // ------------------------------------------------------------------

    function test_impactBps_math() public pure {
        assertEq(SignalLib.impactBps(10_000, 10_500), 500, "5% move = 500bps");
        assertEq(SignalLib.impactBps(10_000, 9_000), 1000, "down moves measured absolutely");
        assertEq(SignalLib.impactBps(10_000, 10_000), 0, "no move no impact");
        assertEq(SignalLib.impactBps(0, 5), 0, "zero anchor safe");
    }
}
