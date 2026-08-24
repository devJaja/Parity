// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @title IParityLpRegistry
/// @notice Read interface through which the LVRReserve discovers eligible liquidity providers
///         and their tracked position sizes. Implemented by ParityHook from its
///         afterAddLiquidity / afterRemoveLiquidity observations.
interface IParityLpRegistry {
    /// @notice Net tracked liquidity contributed by `lp` on `poolId`. Negative values are
    ///         reported as zero by consumers; they indicate over-removal bookkeeping edge cases.
    function lpNet(PoolId poolId, address lp) external view returns (uint256 net);

    /// @notice Block of the LP's most recent liquidity change on `poolId`.
    function lpLastChangeBlock(PoolId poolId, address lp) external view returns (uint64 blockNumber);

    /// @notice Number of addresses that have ever provided liquidity on `poolId`.
    function lpCount(PoolId poolId) external view returns (uint256 count);

    /// @notice Enumerated access to providers on `poolId`, for bounded batch payouts.
    function lpAt(PoolId poolId, uint256 index) external view returns (address lp);
}
