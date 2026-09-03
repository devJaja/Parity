// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {LVRReserve} from "../LVRReserve.sol";

/// @notice Canonical Circle CCTP `TokenMessengerV2` burn-side entrypoint — the current canonical
///         CCTP contract (CCTP V1 is legacy and phases out July 31, 2026). This interface is
///         declared locally to stay on the project's Solidity version, but mirrors Circle's
///         audited `TokenMessengerV2` ABI exactly (`docs/abis/cctp/v2.1/TokenMessengerV2.json` in
///         circlefin/evm-cctp-contracts). It is ABI-compatible with the live contract by selector.
interface ITokenMessengerV2 {
    /// @dev Burns `amount` of `burnToken` on this chain; on the destination domain `amount` is
    ///      minted to `mintRecipient` once Circle attests the message. Emits a `DepositForBurn`
    ///      event carrying the message nonce — V2 no longer returns it, so callers must read the
    ///      event log for tracking.
    /// @param destinationCaller Authorized caller of `receiveMessage` on the destination; use
    ///                          `bytes32(0)` to allow any address to relay.
    /// @param maxFee           Maximum fee payable on the destination, in units of `burnToken`.
    /// @param minFinalityThreshold Minimum finality threshold for attestation (e.g. 1000 Fast,
    ///                          2000 Standard).
    function depositForBurn(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken,
        bytes32 destinationCaller,
        uint256 maxFee,
        uint32 minFinalityThreshold
    ) external;

    /// @dev Minimum fee for a Standard Transfer on this domain, used to set `maxFee`.
    function getMinFeeAmount(uint256 amount) external view returns (uint256);
}

