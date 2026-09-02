// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {IECDSAStakeRegistry} from "./IECDSAStakeRegistry.sol";

/// @title ParityCrossPoolOracle
/// @notice EigenLayer AVS consumer for cross-pool reputation aggregation (doc §9, first
///         roadmap item). Operators of the Parity AVS observe an address's behavior across
///         every Parity-protected pool and co-sign reputation attestations; this contract
///         verifies those attestations against the AVS's ECDSAStakeRegistry — a signature set
///         is accepted only when the signing operators carried the configured stake-weighted
///         quorum at a recent reference block — and exposes freshness-bounded scores that the
///         ParityHook uses to seed the ledger of addresses with no local history.
/// @dev    Consumer-side only: task creation/response plumbing and operator services run in
///         EigenLayer's off-chain infrastructure. On-chain, this is exactly where an AVS
///         consumer lands: quorum verification via `isValidSignature`, replay protection by
///         domain-separating `(chainid, this, subject, score, referenceBlock)`.
contract ParityCrossPoolOracle is Ownable {
    // ------------------------------------------------------------------
    // Types
    // ------------------------------------------------------------------

    struct Attestation {
        int256 score; // cross-pool reputation score in [0, 1000]
        uint64 attestedBlock; // block in which quorum verification passed
    }

    // ------------------------------------------------------------------
    // Storage
    // ------------------------------------------------------------------

    /// @notice The Parity AVS's ECDSAStakeRegistry proxy on this chain.
    IECDSAStakeRegistry public immutable stakeRegistry;

    /// @notice How many blocks an attestation remains usable for seeding.
    uint256 public freshnessBlocks;

    /// @notice Monotonic attestation nonce. Every accepted attestation must commit to
    ///         `nextNonce` and advances it, so an old message can never be re-delivered to
    ///         refresh its freshness timestamp or overwrite a newer score.
    uint256 public nextNonce;

    mapping(address subject => Attestation) internal attestations;

    // ------------------------------------------------------------------
    // Constants / errors / events
    // ------------------------------------------------------------------

    bytes4 internal constant ERC1271_VALID = 0x1626ba7e;
    bytes32 internal constant _ATTESTATION_DOMAIN = keccak256("PARITY_CROSS_POOL_V1");

    error InvalidScoreBounds();
    error ReferenceBlockInFuture();
    error InvalidNonce();
    error InvalidQuorumSignature();

    event ReputationAttested(address indexed subject, int256 score, uint32 indexed referenceBlock);
    event FreshnessUpdated(uint256 blocks);

    // ------------------------------------------------------------------
    // Construction / admin
    // ------------------------------------------------------------------

    constructor(IECDSAStakeRegistry _stakeRegistry, uint256 _freshnessBlocks, address initialOwner)
        Ownable(initialOwner)
    {
        stakeRegistry = _stakeRegistry;
        freshnessBlocks = _freshnessBlocks;
    }

    function setFreshnessBlocks(uint256 blocks_) external onlyOwner {
        freshnessBlocks = blocks_;
        emit FreshnessUpdated(blocks_);
    }

    // ------------------------------------------------------------------
    // Attestation intake (operator responses relayed permissionlessly)
    // ------------------------------------------------------------------

    /// @notice Records a quorum-signed cross-pool reputation score for `subject`.
    /// @param  subject        The address whose aggregated behavior the operators observed.
    /// @param  score          Aggregated score in [0, 1000].
    /// @param  referenceBlock Block whose operator weights/signing keys the signatures commit to.
    /// @param  nonce          Must equal the contract's current `nextNonce`; monotonically
    ///                        advances on acceptance, preventing replay and stale refresh.
    /// @param  operators      Signing operators, strictly ascending (mirrors StakeRegistry rules).
    /// @param  signatures     EIP-191 signatures over the domain-separated digest, aligned to
    ///                        `operators`.
    function attestReputation(
        address subject,
        int256 score,
        uint32 referenceBlock,
        uint256 nonce,
        address[] calldata operators,
        bytes[] calldata signatures
    ) external {
        if (score < 0 || score > 1000) revert InvalidScoreBounds();
        if (uint256(referenceBlock) > block.number) revert ReferenceBlockInFuture();
        if (nonce != nextNonce) revert InvalidNonce();
        nextNonce += 1;

        bytes32 digest = keccak256(
            abi.encode(_ATTESTATION_DOMAIN, block.chainid, address(this), subject, score, referenceBlock, nonce)
        );
        if (stakeRegistry.isValidSignature(digest, abi.encode(operators, signatures, referenceBlock)) != ERC1271_VALID)
        {
            revert InvalidQuorumSignature();
        }

        attestations[subject] = Attestation({score: score, attestedBlock: uint64(block.number)});
        emit ReputationAttested(subject, score, referenceBlock);
    }

    /// @dev Domain separator binding an attestation to this AVS instance, chain, subject,
    ///      score and reference block — signatures cannot be replayed elsewhere.
    function attestationDomain() external pure returns (bytes32) {
        return _ATTESTATION_DOMAIN;
    }

    // ------------------------------------------------------------------
    // Reads
    // ------------------------------------------------------------------

    /// @notice Latest attested score for `subject` if still fresh.
    /// @return fresh True when a quorum-attested score exists within `freshnessBlocks`.
    /// @return score The attested score (meaningless unless `fresh`).
    function freshScore(address subject) external view returns (bool fresh, int256 score) {
        Attestation storage a = attestations[subject];
        if (a.attestedBlock == 0) return (false, 0);
        unchecked {
            if (block.number - a.attestedBlock > freshnessBlocks) return (false, 0);
        }
        return (true, a.score);
    }

    function latestAttestation(address subject) external view returns (int256 score, uint64 attestedBlock) {
        Attestation storage a = attestations[subject];
        return (a.score, a.attestedBlock);
    }
}
