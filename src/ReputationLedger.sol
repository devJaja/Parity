// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {SignalLib} from "./libraries/SignalLib.sol";

/// @title ReputationLedger
/// @notice Stores per-address reputation scores (0–1000, neutral 500), applies signal-driven
///         adjustments and time-based decay toward neutral, and derives the swap treatment tier.
/// @dev    Only the authority contract (the ParityHook) may write. Scores are stored as of the
///         address's last activity and decayed lazily on read, so reads are cheap and storage
///         writes happen only when a swap actually moves a score past the rounding threshold.
contract ReputationLedger is Ownable {
    using SignalLib for SignalLib.Observation;

    // ------------------------------------------------------------------
    // Types
    // ------------------------------------------------------------------

    /// @notice Swap treatment tiers derived from reputation scores.
    enum Tier {
        Flagged, // 0–299   : ordering delay + risk premium
        Neutral, // 300–699 : ordering delay only
        Trusted // 700–1000: base fee, instant execution
    }

    struct Account {
        int256 score; // clamped to [0, 1000], stored as-of lastActivityBlock
        uint64 lastSwapBlock; // 0 = never swapped
        bool lastZeroForOne; // direction of the last observed swap
        uint64 lastActivityBlock; // block of last score-affecting update (swap or decay checkpoint)
    }

    /// @notice Governance-tunable ledger parameters.
    struct LedgerConfig {
        uint32 decayPerBlock; // points of decay toward neutral per elapsed block
        SignalLib.SignalConfig signals;
    }

    // ------------------------------------------------------------------
    // Storage
    // ------------------------------------------------------------------

    mapping(address => Account) internal accounts;

    LedgerConfig public config;

    /// @notice Address allowed to apply updates (the ParityHook).
    address public immutable authority;

    // ------------------------------------------------------------------
    // Constants
    // ------------------------------------------------------------------

    int256 internal constant SCORE_MIN = 0;
    int256 internal constant SCORE_MAX = 1000;
    int256 internal constant SCORE_NEUTRAL = 500;
    int256 internal constant TRUSTED_THRESHOLD = 700;
    int256 internal constant FLAGGED_THRESHOLD = 300;

    // ------------------------------------------------------------------
    // Errors
    // ------------------------------------------------------------------

    error Unauthorized();
    error InvalidScoreBounds();

    // ------------------------------------------------------------------
    // Events
    // ------------------------------------------------------------------

    event ReputationUpdated(address indexed swapper, int256 newScore, Tier tier);
    event ConfigUpdated(uint32 decayPerBlock);

    // ------------------------------------------------------------------
    // Constructor / admin
    // ------------------------------------------------------------------

    constructor(address _authority, address initialOwner) Ownable(initialOwner) {
        authority = _authority;
        config = LedgerConfig({decayPerBlock: 1, signals: SignalLib.defaultConfig()});
    }

    function setDecayPerBlock(uint32 decayPerBlock) external onlyOwner {
        config.decayPerBlock = decayPerBlock;
        emit ConfigUpdated(decayPerBlock);
    }

    function setSignalConfig(SignalLib.SignalConfig memory signals) external onlyOwner {
        config.signals = signals;
    }

    // ------------------------------------------------------------------
    // Writes (authority only)
    // ------------------------------------------------------------------

    /// @notice Applies the four behavioral signals for a swap, then decays the score for blocks
    ///         elapsed since this address's previous activity.
    /// @param  swapper      The account whose flow is being scored.
    /// @param  current      The normalized observation of the swap just executed.
    /// @param  hadPriorOwn  Whether `priorOwn` is populated for this swapper on this pool.
    /// @param  priorOwn     The swapper's own prior observation on this pool (reversal signal).
    /// @param  priorPool    The pool's immediately preceding observation, any swapper
    ///                      (directional-correlation signal).
    /// @return newScore     The post-update, post-decay score in [0, 1000].
    /// @return newTier      The treatment tier implied by `newScore`.
    function applySwapSignals(
        address swapper,
        SignalLib.Observation memory current,
        bool hadPriorOwn,
        SignalLib.Observation memory priorOwn,
        SignalLib.Observation memory priorPool
    ) external returns (int256 newScore, Tier newTier) {
        if (msg.sender != authority) revert Unauthorized();

        Account storage a = accounts[swapper];

        // Lazily settle pending decay before mutating, so adjustments land on the settled value.
        // A first-ever interaction settles to neutral: fresh addresses start Neutral, never
        // Trusted — sybilling only recovers baseline treatment, never an advantage.
        int256 settled = _settled(a);

        SignalLib.SignalConfig memory c = config.signals;

        int16 adjustment = SignalLib.swapToDepthAdjustment(current.priceImpactBps, c)
            + SignalLib.directionalCorrelationAdjustment(priorPool, current, c)
            + SignalLib.rapidFireAdjustment(a.lastSwapBlock, current.blockNumber, c);

        // Reversal counts only when the direction flip happens inside the configured window.
        // Saturating on block numbers: observations may be supplied out-of-order by callers.
        if (
            hadPriorOwn && priorOwn.zeroForOne != current.zeroForOne
                && current.blockNumber >= priorOwn.blockNumber
                && current.blockNumber - priorOwn.blockNumber <= c.reversalWindowBlocks
        ) {
            adjustment += c.reversalPenalty;
        }

        newScore = _clamp(settled + int256(adjustment));

        a.score = newScore;
        a.lastSwapBlock = current.blockNumber;
        a.lastActivityBlock = current.blockNumber;
        a.lastZeroForOne = current.zeroForOne;

        newTier = tierOf(swapper);
        emit ReputationUpdated(swapper, newScore, newTier);
    }

    /// @notice Directly sets a score. Intended for governance remediation and test harnesses.
    function forceSetScore(address swapper, int256 score) external onlyOwner {
        if (score < SCORE_MIN || score > SCORE_MAX) revert InvalidScoreBounds();
        Account storage a = accounts[swapper];
        a.score = score;
        a.lastActivityBlock = uint64(block.number);
        emit ReputationUpdated(swapper, score, _tierFor(score));
    }

    // ------------------------------------------------------------------
    // Reads (lazy decay applied)
    // ------------------------------------------------------------------

    /// @notice Score with pending block-decay applied. Does not persist the decayed value.
    function scoreOf(address swapper) public view returns (int256) {
        return _settled(accounts[swapper]);
    }

    /// @notice Treatment tier for an address at the current block.
    function tierOf(address swapper) public view returns (Tier) {
        return _tierFor(scoreOf(swapper));
    }

    /// @notice Block number of the address's last observed swap (0 = never).
    function lastSwapBlock(address swapper) external view returns (uint64) {
        return accounts[swapper].lastSwapBlock;
    }

    /// @notice Direction of the address's last observed swap.
    function lastZeroForOne(address swapper) external view returns (bool) {
        return accounts[swapper].lastZeroForOne;
    }

    // ------------------------------------------------------------------
    // Internals
    // ------------------------------------------------------------------

    /// @dev Decays a stored score toward neutral by `decayPerBlock` per elapsed block.
    ///      Saturating on elapsed blocks so stale or future-stamped activity cannot underflow.
    function _settled(Account storage a) internal view returns (int256) {
        if (a.lastActivityBlock == 0) return SCORE_NEUTRAL;
        if (a.score == SCORE_NEUTRAL) return a.score;

        uint64 elapsed = uint64(block.number) >= a.lastActivityBlock
            ? uint64(block.number) - a.lastActivityBlock
            : 0;
        int256 drift = a.score - SCORE_NEUTRAL;
        int256 magnitude = drift > 0 ? drift : -drift;
        int256 decay = int256(uint256(elapsed)) * int256(uint256(config.decayPerBlock));

        if (decay >= magnitude) return SCORE_NEUTRAL;
        return a.score - (drift > 0 ? decay : -decay);
    }

    function _clamp(int256 score) internal pure returns (int256) {
        if (score < SCORE_MIN) return SCORE_MIN;
        if (score > SCORE_MAX) return SCORE_MAX;
        return score;
    }

    function _tierFor(int256 score) internal pure returns (Tier) {
        if (score >= TRUSTED_THRESHOLD) return Tier.Trusted;
        if (score >= FLAGGED_THRESHOLD) return Tier.Neutral;
        return Tier.Flagged;
    }
}
