// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {ParityTest} from "./Base.t.sol";
import {LVRReserve} from "../src/LVRReserve.sol";
import {CctpBridge, ITokenMessengerV2} from "../src/circle/CctpBridge.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {MockTokenMessenger} from "./mocks/MockCctp.sol";

/// @notice Circle CCTP integration (doc §6 partner row): the reserve's idle USDC can be
///         burned toward another CCTP domain and swept back in on arrival, while premiums
///         escrowed for LVR verification are provably untouchable.
contract CircleCctpTest is ParityTest {
    MockERC20 usdc;
    MockTokenMessenger messenger;
    CctpBridge bridge;

    uint32 internal constant BASE_DOMAIN = 6; // Base mainnet CCTP domain
    uint256 internal constant RESERVE_SEED = 2_000e6;

    function setUp() public {
        _deployParity();
        _createPoolAndSeedLiquidity(100e18);

        usdc = new MockERC20("USD Coin", "USDC", 6);
        messenger = new MockTokenMessenger();
        bridge =
            new CctpBridge(IERC20Metadata(address(usdc)), reserve, ITokenMessengerV2(address(messenger)), address(this));
        reserve.setBridge(address(bridge));

        usdc.mint(address(reserve), RESERVE_SEED);
        usdc.mint(address(this), 100_000e6); // premium funding for escrow tests
    }

    /// @dev Books an escrowed premium against the reserve exactly as the hook would,
    ///      including transferring the premium in first (recordPremium assumes custody).
    function _bookEscrow(uint256 amount) internal {
        usdc.transfer(address(reserve), amount);
        vm.prank(address(hook));
        reserve.recordPremium(
            poolKey, Currency.wrap(address(usdc)), amount, Constants.SQRT_PRICE_1_1, true, 100e18
        );
    }

    // ------------------------------------------------------------------
    // Burn side: rebalancing idle USDC across domains
    // ------------------------------------------------------------------

    function test_rebalance_burns_idle_usdc_to_destination_domain() public {
        bridge.setDestinationDomain(BASE_DOMAIN, true);

        bridge.rebalance(1_500e6, BASE_DOMAIN);

        assertEq(usdc.balanceOf(address(messenger)), 1_500e6, "burn token must be custodied by the messenger");
        assertEq(usdc.balanceOf(address(reserve)), RESERVE_SEED - 1_500e6);

        (, uint32 dom, bytes32 recipient,,,,,) = messenger.burns(1);
        assertEq(uint256(dom), uint256(BASE_DOMAIN));
        assertEq(recipient, bytes32(uint256(uint160(address(bridge)))), "bridge is the mint recipient");
        assertEq(usdc.allowance(address(reserve), address(messenger)), 0, "allowance fully consumed by CCTP");
    }

    /// @notice Escrowed premiums are untouchable: the bridge may only move balances above
    ///     the escrow watermark, even though the raw balance is larger.
    function test_escrowed_premiums_are_protected_from_rebalance() public {
        bridge.setDestinationDomain(BASE_DOMAIN, true);
        _bookEscrow(4_000e6); // balance 6_000e6; escrowed 4_000e6; idle only 2_000e6

        vm.expectRevert(LVRReserve.InsufficientIdle.selector);
        bridge.rebalance(2_001e6, BASE_DOMAIN);

        bridge.rebalance(2_000e6, BASE_DOMAIN);
        assertEq(usdc.balanceOf(address(reserve)), 4_000e6, "exactly the escrow must remain");
        assertEq(reserve.escrowedBalance(Currency.wrap(address(usdc))), 4_000e6);
    }

    // ------------------------------------------------------------------
    // Mint side: sweeping arrived USDC back into the reserve
    // ------------------------------------------------------------------

    /// @dev Simulates the destination flow: relayers deliver Circle's attestation to the
    ///      MessageTransmitter on the other chain and minted USDC lands on that chain's
    ///      bridge; anyone then sweeps it into the local reserve.
    function test_sweep_forwards_minted_usdc_into_reserve() public {
        usdc.mint(address(bridge), 5_000e6); // as if Circle minted on arrival
        bridge.sweepMintedUsdc();

        assertEq(usdc.balanceOf(address(bridge)), 0);
        assertEq(usdc.balanceOf(address(reserve)), RESERVE_SEED + 5_000e6);

        bridge.sweepMintedUsdc(); // empty sweep is a no-op
        assertEq(usdc.balanceOf(address(reserve)), RESERVE_SEED + 5_000e6);
    }

    // ------------------------------------------------------------------
    // Guards
    // ------------------------------------------------------------------

    function test_rebalance_requires_allowed_destination_domain() public {
        vm.expectRevert(CctpBridge.DestinationNotAllowed.selector);
        bridge.rebalance(1e6, BASE_DOMAIN);

        bridge.setDestinationDomain(BASE_DOMAIN, true);
        bridge.rebalance(1e6, BASE_DOMAIN);

        bridge.setDestinationDomain(BASE_DOMAIN, false);
        vm.expectRevert(CctpBridge.DestinationNotAllowed.selector);
        bridge.rebalance(1e6, BASE_DOMAIN);
    }

    function test_only_bridge_and_owner_can_move_reserve_funds() public {
        address stranger = makeAddr("stranger");

        vm.prank(stranger);
        vm.expectRevert(LVRReserve.Unauthorized.selector);
        reserve.transferIdleToBridge(Currency.wrap(address(usdc)), 1e6);

        vm.prank(stranger);
        vm.expectRevert(); // OwnableUnauthorizedAccount
        bridge.rebalance(1e6, BASE_DOMAIN);
    }

    /// @notice Native ETH idle funds travel to the bridge recipient via a low-level call, not an
    ///     ERC20 `transfer` on address(0) — the transferIdleToBridge path must handle native
    ///     currency. CctpBridge itself bridges only USDC, so the native recipient is a bare
    ///     EOA (any receiver with a payable fallback).
    function test_transfer_idle_native_eth_to_bridge() public {
        address ethBridge = makeAddr("eth-bridge");
        reserve.setBridge(ethBridge);

        uint256 amount = 5 ether;
        vm.deal(address(reserve), amount);

        uint256 before = ethBridge.balance;
        vm.prank(ethBridge);
        reserve.transferIdleToBridge(Currency.wrap(address(0)), amount);

        assertEq(ethBridge.balance, before + amount, "recipient must receive the native ETH");
        assertEq(address(reserve).balance, 0, "reserve releases the idle balance");

        // The escrow watermark still applies to native currency.
        vm.deal(address(reserve), amount);
        vm.prank(address(hook));
        reserve.recordPremium(poolKey, Currency.wrap(address(0)), amount, Constants.SQRT_PRICE_1_1, true, 100e18);
        vm.prank(ethBridge);
        vm.expectRevert(LVRReserve.InsufficientIdle.selector);
        reserve.transferIdleToBridge(Currency.wrap(address(0)), 1);
    }
}
