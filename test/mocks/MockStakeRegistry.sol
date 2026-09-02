// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Test double mirroring EigenLayer middleware's `ECDSAStakeRegistry.isValidSignature`
///         semantics: strictly ascending distinct operators, per-operator signing keys,
///         stake-weighted quorum measured against total registered weight at the reference
///         block (weights approximated by their current values — the real registry reads
///         checkpointed history).
contract MockStakeRegistry {
    bytes4 internal constant ERC1271_VALID = 0x1626ba7e;

    struct Operator {
        address signingKey;
        uint256 weight;
    }

    mapping(address operator => Operator) public operators;
    uint256 public totalWeight;

    /// @notice Required signed stake as basis points of `totalWeight`.
    uint256 public thresholdBps = 6667;

    error LengthMismatch();
    error UnsortedSigners();
    error UnknownOperator();
    error InvalidSignature();
    error InsufficientSignedStake();
    error ReferenceBlockInFuture();

    function setOperator(address op, address signingKey, uint256 weight) external {
        uint256 prev = operators[op].weight;
        totalWeight = totalWeight - prev + weight;
        operators[op] = Operator(signingKey, weight);
    }

    function setThresholdBps(uint256 bps) external {
        thresholdBps = bps;
    }

    function isValidSignature(bytes32 digest, bytes calldata signatureData) external view returns (bytes4) {
        (address[] memory ops, bytes[] memory sigs, uint32 referenceBlock) =
            abi.decode(signatureData, (address[], bytes[], uint32));

        if (ops.length == 0 || ops.length != sigs.length) revert LengthMismatch();
        if (uint256(referenceBlock) > block.number) revert ReferenceBlockInFuture();

        address last;
        uint256 signed;
        for (uint256 i; i < ops.length; ++i) {
            if (i > 0 && ops[i] <= last) revert UnsortedSigners();
            last = ops[i];

            Operator memory o = operators[ops[i]];
            if (o.weight == 0 || o.signingKey == address(0)) revert UnknownOperator();

            _verifyOne(digest, o.signingKey, sigs[i]);
            signed += o.weight;
        }

        if (signed * 1e4 < thresholdBps * totalWeight) revert InsufficientSignedStake();
        return ERC1271_VALID;
    }

    function _verifyOne(bytes32 digest, address signingKey, bytes memory sig) private pure {
        if (sig.length != 65) revert InvalidSignature();
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly ("memory-safe") {
            let data := add(sig, 32)
            r := mload(data)
            s := mload(add(data, 32))
            v := byte(0, mload(add(data, 64)))
        }
        address recovered = ecrecover(digest, v, r, s);
        if (recovered == address(0) || recovered != signingKey) revert InvalidSignature();
    }
}
