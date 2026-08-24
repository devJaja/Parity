// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AggregatorV3Interface} from "../../src/ChainlinkPriceAdapter.sol";

/// @notice Minimal Chainlink AggregatorV3 mock for deterministic verification testing.
contract MockAggregator is AggregatorV3Interface {
    uint8 public immutable override decimals;
    int256 public answer;
    uint256 public updatedAt;

    constructor(uint8 _decimals, int256 _initialAnswer) {
        decimals = _decimals;
        answer = _initialAnswer;
        updatedAt = block.timestamp;
    }

    function setAnswer(int256 _answer) external {
        answer = _answer;
        updatedAt = block.timestamp;
    }

    function setUpdatedAt(uint256 ts) external {
        updatedAt = ts;
    }

    function description() external pure returns (string memory) {
        return "Mock feed";
    }

    function version() external pure returns (uint256) {
        return 1;
    }

    function getRoundData(uint80)
        external
        view
        returns (uint80 roundId, int256 ans, uint256 startedAt, uint256 fetchedAt, uint80 answeredInRound)
    {
        return (1, answer, block.timestamp, updatedAt, 1);
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 ans, uint256 startedAt, uint256 fetchedAt, uint80 answeredInRound)
    {
        return (1, answer, block.timestamp, updatedAt, 1);
    }
}
