// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ParityTest} from "./Base.t.sol";

import {LVRReserve} from "../src/LVRReserve.sol";
import {ReputationLedger} from "../src/ReputationLedger.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @notice The verification loop (doc §5): N-block window, Chainlink-referenced drift
///         comparison, verified → LP payout queue vs unverified → donation, oracle-failure
///         degradation, adaptive noise threshold training, and pro-rata compensation.
contract LVRVerificationTest is ParityTest {
    function setUp() public {
        _deployParity();
        _createPoolAndSeedLiquidity(100e18);
    }

    // ------------------------------------------------------------------
    // Window enforcement
    // ------------------------------------------------------------------

    function test_settle_reverts_before_window_elapses() public {
        address mallory = _makeSwapper(1);
        _flag(mallory, 100);
        _swap(mallory, true, 5e18);

        vm.expectRevert(LVRReserve.WindowNotElapsed.selector);
        reserve.settlePending(0);
    }

    function test_settle_unknown_index_and_double_settle_revert() public {
        vm.expectRevert(LVRReserve.UnknownPayout.selector);
        reserve.settlePending(0);

        address mallory = _makeSwapper(2);
        _flag(mallory, 100);
        _swap(mallory, true, 5e18);

        vm.roll(block.number + _verifyBlocks() + 1);
        assertTrue(reserve.settlePending(0));

        vm.expectRevert(LVRReserve.AlreadySettled.selector);
        reserve.settlePending(0);
    }

    function test_settlement_is_permissionless() public {
        address mallory = _makeSwapper(3);
        _flag(mallory, 100);
        _swap(mallory, true, 25e18);

        address keeper = makeAddr("keeper");
        vm.roll(block.number + _verifyBlocks());
        vm.prank(keeper); // neither owner nor hook — any observer can settle
        assertTrue(reserve.settlePending(0));
    }

    // ------------------------------------------------------------------
    // Verified path: toxic trade queues a payout for LPs
    // ------------------------------------------------------------------

    function test_verified_toxic_trade_queues_payout_for_lps() public {
        address mallory = _makeSwapper(4);
        _flag(mallory, 100);

        uint256 amountIn = 25e18;
        uint256 premium = (amountIn * hook.flaggedPremiumBps()) / 10_000;

        _swap(mallory, true, amountIn);
        assertEq(currency0.balanceOf(address(reserve)), premium);

        // Pool price collapsed far below the unchanged reference → harm confirmed.
        vm.roll(block.number + _verifyBlocks());
        assertTrue(reserve.settlePending(0), "large directional dump must verify");
        assertEq(reserve.pendingsLength(), 1);
        assertEq(reserve.payoutsLength(), 1);

        (PoolId poolId,, uint256 payoutAmount,,, bool complete) = reserve.getPayout(0);
        assertEq(PoolId.unwrap(poolId), PoolId.unwrap(poolIdOf()));
        assertEq(payoutAmount, premium);
        assertFalse(complete);

        // Single seeded LP owns all tracked liquidity → receives full compensation.
        uint256 lpBefore = currency0.balanceOf(address(this));
        (uint256 paid, bool done) = reserve.distributeVerified(0, 10);
        assertEq(paid, premium);
        assertTrue(done);
        assertEq(currency0.balanceOf(address(this)) - lpBefore, premium);
        assertEq(reserve.totalVerifiedPaid(poolIdOf()), premium);
    }

    // ------------------------------------------------------------------
    // Unverified path: natural volatility rolls premium into LP fees
    // ------------------------------------------------------------------

    function test_unverified_premium_donated_and_trains_noise_threshold() public {
        // Reference disagrees with pool at t0 by ~10% → large deviation0 absorbs drift.
        aggregator.setAnswer(9e7); // 0.90 in 8 decimals

        address mallory = _makeSwapper(5);
        _flag(mallory, 100);

        uint256 premium = (8e18 * uint256(hook.flaggedPremiumBps())) / 10_000;
        _swap(mallory, true, 8e18);

        vm.roll(block.number + _verifyBlocks());

        // Pool drifted but not beyond deviation0 + noise → unverified.
        assertFalse(reserve.settlePending(0));
        assertEq(reserve.totalUnverifiedDonated(poolIdOf()), premium);
        assertEq(currency0.balanceOf(address(reserve)), 0, "premium left the reserve");

        // EWMA trained by the observed drift: threshold rises above its floor.
        uint256 threshold = reserve.effectiveThresholdBps(poolIdOf());
        assertGt(threshold, _minNoiseBps(), "unverified outcomes must train the threshold");
    }

    function test_verified_events_do_not_inflate_threshold() public {
        address mallory = _makeSwapper(6);
        _flag(mallory, 100);
        _swap(mallory, true, 25e18);
        vm.roll(block.number + _verifyBlocks());
        assertTrue(reserve.settlePending(0));

        // Confirmed toxic events must NOT train the noise threshold upward.
        assertEq(
            reserve.effectiveThresholdBps(poolIdOf()),
            _minNoiseBps(),
            "verified outcome must leave threshold at floor"
        );
    }

    // ------------------------------------------------------------------
    // Oracle failure degrades gracefully — never bricks flagged flow
    // ------------------------------------------------------------------

    function test_oracle_dead_at_t0_marks_record_auto_unverifiable() public {
        // Foundry starts time at 1; establish a realistic clock first.
        vm.warp(10_000);

        // Stale feed at record time → refPriceT0 sentinel 0.
        aggregator.setUpdatedAt(block.timestamp - 3601);
        vm.warp(block.timestamp + 3601);

        address mallory = _makeSwapper(7);
        _flag(mallory, 100);
        _swap(mallory, true, 5e18); // must not revert despite dead oracle

        (,,,, uint256 refT0,,,) = reserve.getPending(0);
        assertEq(refT0, 0, "sentinel expected for dead oracle");

        // Revive the feed; settlement still takes the auto-unverified branch.
        aggregator.setUpdatedAt(block.timestamp);
        vm.roll(block.number + _verifyBlocks());

        uint256 donatedBefore = reserve.totalUnverifiedDonated(poolIdOf());
        assertFalse(reserve.settlePending(0));
        assertEq(reserve.totalUnverifiedDonated(poolIdOf()) - donatedBefore, (5e18 * uint256(hook.flaggedPremiumBps())) / 10_000);

        // Oracle-failure branch leaves the adaptive threshold untouched.
        assertEq(reserve.effectiveThresholdBps(poolIdOf()), _minNoiseBps());
    }

    function test_oracle_dying_between_t0_and_settle_degrades_gracefully() public {
        vm.warp(10_000); // realistic clock so staleness math stays positive
        address mallory = _makeSwapper(8);
        _flag(mallory, 100);
        _swap(mallory, true, 5e18);

        // Feed goes stale before the window closes.
        vm.warp(block.timestamp + 4000);
        vm.roll(block.number + _verifyBlocks() + 100);

        uint256 premium = 75_000_000_000_000_000; // 5e18 in at 150 bps
        assertFalse(reserve.settlePending(0), "stale oracle must degrade, not revert");
        assertEq(reserve.totalUnverifiedDonated(poolIdOf()), premium);
        assertEq(currency0.balanceOf(address(reserve)), 0);
    }

    // ------------------------------------------------------------------
    // Compensation distribution: batching, pro-rata, eligibility cutoff
    // ------------------------------------------------------------------

    function test_pro_rata_split_across_two_lps_with_batching() public {
        address lp2 = makeAddr("lp2");
        MockERC20(Currency.unwrap(currency0)).mint(lp2, 1_000_000e18);
        MockERC20(Currency.unwrap(currency1)).mint(lp2, 1_000_000e18);
        _addFullRangeLp(lp2, 100e18);
        assertEq(hook.lpCount(poolId), 2);

        address mallory = _makeSwapper(9);
        _flag(mallory, 100);

        uint256 premium = (20e18 * uint256(hook.flaggedPremiumBps())) / 10_000; // divisible by 2
        _swap(mallory, true, 20e18);

        vm.roll(block.number + _verifyBlocks());
        assertTrue(reserve.settlePending(0));

        // Batch of one: each call pays exactly one eligible LP their half.
        uint256 lp1Before = currency0.balanceOf(address(this));
        (uint256 paid1, bool complete) = reserve.distributeVerified(0, 1);
        assertEq(paid1, premium / 2);
        assertFalse(complete, "one LP remains");

        vm.prank(lp2);
        uint256 lp2Before = currency0.balanceOf(lp2);
        (uint256 paid2, bool done) = reserve.distributeVerified(0, 1);
        assertEq(paid2, premium / 2);
        assertTrue(done);
        assertEq(currency0.balanceOf(lp2) - lp2Before, paid2);

        assertEq(currency0.balanceOf(address(this)) - lp1Before, premium / 2);
        vm.expectRevert(LVRReserve.PayoutComplete.selector);
        reserve.distributeVerified(0, 10);
    }

    function test_lp_entering_after_the_attack_is_ineligible() public {
        address mallory = _makeSwapper(10);
        _flag(mallory, 100);
        _swap(mallory, true, 25e18); // affected block recorded here

        // LP joins after the harmful trade — free-rides nothing.
        address lateLp = makeAddr("late-lp");
        MockERC20(Currency.unwrap(currency0)).mint(lateLp, 1_000_000e18);
        MockERC20(Currency.unwrap(currency1)).mint(lateLp, 1_000_000e18);
        _addFullRangeLp(lateLp, 500e18);

        vm.roll(block.number + _verifyBlocks());
        assertTrue(reserve.settlePending(0));

        // Base is liquidity active AT the attack; late LP's huge position inflates
        // registry net only after the cutoff, so it is skipped entirely.
        uint256 premium = (25e18 * uint256(hook.flaggedPremiumBps())) / 10_000;
        uint256 earlyBefore = currency0.balanceOf(address(this));
        uint256 lateBefore = currency0.balanceOf(lateLp);
        (uint256 paid, bool done) = reserve.distributeVerified(0, 10);
        assertTrue(done);
        assertEq(currency0.balanceOf(lateLp) - lateBefore, 0, "post-attack LP must not be compensated");
        assertEq(currency0.balanceOf(address(this)) - earlyBefore, paid);
        assertEq(paid, premium, "full premium lands with the LP who bore the risk");
    }

    // ------------------------------------------------------------------
    // Governance
    // ------------------------------------------------------------------

    function test_only_owner_can_set_verify_config() public {
        LVRReserve.VerifyConfig memory cfg =
            LVRReserve.VerifyConfig({verifyBlocks: 10, minNoiseBps: 30, maxNoiseBps: 600, ewmaNum: 1, ewmaDen: 2});
        address rando = makeAddr("rando");
        vm.prank(rando);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, rando));
        reserve.setVerifyConfig(cfg);

        reserve.setVerifyConfig(cfg);
        (uint32 vb, uint256 mn,,,) = reserve.config();
        assertEq(vb, 10);
        assertEq(mn, 30);
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    function _flag(address who, int256 score) internal {
        ledger.forceSetScore(who, score);
        assertEq(uint8(ledger.tierOf(who)), uint8(ReputationLedger.Tier.Flagged));
    }

    function poolIdOf() internal view returns (PoolId) {
        return poolId;
    }

    function _verifyBlocks() internal view returns (uint32 v) {
        (v,,,,) = reserve.config();
    }

    function _minNoiseBps() internal view returns (uint256 m) {
        (, m,,,) = reserve.config();
    }
}
