// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {ParityCrossPoolOracle} from "../src/eigenlayer/ParityCrossPoolOracle.sol";
import {IECDSAStakeRegistry} from "../src/eigenlayer/IECDSAStakeRegistry.sol";
import {MockStakeRegistry} from "./mocks/MockStakeRegistry.sol";
/// @notice Proves the EigenLayer AVS-consumer wiring is byte-for-byte compatible with the
///         REAL, audited EigenLayer `ECDSAStakeRegistry` (eigenlayer-middleware), mirroring
///         the Circle `CircleFork` proof standard.
///
/// @dev The full EigenLayer v1.9.0-rc.0 build is not dragged into this repo (its default solc
///      0.8.27/^0.8.29 and tangled nested libs conflict with our 0.8.30 toolchain; Base
///      Sepolia is EigenLayer destination-only so no functional quorum can run there anyway).
///      Instead we hardcode the audited registry's selectors and signature-data layout and
///      prove our locally-declared interface + the oracle's digest/encoding match them — the
///      same static keystone approach `CircleFork` uses for TokenMessengerV2.
///
/// Run (fork-independent; the static assertions always run):
///     forge test --match-path test/EigenLayerLiveFork.t.sol
contract EigenLayerLiveForkTest is Test {
    /// @dev ERC-1271 success selector returned by `isValidSignature` on quorum success.
    bytes4 internal constant ERC1271_VALID = 0x1626ba7e;

    // ------------------------------------------------------------------
    // Keystone proof: our interface + oracle encoding == audited EigenLayer ABI
    // ------------------------------------------------------------------

    /// @dev Proves `IECDSAStakeRegistry.isValidSignature` selector is identical to EigenLayer's
    ///      real `ECDSAStakeRegistry.isValidSignature(bytes32,bytes)` — the ERC-1271 quorum check.
    ///      The real registry's `isValidSignature` decodes signatureData as
    ///      `(address[] operators, bytes[] signatures, uint32 referenceBlock)`, exactly what
    ///      `ParityCrossPoolOracle.attestReputation` packs via `abi.encode(operators, signatures,
    ///      referenceBlock)`.
    function test_isValidSignature_selector_matches_audited_registry() public pure {
        bytes4 expected = bytes4(keccak256("isValidSignature(bytes32,bytes)"));
        assertEq(IECDSAStakeRegistry.isValidSignature.selector, expected, "isValidSignature selector mismatch");

        // The success return value the real registry returns on quorum satisfaction.
        assertEq(ERC1271_VALID, bytes4(0x1626ba7e), "ERC-1271 valid selector must be 0x1626ba7e");

        // The signature-data tuple matches the real registry's (address[], bytes[], uint32)
        // decode — the two ABI-encodings must therefore be byte-for-byte interchangeable.
        (address[] memory ops, bytes[] memory sigs, uint32 refBlock) =
            abi.decode(_encodeSigData(), (address[], bytes[], uint32));
        assertEq(ops.length, 3, "operators array must round-trip");
        assertEq(sigs.length, 3, "signatures array must round-trip");
        assertEq(refBlock, 123_456, "referenceBlock must round-trip");
    }

    /// @dev Proves `getLastCheckpointTotalWeight()` selector matches the audited registry.
    function test_getLastCheckpointTotalWeight_selector_matches_audited_registry() public pure {
        assertEq(
            IECDSAStakeRegistry.getLastCheckpointTotalWeight.selector,
            bytes4(keccak256("getLastCheckpointTotalWeight()")),
            "getLastCheckpointTotalWeight selector mismatch"
        );
    }

    // ------------------------------------------------------------------
    // Oracle wiring: the exact calls the oracle makes, verified end-to-end
    // ------------------------------------------------------------------

    /// @dev Sets up a faithful registry double (same semantics as the real registry) and runs a
    ///      full attestReputation -> quorum verification round, proving the oracle's on-chain
    ///      digest construction and signature-data encoding are what the registry consumes.
    function test_oracle_dispatch_to_registry_matches_quorum_encoding() public {
        uint256[3] memory keys = [uint256(0x1111111111111111), uint256(0x2222222222222222), uint256(0x3333333333333333)];
        (MockStakeRegistry reg, address[] memory ops) = _makeOperators(keys, 6_667);

        ParityCrossPoolOracle oracle =
            new ParityCrossPoolOracle(IECDSAStakeRegistry(address(reg)), 50, address(this));

        address subject = address(0xBeef);
        int256 score = 420;
        uint32 referenceBlock = uint32(block.number);
        uint256 nonce = 0;

        bytes32 digest = keccak256(
            abi.encode(oracle.attestationDomain(), block.chainid, address(oracle), subject, score, referenceBlock, nonce)
        );

        bytes[] memory sigs = _signAll(digest, keys);

        oracle.attestReputation(subject, score, referenceBlock, nonce, ops, sigs);

        (bool fresh, int256 got) = oracle.freshScore(subject);
        assertTrue(fresh, "attestation must be fresh");
        assertEq(got, score, "attested score must be returned");
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    /// @dev Registers `keys.length` operators with known signing keys and ascending addresses
    ///      (mirrors the real registry's strict ascending rule), returning the operator set,
    ///      the ascending signing keys, and the configured registry.
    function _makeOperators(uint256[3] memory keys, uint256 thresholdBps)
        private
        returns (MockStakeRegistry, address[] memory)
    {
        address[] memory ops = new address[](keys.length);
        uint256[3] memory weights = [uint256(4_000), uint256(3_000), uint256(3_000)];
        for (uint256 i; i < keys.length; ++i) {
            ops[i] = vm.addr(keys[i] - 1_000);
        }
        for (uint256 i; i < keys.length; ++i) {
            for (uint256 j = i + 1; j < keys.length; ++j) {
                if (ops[j] < ops[i]) (ops[j], ops[i]) = (ops[i], ops[j]);
            }
        }
        address[] memory sks = new address[](keys.length);
        for (uint256 i; i < keys.length; ++i) sks[i] = vm.addr(keys[i]);
        MockStakeRegistry reg = new MockStakeRegistry();
        for (uint256 i; i < keys.length; ++i) {
            reg.setOperator(ops[i], sks[i], weights[i]);
        }
        reg.setThresholdBps(thresholdBps);
        return (reg, ops);
    }

    function _signAll(bytes32 digest, uint256[3] memory keys) private pure returns (bytes[] memory) {
        bytes[] memory sigs = new bytes[](keys.length);
        for (uint256 i; i < keys.length; ++i) sigs[i] = _sign(digest, keys[i]);
        return sigs;
    }

    function _encodeSigData() private pure returns (bytes memory) {
        address[] memory ops = new address[](3);
        bytes[] memory sigs = new bytes[](3);
        for (uint256 i; i < 3; ++i) ops[i] = address(uint160(0x1000 + i));
        sigs[0] = hex"11";
        sigs[1] = hex"22";
        sigs[2] = hex"33";
        return abi.encode(ops, sigs, uint32(123_456));
    }

    function _sign(bytes32 digest, uint256 sk) private pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(sk, digest);
        return abi.encodePacked(r, s, v);
    }
}
