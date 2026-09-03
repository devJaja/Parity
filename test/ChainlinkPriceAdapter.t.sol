// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {ChainlinkPriceAdapter, AggregatorV3Interface} from "../src/ChainlinkPriceAdapter.sol";
import {MockAggregator} from "./mocks/MockAggregator.sol";

/// @notice Unit proof for the Chainlink integration (`src/ChainlinkPriceAdapter.sol`):
///         a thin, staleness-guarded wrapper over a canonical Chainlink AggregatorV3 feed that
///         normalizes every quote to 18 decimals so the LVR verifier can compare the pool's
///         price against the independent reference without per-feed special-casing.
///
/// @dev These tests exercise the adapter's own logic deterministically (decimals
///      normalization, staleness guard, invalid-answer rejection) against the AggregatorV3 mock.
///      Live-feed compatibility with the real on-chain AggregatorV3 is proven by the adapter
///      reading the deployed ETH/USD feed via `latestRaw`/`latestPrice18` on Base Sepolia.
contract ChainlinkPriceAdapterTest is Test {
    function test_normalizes_feed_to_18_decimals() public {
        // Standard Chainlink feeds are 8-decimal: e.g. ETH/USD reports ~2400.79 as 240079959788.
        MockAggregator agg = new MockAggregator(8, 240_079_959_788);
        ChainlinkPriceAdapter adapter = new ChainlinkPriceAdapter(agg, 3600);

        (uint256 price18,) = adapter.latestPrice18();
        // 240079959788 * 10^(18-8) = 240079959788e10 exactly (= $2400.79 in 18 decimals).
        assertEq(price18, 240_079_959_788e10, "8-dec answer must be scaled to 18 decimals");
    }

    function test_no_scale_for_18_decimal_feed() public {
        MockAggregator agg = new MockAggregator(18, 1234e18);
        ChainlinkPriceAdapter adapter = new ChainlinkPriceAdapter(agg, 3600);

        (uint256 price18,) = adapter.latestPrice18();
        assertEq(price18, 1234e18, "18-dec answer must pass through unchanged");
    }

    function test_scales_6_decimal_feed_to_18() public {
        // A 6-decimal feed (e.g. a stablecoin quote at 1.000000) -> 1e18.
        MockAggregator agg = new MockAggregator(6, 999_999);
        ChainlinkPriceAdapter adapter = new ChainlinkPriceAdapter(agg, 3600);

        (uint256 price18,) = adapter.latestPrice18();
        assertEq(price18, 999_999e12, "6-dec answer must be scaled to 18 decimals");
    }

    function test_stale_price_reverts() public {
        vm.warp(1_000_000); // realistic clock so staleness arithmetic stays positive
        MockAggregator agg = new MockAggregator(8, 1e8);
        ChainlinkPriceAdapter adapter = new ChainlinkPriceAdapter(agg, 3600);

        // Feed answer is 3601s old -> exceeds the 3600s guard.
        agg.setUpdatedAt(block.timestamp - 3601);
        vm.expectRevert(ChainlinkPriceAdapter.StalePrice.selector);
        adapter.latestPrice18();
    }

    function test_non_positive_answer_reverts() public {
        MockAggregator agg = new MockAggregator(8, 0); // answer <= 0
        ChainlinkPriceAdapter adapter = new ChainlinkPriceAdapter(agg, 3600);

        vm.expectRevert(ChainlinkPriceAdapter.InvalidAnswer.selector);
        adapter.latestPrice18();
    }

    function test_constructing_feed_with_more_than_18_decimals_reverts() public {
        MockAggregator agg = new MockAggregator(19, 1);
        vm.expectRevert(ChainlinkPriceAdapter.InvalidAnswer.selector);
        new ChainlinkPriceAdapter(agg, 3600);
    }

    function test_latestRaw_exposes_feed_metadata() public {
        MockAggregator agg = new MockAggregator(8, 50_00000000);
        ChainlinkPriceAdapter adapter = new ChainlinkPriceAdapter(agg, 3600);

        (uint80 roundId, int256 answer,, uint256 updatedAt,) = adapter.latestRaw();
        assertEq(uint256(roundId), 1);
        assertEq(uint256(answer), 50_00000000);
        assertEq(updatedAt, block.timestamp);
    }
}
