// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Canonical interface of a Chainlink Data Feed (AggregatorV3), declared locally so the
///         project does not depend on where each integration vendored it.
interface AggregatorV3Interface {
    function decimals() external view returns (uint8);

    function description() external view returns (string memory);

    function version() external view returns (uint256);

    function getRoundData(uint80 roundId)
        external
        view
        returns (uint80 id, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// @title ChainlinkPriceAdapter
/// @notice Thin, staleness-guarded wrapper around a Chainlink Data Feed. Normalizes every quote
///         to 18 decimals so LVR verification can compare pool prices and reference prices in
///         the same units without per-feed special-casing.
/// @dev    This is the non-circular anchor of the system: Parity never verifies harm using the
///         pool's own price as both evidence and judge.
contract ChainlinkPriceAdapter {
    // ------------------------------------------------------------------
    // Immutable parameters
    // ------------------------------------------------------------------

    /// @notice The Chainlink Data Feed for the pool's pair.
    AggregatorV3Interface public immutable feed;

    /// @notice Maximum acceptable age (seconds) of a feed answer.
    uint256 public immutable maxStalenessSeconds;

    /// @notice Power-of-ten factor applied to raw answers to reach 18 decimals.
    int256 internal immutable normalizeFactor;

    // ------------------------------------------------------------------
    // Errors
    // ------------------------------------------------------------------

    error StalePrice();
    error InvalidAnswer();

    // ------------------------------------------------------------------
    // Constructor
    // ------------------------------------------------------------------

    constructor(AggregatorV3Interface _feed, uint256 _maxStalenessSeconds) {
        feed = _feed;
        maxStalenessSeconds = _maxStalenessSeconds;
        uint8 feedDecimals = _feed.decimals();
        if (feedDecimals > 18) revert InvalidAnswer();
        // 10^(18 - decimals), computed without exponentiation on ints.
        int256 factor = 1;
        for (uint256 i = feedDecimals; i < 18; ++i) factor *= 10;
        normalizeFactor = factor;
    }

    // ------------------------------------------------------------------
    // Reads
    // ------------------------------------------------------------------

    /// @notice Latest normalized price and its feed timestamp.
    /// @return price18 Reference price scaled to 18 decimals.
    /// @return updatedAt Feed answer timestamp; caller may apply additional policy on top of
    ///                   the hard staleness guard enforced here.
    function latestPrice18() external view returns (uint256 price18, uint256 updatedAt) {
        (, int256 answer,, uint256 fetchedAt,) = feed.latestRoundData();
        if (answer <= 0) revert InvalidAnswer();
        if (block.timestamp - fetchedAt > maxStalenessSeconds) revert StalePrice();
        return (uint256(answer * normalizeFactor), fetchedAt);
    }

    /// @notice Raw feed answer with metadata, for dashboards and integrations.
    function latestRaw()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return feed.latestRoundData();
    }
}