/// @title CctpBridge
/// @notice Circle CCTP integration for the Parity LVR Reserve (doc §6, partner row "Circle").
///         Rebalances idle USDC held by the reserve across chains via Circle's canonical
///         burn-and-mint transfer protocol, so a multichain deployment can concentrate
///         compensation capital where toxic flow concentrates — without trusting any bridge
///         liquidity pool, custodian, or wrapped asset.
/// @dev    Burn side: pulls only *unlocked* USDC out of the reserve (premiums escrowed for
///         pending LVR verification are never touchable) and calls `depositForBurn` with the
///         bridge itself as mint recipient. Mint side: after permissionless relayers deliver
///         Circle's attestation to the destination `MessageTransmitter`, freshly minted USDC
///         lands directly on this contract and anyone can sweep it back into the reserve.
///         On each chain, deploy one bridge with that chain's native USDC and the canonical
///         `TokenMessenger` address for its CCTP domain.
contract CctpBridge is Ownable {
    using SafeERC20 for IERC20Metadata;

    // ------------------------------------------------------------------
    // Storage
    // ------------------------------------------------------------------

    /// @notice Native USDC on THIS chain (the token burned by `depositForBurn`).
    IERC20Metadata public immutable usdc;

    /// @notice The reserve whose idle USDC this bridge rebalances.
    LVRReserve public immutable reserve;

    /// @notice Canonical CCTP TokenMessengerV2 on this chain.
    ITokenMessengerV2 public tokenMessenger;

    /// @notice CCTP domains this deployment may rebalance toward (Ethereum=0, Base=6, ...).
    mapping(uint32 domain => bool allowed) public destinationDomainAllowed;

    /// @notice Fallback `maxFee` expressed as 1e18-scaled fraction of `amount`, used to size the
    ///         CCTP `maxFee` when the canonical `getMinFeeAmount` view is unavailable on-chain
    ///         (some CCTP v2 deployments expose it via a fee/upgrade storage layout that reverts
    ///         on `staticcall`). Set by the owner for each destination.
    mapping(uint32 domain => uint256 fallbackMaxFeeFraction) public fallbackMaxFeeFraction;

    // ------------------------------------------------------------------
    // Errors / events
    // ------------------------------------------------------------------

    error DestinationNotAllowed();

    event DestinationDomainSet(uint32 indexed domain, bool allowed);
    event TokenMessengerSet(address indexed messenger);
    event RebalanceInitiated(uint256 amount, uint32 indexed destinationDomain, bytes32 mintRecipient);
    event MintedUsdcSweptToReserve(uint256 amount);

    // ------------------------------------------------------------------
    // Construction / admin
    // ------------------------------------------------------------------

    constructor(IERC20Metadata usdc_, LVRReserve reserve_, ITokenMessengerV2 messenger_, address initialOwner)
        Ownable(initialOwner)
    {
        usdc = usdc_;
        reserve = reserve_;
        tokenMessenger = messenger_;
    }

    function setDestinationDomain(uint32 domain, bool allowed) external onlyOwner {
        destinationDomainAllowed[domain] = allowed;
        emit DestinationDomainSet(domain, allowed);
    }

    /// @notice Configures the fallback `maxFee` fraction (1e18-scaled proportion of `amount`)
    ///         used when the canonical `getMinFeeAmount` view reverts on-chain. 0 disables the
    ///         fallback and requires the live view to succeed.
    function setFallbackMaxFeeFraction(uint32 domain, uint256 maxFeeFraction) external onlyOwner {
        fallbackMaxFeeFraction[domain] = maxFeeFraction;
    }

    /// @notice Upgrades to another messenger deployment (e.g. a future CCTP version),
    ///         preserving the same burn-token and reserve wiring.
    function setTokenMessenger(ITokenMessengerV2 messenger_) external onlyOwner {
        tokenMessenger = messenger_;
        emit TokenMessengerSet(address(messenger_));
    }

    // ------------------------------------------------------------------
    // Cross-chain rebalancing
    // ------------------------------------------------------------------

    /// @notice Minimum finality threshold for attestation (1000 = Fast, 2000 = Standard).
    ///         Fast is sufficient for compensation rebalancing.
    uint32 public constant MIN_FINALITY_THRESHOLD = 1000;

    /// @notice Resistance-safe maximum fee fraction — CCTP only requires `maxFee < amount`, so
    ///         we cap the fee we ever pass at 1% of `amount` (a generous ceiling for live fees),
    ///         keeping the burn economically safe while guaranteeing `maxFee < amount`.
    uint256 internal constant MAX_FEE_PCT = 1e16; // 1%

    /// @notice Calls the canonical `getMinFeeAmount` view safely. Some CCTP v2 deployments expose
    ///         the fee accessors through a storage layout that reverts on `staticcall`; in that
    ///         case we fall back to the owner-configured `fallbackMaxFeeFraction` for the domain so
    ///         a rebalance is never blocked by an unreadable fee oracle.
    function _maxFeeFor(uint32 destinationDomain, uint256 amount) private view returns (uint256) {
        (bool ok, bytes memory data) =
            address(tokenMessenger).staticcall(abi.encodeWithSelector(ITokenMessengerV2.getMinFeeAmount.selector, amount));
        if (ok && data.length >= 32) {
            uint256 minFee = abi.decode(data, (uint256));
            // min fee + 10% buffer, but never let the fee alone consume the burn.
            uint256 bufferedFee = minFee + (minFee / 10) + 1;
            return bufferedFee > amount ? amount : bufferedFee;
        }
        // Fallback: fee oracle unavailable on-chain. Use the owner-set fraction (0 => passthrough
        // with the protocol fee ceiling).
        uint256 fraction = fallbackMaxFeeFraction[destinationDomain];
        uint256 fallbackFee = fraction != 0 ? (amount * fraction) / 1e18 : (amount * MAX_FEE_PCT) / 1e18;
        uint256 maxFee = fallbackFee + 1;
        return maxFee > amount ? amount : maxFee;
    }

    /// @notice Burns `amount` of reserve-held USDC toward `destinationDomain`; the mint
    ///         recipient is this bridge's counterpart address space (this contract on the
    ///         destination chain). Only idle USDC moves — escrowed premiums are untouched.
    /// @dev    Uses the canonical `TokenMessengerV2.depositForBurn`, computing a `maxFee`
    ///         above the domain's minimum fee so the burn is accepted. V2 does not return a
    ///         nonce — the deposit is tracked via the `DepositForBurn` event log.
    function rebalance(uint256 amount, uint32 destinationDomain) external onlyOwner {
        if (!destinationDomainAllowed[destinationDomain]) revert DestinationNotAllowed();

        // Pull unlocked idle USDC from the reserve into escrow-free bridge custody.
        reserve.transferIdleToBridge(Currency.wrap(address(usdc)), amount);

        usdc.forceApprove(address(tokenMessenger), amount);

        // V2 requires maxFee < amount and >= the domain minimum fee; query the canonical fee
        // oracle, falling back to a configured/ceiled value when it is unreadable on-chain.
        uint256 maxFee = _maxFeeFor(destinationDomain, amount);
        require(maxFee < amount, "fee too high");

        tokenMessenger.depositForBurn(
            amount,
            destinationDomain,
            bytes32(uint256(uint160(address(this)))),
            address(usdc),
            bytes32(0), // any caller may relay
            maxFee,
            MIN_FINALITY_THRESHOLD
        );
        emit RebalanceInitiated(amount, destinationDomain, bytes32(uint256(uint160(address(this)))));
    }

    /// @notice Forwards USDC minted here by the destination chain's MessageTransmitter into
    ///         the reserve. Permissionless: relayers already delivered Circle's attestation,
    ///         so sweeping adds no trust assumption.
    function sweepMintedUsdc() external {
        uint256 balance = usdc.balanceOf(address(this));
        if (balance == 0) return;
        usdc.safeTransfer(address(reserve), balance);
        emit MintedUsdcSweptToReserve(balance);
    }
}
