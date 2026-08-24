// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ParityTest} from "./Base.t.sol";
import {ParityHook} from "../src/ParityHook.sol";
import {LVRReserve} from "../src/LVRReserve.sol";
import {ReputationLedger} from "../src/ReputationLedger.sol";

/// @notice Full lifecycle: attack -> flag -> delay -> verify -> LP compensation,
///         contrasted with honest flows that never pay a premium.
contract EndToEndTest is ParityTest {
    address internal alice;
    address internal bob; // Neutral
    address internal mallory; // Flagged

    function setUp() public {
        _deployParity();
        _createPoolAndSeedLiquidity(100e18);
        vm.warp(10_000); // realistic timestamp (foundry starts at 1)
        aggregator.setUpdatedAt(block.timestamp); // keep the reference feed fresh
        alice = _makeSwapper(1);
        ledger.forceSetScore(alice, 800);
        bob = _makeSwapper(2);
        ledger.forceSetScore(bob, 500);
        mallory = _makeSwapper(3);
        ledger.forceSetScore(mallory, 100);
    }

    function _flaggedDelayExpected(address who) internal view returns (uint64) {
        return uint64(block.number + 1 + hook.flaggedExtraGapBlocks());
    }

    function test_honest_flow_never_pays_premium_or_enters_delay() public {
        assertEq(uint8(ledger.tierOf(alice)), uint8(ReputationLedger.Tier.Trusted));

        _swap(alice, true, 1e18);

        assertEq(reserve.pendingsLength(), 0, "trusted trades are never flagged");
        assertEq(currency0.balanceOf(address(reserve)), 0);
    }

    function test_attack_lifecycle_from_flag_to_lp_compensation() public {
        // 0) Baseline: LP holds everything, reserve is empty.
        uint256 lpBefore = currency0.balanceOf(address(this));
        assertEq(currency0.balanceOf(address(reserve)), 0);

        // 1) Attack swap: premium escrowed in the reserve (first swap is not delayed).
        _swap(mallory, true, 5e18);
        uint256 premium = (5e18 * uint256(hook.flaggedPremiumBps())) / 10_000;

        (, , uint256 recordedAmount, , , , , ) = reserve.getPending(0);
        assertEq(recordedAmount, premium, "premium recorded");
        assertEq(currency0.balanceOf(address(reserve)), premium, "premium escrowed");

        // 2) Same-block followup (the second sandwich leg) hits the delay window.
        vm.startPrank(mallory);
        vm.expectRevert();
        swapRouter.swapExactTokensForTokens(
            2e18, 0, true, poolKey, abi.encode(mallory), mallory, block.timestamp + 100
        );
        vm.stopPrank();

        // 3) Oracle stays live through the window; price keeps falling => toxic.
        uint32 verifyBlocks;
        (verifyBlocks,,,,) = reserve.config();
        vm.roll(block.number + verifyBlocks);

        // 4) Permissionless settlement confirms toxicity.
        assertTrue(reserve.settlePending(0), "toxic flow must verify");
        (, , uint256 settledAmount, , , , , ) = reserve.getPending(0);
        assertEq(settledAmount, 0, "pending record zeroed on settle");
        assertEq(reserve.payoutsLength(), 1);

        // 5) Anyone triggers distribution; LPs recover the damage pro-rata.
        (uint256 paid, bool complete) = reserve.distributeVerified(0, 50);
        assertTrue(complete);
        assertEq(paid, premium);
        assertEq(currency0.balanceOf(address(this)) - lpBefore, premium, "LP made whole");
        assertEq(currency0.balanceOf(address(reserve)), 0, "reserve fully drained");
        assertEq(reserve.totalVerifiedPaid(poolId), premium);
    }

    function test_neutral_swapper_is_delayed_but_never_charged() public {
        // First swap in this block passes freely and sets lastSwapBlock.
        _swap(bob, false, 1e18);

        // Second swap same block: delayed (Neutral gap = 1 block), no premium taken.
        vm.roll(block.number); // stay on the block for clarity
        _swapExpectingDelay(bob, 1e18, uint64(block.number + 1));

        assertEq(reserve.pendingsLength(), 0, "neutral tier pays nothing");
        assertEq(currency0.balanceOf(address(reserve)), 0);
    }

    function test_flagged_extra_gap_and_recovery_cycle() public {
        _swap(mallory, true, 1e18); // establishes lastSwapBlock + queues a premium
        assertEq(reserve.pendingsLength(), 1, "flagged exact-in pays a premium");

        // Flagged must wait one extra block beyond Neutral.
        _swapExpectingDelay(mallory, 1e18, _flaggedDelayExpected(mallory));

        // Honest activity over time rebuilds trust.
        ledger.forceSetScore(mallory, 800);
        ReputationLedger.Tier tier = ledger.tierOf(mallory);
        assertEq(uint8(tier), uint8(ReputationLedger.Tier.Trusted));

        // Trusted swaps skip both delay and premium paths even back-to-back.
        _swap(mallory, true, 1e18);
        assertEq(reserve.pendingsLength(), 1, "no new pending from trusted flow");
    }
}
