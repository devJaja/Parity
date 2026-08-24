// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title SignalLib
/// @notice Pure library implementing the four behavioral signals Parity uses to score swap flow.
///         Isolated from storage and access control so every rule is unit-testable in isolation.
/// @dev    Every function is pure: it takes observations plus configuration and returns a signed
///         reputation adjustment. Negative adjustments move an address toward Flagged, zero or
///         positive adjustments do not. Positive adjustments are reserved for benign behavior
///         (Signal 1 only). The ReputationLedger owns all state, clamping and decay.
library SignalLib {
    /// @notice A single observed swap, normalized for signal computation.
    struct Observation {
        address swapper;
        bool zeroForOne;
        uint256 amountIn;
        /// @dev |sqrtPriceAfter - sqrtPriceBefore| * 1e4 / sqrtPriceBefore — size relative to depth.
        uint256 priceImpactBps;
        uint64 blockNumber;
    }

    /// @notice Weights and thresholds for all four signals. Owned by the ReputationLedger,
    ///         governance-configurable per deployment.
    struct SignalConfig {
        // --- Signal 1: swap-to-depth ---
        uint256 impactBenignBps; // at/below: benign bonus
        uint256 impactT1Bps; // above: first penalty tier
        uint256 impactT2Bps; // above: second penalty tier
        uint256 impactT3Bps; // above: heaviest penalty tier
        int16 benignBonus;
        int16 impactPenalty1;
        int16 impactPenalty2;
        int16 impactPenalty3;
        // --- Signal 2: directional correlation ---
        int16 correlationPenalty;
        // --- Signal 3: rapid fire ---
        uint32 rapidWindowBlocks;
        int16 rapidFirePenalty;
        // --- Signal 4: reversal ---
        uint32 reversalWindowBlocks;
        int16 reversalPenalty;
    }

    /// @notice Default configuration used by the ledger unless governance changes it.
    function defaultConfig() internal pure returns (SignalConfig memory c) {
        c = SignalConfig({
            // Signal 1 — price impact tiers (bps): benign < 30, escalating at 80/200/500.
            impactBenignBps: 30,
            impactT1Bps: 80,
            impactT2Bps: 200,
            impactT3Bps: 500,
            benignBonus: 6,
            impactPenalty1: -10,
            impactPenalty2: -25,
            impactPenalty3: -70,
            // Signal 2 — same-direction follow within one block by a different address.
            correlationPenalty: -22,
            // Signal 3 — own re-swap within 2 blocks.
            rapidWindowBlocks: 2,
            rapidFirePenalty: -18,
            // Signal 4 — direction flip within 3 blocks.
            reversalWindowBlocks: 3,
            reversalPenalty: -35
        });
    }

    // ------------------------------------------------------------------
    // Signal 1 — Swap-to-depth ratio
    // ------------------------------------------------------------------

    /// @notice Adjustment for swaps sized relative to pool depth (measured by realized price
    ///         impact) — the setup/teardown signature of a sandwich.
    function swapToDepthAdjustment(uint256 priceImpactBps, SignalConfig memory c)
        internal
        pure
        returns (int16 adjustment)
    {
        if (priceImpactBps > c.impactT3Bps) return c.impactPenalty3;
        if (priceImpactBps > c.impactT2Bps) return c.impactPenalty2;
        if (priceImpactBps > c.impactT1Bps) return c.impactPenalty1;
        if (priceImpactBps <= c.impactBenignBps) return c.benignBonus;
        return 0;
    }

    // ------------------------------------------------------------------
    // Signal 2 — Directional correlation
    // ------------------------------------------------------------------

    /// @notice Penalty for swapping the same direction as, and immediately following,
    ///         another address's swap — flow that piles onto someone else's move.
    function directionalCorrelationAdjustment(Observation memory previous, Observation memory current, SignalConfig memory c)
        internal
        pure
        returns (int16 adjustment)
    {
        bool differentSwapper = previous.swapper != current.swapper;
        bool sameDirection = previous.zeroForOne == current.zeroForOne;
        bool sameBlockOrAdjacent = current.blockNumber <= previous.blockNumber + 1;

        if (differentSwapper && sameDirection && sameBlockOrAdjacent) {
            return c.correlationPenalty;
        }
        return 0;
    }

    // ------------------------------------------------------------------
    // Signal 3 — Time-since-last-swap (rapid fire)
    // ------------------------------------------------------------------

    /// @notice Penalty for swapping again within `rapidWindowBlocks` of one's own last swap.
    /// @return adjustment Zero when no prior swap exists or enough blocks have elapsed.
    function rapidFireAdjustment(uint64 lastSwapBlock, uint64 currentBlock, SignalConfig memory c)
        internal
        pure
        returns (int16 adjustment)
    {
        if (lastSwapBlock == 0) return 0;
        if (currentBlock < lastSwapBlock) return 0; // saturating: never underflow on stale data
        if (currentBlock - lastSwapBlock <= c.rapidWindowBlocks) return c.rapidFirePenalty;
        return 0;
    }

    // ------------------------------------------------------------------
    // Signal 4 — Net position reversal
    // ------------------------------------------------------------------

    /// @notice Penalty for reversing direction within `reversalWindowBlocks` of one's own prior
    ///         swap — opening and closing in a short window indicates extractive intent.
    /// @return adjustment Zero when there is no prior own-swap or the direction did not flip.
    /// @param hadPriorSwap False when this is the address's first observed swap on this pool.
    function reversalAdjustment(bool hadPriorSwap, bool previousZeroForOne, bool currentZeroForOne, SignalConfig memory c)
        internal
        pure
        returns (int16 adjustment)
    {
        if (!hadPriorSwap) return 0;
        if (previousZeroForOne != currentZeroForOne) return c.reversalPenalty;
        return 0;
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    /// @notice Computes price impact in basis points from two square-root prices.
    ///         Used by the hook to populate `Observation.priceImpactBps`.
    function impactBps(uint160 sqrtPriceBefore, uint160 sqrtPriceAfter) internal pure returns (uint256) {
        if (sqrtPriceBefore == 0) return 0;
        uint256 before_ = uint256(sqrtPriceBefore);
        uint256 after_ = uint256(sqrtPriceAfter);
        uint256 diff = after_ > before_ ? after_ - before_ : before_ - after_;
        return (diff * 10_000) / before_;
    }
}
