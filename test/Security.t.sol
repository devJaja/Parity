// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ParityTest} from "./Base.t.sol";
import {ReputationLedger} from "../src/ReputationLedger.sol";
import {EasyPosm} from "./utils/libraries/EasyPosm.sol";

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

/// @notice Regression coverage for implementation-hardening fixes:
///         1) hookData identity claims are corroborated (tx.origin or an authorized
///            router) before any reputation state or tier treatment is applied;
///         2) LVR verification normalizes pool prices across token decimal pairs, so
///            mixed-decimal pools classify drift identically to 18/18 pools.
contract IdentitySpoofTest is ParityTest {
    function setUp() public {
        _deployParity();
        _createPoolAndSeedLiquidity(100e18);
    }

    // ------------------------------------------------------------------
    // Identity: uncorroborated hookData claims must be discarded
    // ------------------------------------------------------------------

    /// @dev A fresh Neutral attacker cannot inherit a Trusted victim's tier by naming them
    ///      in hookData: tx.origin != victim and the router is unauthorized, so the claim
    ///      is discarded and flow resolves to the calling router. The victim's ledger
    ///      state stays untouched, and treatment was NOT Trusted — an immediate re-swap
    ///      hits the delay gate under the router's own identity.
    function test_impersonated_hookdata_claim_is_discarded() public {
        address victim = _makeSwapper(1);
        ledger.forceSetScore(victim, 800);
        assertEq(uint8(ledger.tierOf(victim)), uint8(ReputationLedger.Tier.Trusted));

        address attacker = _makeSwapper(2); // fresh -> Neutral

        vm.startPrank(attacker, attacker); // tx.origin == attacker != victim; router unauthorized
        swapRouter.swapExactTokensForTokens({
            amountIn: 1e18,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: abi.encode(victim), // spoofed identity claim
            receiver: attacker,
            deadline: block.timestamp + 100
        });
        vm.stopPrank();

        assertEq(ledger.scoreOf(victim), 800, "victim score untouched");
        assertEq(ledger.lastSwapBlock(victim), 0, "victim ledger untouched");
        assertTrue(
            ledger.lastSwapBlock(address(swapRouter)) != 0, "uncorroborated flow resolved to the router identity"
        );

        // The router's own identity (Neutral) is subject to the ordering delay.
        _swapExpectingDelay(address(swapRouter), 1e18, uint64(block.number + 1));
    }

    /// @dev An authorized router's attestation IS honored even when the transaction origin
    ///      differs from the claimed user — the smart-wallet path. Trusted treatment skips
    ///      the delay gate, and reputation updates land on the attested user only.
    function test_authorized_router_attestation_is_honored() public {
        hook.setRouterAuthorization(address(swapRouter), true);

        address user = _makeSwapper(3);
        ledger.forceSetScore(user, 800); // Trusted
        address unrelatedOrigin = makeAddr("unrelated-origin");

        for (uint256 i; i < 2; ++i) {
            vm.startPrank(user, unrelatedOrigin);
            swapRouter.swapExactTokensForTokens({
                amountIn: 1e18,
                amountOutMin: 0,
                zeroForOne: true,
                poolKey: poolKey,
                hookData: abi.encode(user),
                receiver: user,
                deadline: block.timestamp + 100
            });
            vm.stopPrank();
        }

        assertEq(ledger.lastSwapBlock(user), block.number, "attested identity recorded");
        assertEq(ledger.lastSwapBlock(unrelatedOrigin), 0);
        assertEq(ledger.lastSwapBlock(address(swapRouter)), 0, "router identity bypassed when attesting");
    }

    /// @dev Only governance can grant attestation rights.
    function test_only_owner_can_authorize_routers() public {
        address rando = makeAddr("rando");
        vm.prank(rando);
        vm.expectRevert();
        hook.setRouterAuthorization(address(swapRouter), true);

        assertFalse(hook.isAuthorizedRouter(address(swapRouter)));
    }
}

