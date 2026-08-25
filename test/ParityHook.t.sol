// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ParityTest} from "./Base.t.sol";
import {EasyPosm} from "./utils/libraries/EasyPosm.sol";

import {ParityHook} from "../src/ParityHook.sol";
import {ReputationLedger} from "../src/ReputationLedger.sol";
import {LVRReserve} from "../src/LVRReserve.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/// @notice Tier treatment, sandwich atomicity break, premium routing and the LP registry,
///          exercised end-to-end through the real PoolManager + router stack.
contract ParityHookTest is ParityTest {
    using EasyPosm for IPositionManager;

    function setUp() public {
        _deployParity();
        _createPoolAndSeedLiquidity(100e18);
    }

    // ------------------------------------------------------------------
    // Deployment / permissions
    // ------------------------------------------------------------------

    function test_hook_permissions_match_flags() public view {
        assertTrue(hook.poolManager() == poolManager);
        assertTrue(address(hook.reserve()) == address(reserve));
        assertTrue(address(reserve.hook()) == address(hook));
    }

    // ------------------------------------------------------------------
    // Trusted tier — instant execution, no premium, no delay
    // ------------------------------------------------------------------

    function test_trusted_flow_no_delay_no_premium() public {
        address alice = _makeSwapper(1);
        vm.startPrank(address(this)); // owner
        ledger.forceSetScore(alice, 800); // Trusted
        vm.stopPrank();

        uint256 reserveBefore = currency0.balanceOf(address(reserve));

        // Two swaps in the SAME block: allowed for trusted flow.
        _swap(alice, true, 1e17);
        _swap(alice, false, 1e16);

        assertEq(currency0.balanceOf(address(reserve)), reserveBefore, "trusted flow pays no premium");
    }

    // ------------------------------------------------------------------
    // Neutral tier — ordering delay only
    // ------------------------------------------------------------------

    function test_neutral_same_block_reswap_reverts_then_allowed_next_block() public {
        address bob = _makeSwapper(2);

        _swap(bob, true, 1e17);
        assertEq(uint8(ledger.tierOf(bob)), uint8(ReputationLedger.Tier.Neutral));

        // Same-block re-entry is exactly what an atomic sandwich needs — blocked.
        _swapExpectingDelay(bob, 5e16, ledger.lastSwapBlock(bob) + 1);

        // Next block: allowed.
        vm.roll(block.number + 1);
        _swap(bob, false, 5e16);
    }

    function test_neutral_flow_pays_no_premium() public {
        address bob = _makeSwapper(2);
        uint256 reserveBefore = currency0.balanceOf(address(reserve));
        _swap(bob, true, 1e17);
        assertEq(currency0.balanceOf(address(reserve)) - reserveBefore, 0, "neutral flow pays no premium");
    }

    // ------------------------------------------------------------------
    // Flagged tier — delay + premium routed to the LVR Reserve
    // ------------------------------------------------------------------

    function _flag(address who, int256 score) internal {
        vm.prank(address(this));
        ledger.forceSetScore(who, score);
        assertEq(uint8(ledger.tierOf(who)), uint8(ReputationLedger.Tier.Flagged));
    }

    function test_flagged_exact_input_pays_premium_to_reserve() public {
        address mallory = _makeSwapper(3);
        _flag(mallory, 100);

        uint256 amountIn = 10e18;
        uint256 expectedPremium = (amountIn * hook.flaggedPremiumBps()) / 10_000; // 150 bps

        uint256 reserveBefore = currency0.balanceOf(address(reserve));

        // First flagged swap ever: lastSwapBlock == 0 → no delay gate applies yet.
        _swap(mallory, true, amountIn);

        assertEq(currency0.balanceOf(address(reserve)) - reserveBefore, expectedPremium, "premium must land in reserve");
        assertEq(reserve.pendingsLength(), 1, "premium queued for verification");

        (
            , Currency premiumCurrency, uint256 amount,, , bool zfo, uint128 liqAtBlock, uint64 recordedBlock
        ) = reserve.getPending(0);
        assertTrue(premiumCurrency == currency0);
        assertEq(amount, expectedPremium);
        assertFalse(zfo == false, "direction recorded"); // zeroForOne == true
        assertTrue(liqAtBlock > 0, "liquidity snapshot captured");
        assertEq(recordedBlock, block.number);
    }

    function test_flagged_extra_delay_gap_enforced() public {
        address mallory = _makeSwapper(4);
        _flag(mallory, 100);

        _swap(mallory, true, 1e18); // sets lastSwapBlock

        // One block later: still inside the flagged window (needs extra gap).
        vm.roll(block.number + 1);
        _swapExpectingDelay(mallory, 1e18, ledger.lastSwapBlock(mallory) + 1 + hook.flaggedExtraGapBlocks());

        // Two blocks later: passes.
        vm.roll(block.number + 2);
        _swap(mallory, false, 1e17);
    }

    function test_flagged_exact_output_premium_taken_on_input_side() public {
        address mallory = _makeSwapper(5);
        _flag(mallory, 100);

        uint256 reserveBefore = currency0.balanceOf(address(reserve));

        // Exact-OUTPUT buy of token1: input is currency0; premium charged on realized input.
        BalanceDelta delta = _swapExactOut(mallory, true, 1e17);

        // The router settles raw input + premium, so the charged amount is the
        // gross figure: premium = charged * bps / (10_000 + bps).
        uint256 charged = uint256(uint128(-delta.amount0()));
        uint256 expectedPremium = (charged * hook.flaggedPremiumBps()) / (10_000 + hook.flaggedPremiumBps());

        assertEq(
            currency0.balanceOf(address(reserve)) - reserveBefore,
            expectedPremium,
            "exact-output premium must equal bps share of realized input"
        );
        assertEq(reserve.pendingsLength(), 1, "premium queued for verification");
    }

    // ------------------------------------------------------------------
    // Sandwich atomicity — the core protective property
    // ------------------------------------------------------------------

    function test_atomic_sandwich_impossible_for_neutral_attacker() public {
        address attacker = _makeSwapper(6);
        address victim = _makeSwapper(7);

        // Setup leg in block N.
        _swap(attacker, true, 5e18); // large relative to pool → big impact penalty too
        uint256 attackerBlock = block.number;

        // Attack leg MUST be same-block for a classical sandwich — it reverts instead.
        _swapExpectingDelay(attacker, 4e18, ledger.lastSwapBlock(attacker) + 1);

        // Victim trades in between (different block).
        vm.roll(attackerBlock + 1);
        _swap(victim, true, 1e18);

        // Teardown now lands on a moved pool — the extraction window is gone.
        _swap(attacker, false, 4e18);
        assertTrue(ledger.scoreOf(attacker) < 500, "extractive pattern must degrade reputation");
    }

    // ------------------------------------------------------------------
    // Reputation naturally reaches Flagged through repeated extraction
    // ------------------------------------------------------------------

    function test_repeated_extraction_drives_tier_to_flagged() public {
        address grifter = _makeSwapper(8);

        ReputationLedger.Tier t0 = ledger.tierOf(grifter);
        assertTrue(t0 == ReputationLedger.Tier.Neutral);

        // Alternate-direction churn with heavy impact every other block.
        for (uint64 i = 0; i < 6; ++i) {
            if (i > 0) vm.roll(block.number + hook.flaggedExtraGapBlocks() + 1);
            _swap(grifter, i % 2 == 0, 20e18);
        }

        assertTrue(
            uint8(ledger.tierOf(grifter)) < uint8(ReputationLedger.Tier.Neutral),
            "sustained churn must reach Flagged"
        );
    }

    // ------------------------------------------------------------------
    // LP registry
    // ------------------------------------------------------------------

    function test_lp_registry_tracks_seeded_position() public view {
        assertEq(hook.lpCount(poolId), 1);
        assertEq(hook.lpAt(poolId, 0), address(this));
        assertTrue(hook.lpNet(poolId, address(this)) > 0);
        assertEq(hook.lpLastChangeBlock(poolId, address(this)), block.number);
    }

    function test_lp_registry_tracks_second_provider_and_removal() public {
        address lp2 = makeAddr("second-lp");
        MockERC20(Currency.unwrap(currency0)).mint(lp2, 1000e18);
        MockERC20(Currency.unwrap(currency1)).mint(lp2, 1000e18);
        vm.startPrank(lp2);
        MockERC20(Currency.unwrap(currency0)).approve(address(permit2), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(permit2), type(uint256).max);
        permit2.approve(Currency.unwrap(currency0), address(positionManager), type(uint160).max, type(uint48).max);
        permit2.approve(Currency.unwrap(currency1), address(positionManager), type(uint160).max, type(uint48).max);
        vm.stopPrank();

        int24 tickLower = -60;
        int24 tickUpper = 60;

        vm.startPrank(lp2, lp2);
        (uint256 tokenId,) = positionManager.mint(
            poolKey,
            tickLower,
            tickUpper,
            1e18,
            type(uint256).max,
            type(uint256).max,
            lp2,
            block.timestamp,
            abi.encode(lp2)
        );
        vm.stopPrank();

        assertEq(hook.lpCount(poolId), 2);
        assertEq(hook.lpAt(poolId, 1), lp2);
        uint256 netBefore = hook.lpNet(poolId, lp2);
        assertTrue(netBefore > 0);

        vm.startPrank(lp2, lp2);
        positionManager.decreaseLiquidity(tokenId, netBefore / 2, 0, 0, lp2, block.timestamp, abi.encode(lp2));
        vm.stopPrank();
        assertApproxEqRel(hook.lpNet(poolId, lp2), netBefore / 2, 0.01e18);
    }
}
