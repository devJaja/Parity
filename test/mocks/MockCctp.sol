// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/// @notice Test double standing in for Circle's canonical CCTP `TokenMessengerV2`. Burns
///         (custodies) the burn token on deposit and emits the canonical V2 `DepositForBurn`
///         event, mirroring the production flow up to cross-chain attestation delivery.
///         Mirrors the V2 interface: no nonce is returned by `depositForBurn`; it is carried
///         in the emitted event.
contract MockTokenMessenger {
    struct Burn {
        uint256 amount;
        uint32 destinationDomain;
        bytes32 mintRecipient;
        address burnToken;
        address depositor;
        bytes32 destinationCaller;
        uint256 maxFee;
        uint32 minFinalityThreshold;
    }

    uint64 public nextNonce = 1;
    mapping(uint64 => Burn) public burns;

    uint256 public minFee = 1;

    event DepositForBurn(
        address indexed burnToken,
        uint256 amount,
        address indexed depositor,
        bytes32 mintRecipient,
        uint32 destinationDomain,
        bytes32 destinationTokenMessenger,
        bytes32 destinationCaller,
        uint256 maxFee,
        uint32 indexed minFinalityThreshold,
        bytes hookData
    );

    function depositForBurn(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken,
        bytes32 destinationCaller,
        uint256 maxFee,
        uint32 minFinalityThreshold
    ) external {
        require(amount > 0, "Amount must be nonzero");
        require(mintRecipient != bytes32(0), "mint recipient zero");
        require(maxFee < amount, "max fee >= amount");

        MockERC20(burnToken).transferFrom(msg.sender, address(this), amount);
        uint64 nonce = nextNonce++;
        burns[nonce] =
            Burn(amount, destinationDomain, mintRecipient, burnToken, msg.sender, destinationCaller, maxFee, minFinalityThreshold);
        emit DepositForBurn(
            burnToken, amount, msg.sender, mintRecipient, destinationDomain, bytes32(uint256(type(uint160).max)), destinationCaller,
            maxFee, minFinalityThreshold, ""
        );
    }

    /// @dev Mirrors `TokenMessengerV2.getMinFeeAmount`.
    function getMinFeeAmount(uint256) external view virtual returns (uint256) {
        return minFee;
    }
}

/// @notice `MockTokenMessenger` variant whose fee oracle (`getMinFeeAmount`) always reverts,
///         simulating CCTP v2 deployments that expose fee accessors through a storage layout
///         unreadable via `staticcall`. The bridge must fall back to a configured max-fee fraction
///         and still complete the burn instead of bricking the rebalance.
contract MockTokenMessengerRevertFee is MockTokenMessenger {
    function getMinFeeAmount(uint256) external pure override returns (uint256) {
        revert("fee oracle unavailable");
    }
}