/// @notice Mixed-decimals verification: the reserve scales raw pool prices by
///         10^(dec0-dec1) before comparing against the Chainlink reference, so a pool
///         with skewed token decimals classifies drift identically to an 18/18 pool.
///         Without normalization, deviation0 absorbs a fixed 100x unit error and no
///         realistic drift would ever verify (or everything would, depending on sign).
contract DecimalNormalizationTest is ParityTest {
    using EasyPosm for IPositionManager;
    using StateLibrary for IPoolManager;

    function setUp() public {
        _deployParity();
    }

    /// @param wethIsCurrency0 Exercises both scale directions:
    ///         true  -> dec0=18, dec1=16, H=100   (scaleNum = 10^2)
    ///         false -> dec0=16, dec1=18, H=0.01  (scaleDen = 10^2)
    ///         Both arrangements place the RAW pool price at exactly 1.0, so all pool
    ///         mechanics match the standard fixture while the human-price comparison
    ///         still crosses the decimal-scaling code path.
    function test_mixed_decimals_pool_verifies_like_unit_pool(bool wethIsCurrency0) public {
        MockERC20 weth = new MockERC20("Wrapped Ether", "WETH", 18);
        MockERC20 low = new MockERC20("Low Decimals Token", "LDT", 16);

        currency0 = Currency.wrap(wethIsCurrency0 ? address(weth) : address(low));
        currency1 = Currency.wrap(wethIsCurrency0 ? address(low) : address(weth));
        if (Currency.unwrap(currency0) > Currency.unwrap(currency1)) {
            (currency0, currency1) = (currency1, currency0);
        }

        // Choose the reference so the RAW pool price is exactly 1.0 regardless of which
        // token the address-sort placed first: H = 10^(dec0-dec1).
        uint256 d0 = MockERC20(Currency.unwrap(currency0)).decimals();
        uint256 d1 = MockERC20(Currency.unwrap(currency1)).decimals();
        uint256 hNum = d0 >= d1 ? 10 ** (d0 - d1) : 1;
        uint256 hDen = d0 >= d1 ? 1 : 10 ** (d1 - d0);

        // Feed quotes token1-per-token0 in human units (8dp like real feeds).
        aggregator.setAnswer(int256(100e8 * hNum / hDen));

        _initMixedDecimalsPool();

        // Sanity: the pool trades AT the reference in human units.
        assertApproxEqRel(_poolHumanPrice18(), 1e18 * hNum / hDen, 1e14);

        // Toxic dump of currency0 collapses the human price below the static reference.
        address mallory = _makeSwapper(4);
        _flag(mallory, 100);

        uint256 amountIn = 20e18;
        uint256 premium = (amountIn * uint256(hook.flaggedPremiumBps())) / 10_000;
        _swap(mallory, true, amountIn);
        assertEq(currency0.balanceOf(address(reserve)), premium, "premium escrowed");

        vm.roll(block.number + _verifyBlocks());
        assertTrue(reserve.settlePending(0), "must verify despite decimal skew");

        uint256 lpBefore = currency0.balanceOf(address(this));
        (uint256 paid,) = reserve.distributeVerified(0, 10);
        assertEq(paid, premium, "LP compensated in full");
        assertEq(currency0.balanceOf(address(this)) - lpBefore, premium);
    }

    /// @dev Unverified path must also behave identically: a small trade whose drift stays
    ///      inside deviation0 + noise donates the premium instead of paying it out.
    function test_mixed_decimals_small_drift_stays_unverified(bool wethIsCurrency0) public {
        MockERC20 weth = new MockERC20("Wrapped Ether", "WETH", 18);
        MockERC20 low = new MockERC20("Low Decimals Token", "LDT", 16);

        currency0 = Currency.wrap(wethIsCurrency0 ? address(weth) : address(low));
        currency1 = Currency.wrap(wethIsCurrency0 ? address(low) : address(weth));
        if (Currency.unwrap(currency0) > Currency.unwrap(currency1)) {
            (currency0, currency1) = (currency1, currency0);
        }

        // Reference disagrees slightly with the pool at t0 (~1%): deviation0 ~100 bps
        // absorbs the sub-noise drift of a small swap, exactly like the 18/18 tests.
        uint256 d0 = MockERC20(Currency.unwrap(currency0)).decimals();
        uint256 d1 = MockERC20(Currency.unwrap(currency1)).decimals();
        uint256 hNum = d0 >= d1 ? 10 ** (d0 - d1) : 1;
        uint256 hDen = d0 >= d1 ? 1 : 10 ** (d1 - d0);
        aggregator.setAnswer(int256(99e8 * hNum / hDen));

        _initMixedDecimalsPool();

        address mallory = _makeSwapper(5);
        _flag(mallory, 100);

        uint256 premium = (2e18 * uint256(hook.flaggedPremiumBps())) / 10_000;
        _swap(mallory, true, 2e18);

        vm.roll(block.number + _verifyBlocks());
        assertFalse(reserve.settlePending(0), "small drift must stay unverified");
        assertEq(reserve.totalUnverifiedDonated(poolId), premium);
        assertEq(reserve.payoutsLength(), 0);
    }

    // ------------------------------------------------------------------
    // Fixture plumbing
    // ------------------------------------------------------------------

    function _initMixedDecimalsPool() internal {
        poolKey = PoolKey(currency0, currency1, 3000, 60, IHooks(hook));
        poolId = poolKey.toId();
        poolManager.initialize(poolKey, Constants.SQRT_PRICE_1_1);

        int24 lower = TickMath.minUsableTick(poolKey.tickSpacing);
        int24 upper = TickMath.maxUsableTick(poolKey.tickSpacing);
        (uint256 amt0, uint256 amt1) = LiquidityAmounts.getAmountsForLiquidity(
            Constants.SQRT_PRICE_1_1, TickMath.getSqrtPriceAtTick(lower), TickMath.getSqrtPriceAtTick(upper), 100e18
        );

        MockERC20(Currency.unwrap(currency0)).mint(address(this), amt0 + 1);
        MockERC20(Currency.unwrap(currency1)).mint(address(this), amt1 + 1);
        MockERC20(Currency.unwrap(currency0)).approve(address(permit2), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(permit2), type(uint256).max);
        permit2.approve(Currency.unwrap(currency0), address(positionManager), type(uint160).max, type(uint48).max);
        permit2.approve(Currency.unwrap(currency1), address(positionManager), type(uint160).max, type(uint48).max);

        positionManager.mint(
            poolKey, lower, upper, 100e18, amt0 + 1, amt1 + 1, address(this), block.timestamp, abi.encode(address(this))
        );
    }

    /// @dev Mirrors the reserve's scaled conversion so the test asserts on the same
    ///      units the verification actually uses: raw price * 10^(dec0-dec1), 18dp.
    function _poolHumanPrice18() internal view returns (uint256 p) {
        (uint160 sqrtNow, , , ) = poolManager.getSlot0(poolId);
        uint256 sq = uint256(sqrtNow);
        uint256 d0 = MockERC20(Currency.unwrap(currency0)).decimals();
        uint256 d1 = MockERC20(Currency.unwrap(currency1)).decimals();
        uint256 shifted = Math.mulDiv(sq, sq, 1 << 96); // raw * 2^96
        if (d0 >= d1) {
            p = Math.mulDiv(shifted, 1e18 * 10 ** (d0 - d1), 1 << 96);
        } else {
            p = Math.mulDiv(shifted, 1e18, (1 << 96) * 10 ** (d1 - d0));
        }
    }

    function _flag(address who, int256 score) internal {
        ledger.forceSetScore(who, score);
        assertEq(uint8(ledger.tierOf(who)), uint8(ReputationLedger.Tier.Flagged));
    }

    function _verifyBlocks() internal view returns (uint32 v) {
        (v,,,, ) = reserve.config();
    }
}
