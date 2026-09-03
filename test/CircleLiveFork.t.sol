// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {LVRReserve} from "../src/LVRReserve.sol";
import {CctpBridge, ITokenMessengerV2} from "../src/circle/CctpBridge.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/// @notice End-to-end fork proof against the LIVE Base Sepolia (chain 84532) deployment.
///         Proves the previously catastrophic `rebalance()` issue is fixed on-chain:
///         Base Sepolia's canonical `TokenMessengerV2` reverts its `getMinFeeAmount()` / `minFee()`
///         fee oracle (observed live), which would have reverted every old CctpBridge rebalance.
///         This test drives the DEPLOYED upgraded bridge (`0xc312…Ee6`) through a real
///         `rebalance()` (owner-pranked) against the REAL canonical messenger and confirms the
///         burn custodies USDC — i.e. the staticcall-with-fallback fee path succeeds on-chain.
///
/// Run (requires an RPC):
///     forge test --match-path test/CircleLiveFork.t.sol --fork-url <BASE_RPC>
/// Without a fork these assertions are skipped.
contract CircleLiveForkTest is Test {
    // ---- Live Base Sepolia (84532) deploy ---
    address internal constant PARITY_HOOK = 0x95E4a3Aa11c44EB8de369830E9f956703F5585cC;
    address internal constant LVR_RESERVE = 0x07fabE011c4BB617a12E33098258586fD066EcDF;
    address internal constant UPGRADED_BRIDGE = 0xc3127A26Bf8f21a58e4AA5b851C886Ad6CF00Ee6;
    address internal constant CHAINLINK_ADAPTER = 0x81e9bb58e41888E4c3f9b4523d4c62290F2AAa46;
    address internal constant OWNER = 0x664C1791ad9189ebAEB63716d29EeCaA405c732D;

    // ---- Canonical Base Sepolia CCTP + USDC ---
    address internal constant TOKEN_MESSENGER_V2 = 0x8FE6B999Dc680CcFDD5Bf7EB0974218be2542DAA;
    address internal constant USDC = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;

    uint32 internal constant ETH_DOMAIN = 0; // Ethereum Sepolia (a registered CCTP destination from Base)
    uint256 internal constant SEED = 1_000e6;

    LVRReserve reserve;
    CctpBridge bridge;
    IERC20Metadata usdc;

    function setUp() public {
        vm.skip(block.chainid == 31_337); // skip on plain Anvil (no fork)
        vm.skip(USDC.code.length == 0); // skip when not forked

        reserve = LVRReserve(LVR_RESERVE);
        bridge = CctpBridge(UPGRADED_BRIDGE);
        usdc = IERC20Metadata(USDC);
    }

    /// @dev The deployed bridge is wired to the reserve and the REAL canonical messenger, and
    ///      custody of USDC flows to the messenger on a real rebalance — proving the fee-oracle
    ///      revert no longer bricks cross-chain rebalancing.
    function test_live_rebalance_completes_despite_fee_oracle_revert() public {
        // 1. Confirm wiring.
        assertEq(address(reserve.bridge()), UPGRADED_BRIDGE, "reserve must point at the upgraded bridge");
        assertEq(address(bridge.reserve()), LVR_RESERVE);
        assertEq(address(bridge.tokenMessenger()), TOKEN_MESSENGER_V2, "bridge must target canonical messenger");
        assertEq(bridge.owner(), OWNER);

        // 2. The exact fault: Base Sepolia's canonical fee oracle reverts (would have bricked old rebalance).
        ITokenMessengerV2 tm = ITokenMessengerV2(TOKEN_MESSENGER_V2);
        vm.expectRevert();
        tm.getMinFeeAmount(SEED);

        // 3. Fund the reserve with USDC on the fork; no escrows => whole balance is idle.
        deal(USDC, LVR_RESERVE, SEED);
        assertEq(usdc.balanceOf(LVR_RESERVE), SEED);

        // 4. Owner drives the deployed bridge through a real rebalance toward a *different*
        //    CCTP domain (Ethereum Sepolia = 0; Base cannot burn to itself). The upgraded bridge
        //    staticcalls getMinFeeAmount (it reverts) and falls back to the owner-configured
        //    fraction instead of reverting.
        vm.prank(OWNER);
        bridge.rebalance(SEED, ETH_DOMAIN);

        // 5. CCTP burns (FiatToken burnFrom) rather than custodies, so the correct invariants
        //    are that the reserve released and the bridge spent the full amount on the burn.
        assertEq(usdc.balanceOf(LVR_RESERVE), 0, "reserve must release the idle USDC");
        assertEq(usdc.balanceOf(UPGRADED_BRIDGE), 0, "bridge must spend the full amount on the CCTP burn");
        assertEq(usdc.allowance(UPGRADED_BRIDGE, TOKEN_MESSENGER_V2), 0, "allowance fully consumed by CCTP");
    }
}
