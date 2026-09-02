// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title IECDSAStakeRegistry
/// @notice Minimal consumer-facing subset of EigenLayer's `ECDSAStakeRegistry`
///         (eigenlayer-middleware, src/unaudited/ECDSAStakeRegistry.sol). ABI-faithful:
///         `signatureData` decodes to `(address[] operators, bytes[] signatures,
///         uint32 referenceBlock)` and verification enforces stake-weighted quorum over the
///         AVS's registered operator set at the given reference block, exactly as the real
///         registry does. Deployments point `ParityCrossPoolOracle.stakeRegistry` at the
///         actual ECDSAStakeRegistry proxy of the Parity AVS.
interface IECDSAStakeRegistry {
    /// @notice ERC-1271-style quorum signature check. Reverts unless the supplied operators,
    ///         in strictly ascending order, carry sufficient signed stake at `referenceBlock`.
    function isValidSignature(bytes32 digest, bytes calldata signatureData) external view returns (bytes4);

    /// @notice Total stake-weight carried by the currently registered operator set.
    function getLastCheckpointTotalWeight() external view returns (uint256);
}
