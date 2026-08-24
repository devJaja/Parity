// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager, SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";

import {ReputationLedger} from "./ReputationLedger.sol";
import {SignalLib} from "./libraries/SignalLib.sol";
import {LVRReserve} from "./LVRReserve.sol";
import {IParityLpRegistry} from "./interfaces/IParityLpRegistry.sol";

/// @title ParityHook
/// @notice A self-funding LVR firewall for Uniswap v4.
///         Detects toxic order flow on-chain (ReputationLedger), prices the risk it creates
///         (tiered swap treatment with ordering delays and premiums), and pays liquidity
///         providers back for Chainlink-verified losses (LVRReserve).
///
///         Treatment matrix (doc §3.2):
///           Trusted  (700–1000): base fee, instant execution, no premium.
///           Neutral  (300–699) : small ordering delay — breaks sandwich atomicity.
///           Flagged  (0–299)   : ordering delay + risk premium routed to the LVR Reserve.
///
///         No trade is ever censored: Parity reprices risk instead of blocking flow. The only
///         revert a swapper can trigger is the delay window itself, which is precisely the
///         mechanism that makes atomic sandwiches impossible for untrusted flow.
contract ParityHook is BaseHook, Ownable, IParityLpRegistry {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using CurrencyLibrary for Currency;
    using SafeCast for *;

    // ------------------------------------------------------------------
    // Types
    // ------------------------------------------------------------------

    /// @notice Per-swap scratch state consumed by afterSwap. One slot per pool; nested swaps on
    ///         the same pool within one lock are not supported by design (single-writer per lock).
    struct PreSwap {
        address swapper;
        uint160 sqrtPriceBefore;
        bool zeroForOne;
        ReputationLedger.Tier tier;
        uint256 premiumTaken;
        Currency premiumCurrency;
        uint128 liquidityBefore;
        bool recorded;
    }

    // ------------------------------------------------------------------
    // Immutable / governance
    // ------------------------------------------------------------------

    /// @notice On-chain reputation: scores, decay, tiers.
    ReputationLedger public immutable ledger;

    /// @notice Escrows premiums, verifies LVR against Chainlink, compensates LPs.
    LVRReserve public immutable reserve;

    /// @notice Extra blocks a Flagged swapper must wait beyond Neutral's gap before re-swapping.
    ///         Neutral requires strictly-later-block re-entry (gap 1); Flagged requires two.
    uint32 public flaggedExtraGapBlocks = 1;

    /// @notice Risk premium for Flagged flow, in basis points of the input amount.
    uint24 public flaggedPremiumBps = 150;

    /// @notice Hard cap so premiums can never exceed MAX_PREMIUM_BPS of trade size.
    uint24 public constant MAX_PREMIUM_BPS = 1000;

    // ------------------------------------------------------------------
    // State
    // ------------------------------------------------------------------

    mapping(PoolId => PreSwap) internal preSwaps;

    /// @notice Last observed swap in each pool — feeds the directional-correlation signal.
    mapping(PoolId => SignalLib.Observation) internal lastPoolObservation;

    /// @notice Each swapper's last observation per pool — feeds the reversal signal.
    mapping(PoolId => mapping(address => SignalLib.Observation)) internal lastOwnObservation;
    mapping(PoolId => mapping(address => bool)) internal hasOwnObservation;

    // LP registry (IParityLpRegistry)
    mapping(PoolId => mapping(address => uint256)) internal lpNet_;
    mapping(PoolId => mapping(address => uint64)) internal lpLastChangeBlock_;
    mapping(PoolId => address[]) internal lpOwners_;

    // ------------------------------------------------------------------
    // Errors
    // ------------------------------------------------------------------

    error DelayWindowActive(address swapper, uint64 eligibleAtBlock);
    error InvalidTier();

    // ------------------------------------------------------------------
    // Events
    // ------------------------------------------------------------------

    event SwapTreated(
        address indexed swapper,
        PoolId indexed poolId,
        ReputationLedger.Tier tier,
        bool delayApplied,
        uint256 premium,
        Currency premiumCurrency
    );
    event PremiumRouted(PoolId indexed poolId, Currency currency, uint256 amount);

    // ------------------------------------------------------------------
    // Construction
    // ------------------------------------------------------------------

    constructor(IPoolManager _poolManager, LVRReserve _reserve, address initialOwner)
        BaseHook(_poolManager)
        Ownable(initialOwner)
    {
        ledger = new ReputationLedger(address(this), initialOwner);
        reserve = _reserve;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: true,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: true,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ------------------------------------------------------------------
    // Governance
    // ------------------------------------------------------------------

    function setFlaggedPremiumBps(uint24 bps) external onlyOwner {
        require(bps <= MAX_PREMIUM_BPS, "premium too high");
        flaggedPremiumBps = bps;
    }

    function setFlaggedExtraGapBlocks(uint32 blocks_) external onlyOwner {
        flaggedExtraGapBlocks = blocks_;
    }

    // ------------------------------------------------------------------
    // Swap hooks
    // ------------------------------------------------------------------

    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId poolId = key.toId();
        address swapper = _resolveSwapper(sender, hookData);
        ReputationLedger.Tier tier = ledger.tierOf(swapper);

        // ---- Treatment: ordering delay -------------------------------------
        // Neutral and Flagged flow must enter on a strictly later block than their previous
        // swap (Flagged must wait an extra block). Atomic sandwiches need both legs in the
        // same block — this gate removes that possibility without censoring any trade.
        uint64 lastBlock = ledger.lastSwapBlock(swapper);
        if (tier != ReputationLedger.Tier.Trusted && lastBlock != 0) {
            uint64 requiredGap = tier == ReputationLedger.Tier.Flagged ? 1 + flaggedExtraGapBlocks : 1;
            if (uint64(block.number) < lastBlock + requiredGap) {
                revert DelayWindowActive(swapper, lastBlock + requiredGap);
            }
        }

        // Snapshot pre-swap state for signal computation and verification anchoring.
        (uint160 sqrtPriceBefore, , , ) = poolManager.getSlot0(poolId);
        uint128 liquidityBefore = poolManager.getLiquidity(poolId);

        PreSwap storage pre = preSwaps[poolId];
        pre.swapper = swapper;
        pre.sqrtPriceBefore = sqrtPriceBefore;
        pre.zeroForOne = params.zeroForOne;
        pre.tier = tier;
        pre.premiumTaken = 0;
        pre.premiumCurrency = params.zeroForOne ? key.currency0 : key.currency1;
        pre.liquidityBefore = liquidityBefore;
        pre.recorded = true;

        BeforeSwapDelta delta = BeforeSwapDeltaLibrary.ZERO_DELTA;

        // ---- Treatment: risk premium (Flagged only, exact-input swaps) -----
        // v4 sign convention: negative amountSpecified = exact input. The premium is taken on
        // the specified (input) currency via a positive hook delta, then immediately settled
        // out to the LVR Reserve. Exact-output swaps take their premium in afterSwap where the
        // actual input consumption is known.
        bool exactInput = params.amountSpecified < 0;
        if (tier == ReputationLedger.Tier.Flagged && exactInput && flaggedPremiumBps > 0) {
            uint256 amountIn = uint256(-params.amountSpecified);
            uint256 premium = (amountIn * flaggedPremiumBps) / 10_000;
            if (premium > amountIn) premium = amountIn;

            if (premium > 0) {
                pre.premiumTaken = premium;
                // Credit the hook with `premium` of the input currency, paid by the swapper.
                delta = toBeforeSwapDelta(premium.toInt128(), 0);
                _takeToReserve(pre.premiumCurrency, premium);
                emit PremiumRouted(poolId, pre.premiumCurrency, premium);
            }
        }

        emit SwapTreated(swapper, poolId, tier, tier != ReputationLedger.Tier.Trusted, pre.premiumTaken, pre.premiumCurrency);
        return (BaseHook.beforeSwap.selector, delta, 0);
    }

    function _afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) internal override returns (bytes4, int128) {
        PoolId poolId = key.toId();
        PreSwap memory pre = preSwaps[poolId];
        delete preSwaps[poolId];
        if (!pre.recorded) return (BaseHook.afterSwap.selector, 0);

        address swapper = pre.swapper;
        (uint160 sqrtPriceAfter, , , ) = poolManager.getSlot0(poolId);

        // Swapper-visible amounts: negative side is what they paid in.
        uint256 amountIn = params.zeroForOne
            ? uint256(uint128(-delta.amount0()))
            : uint256(uint128(-delta.amount1()));

        // ---- Premium for exact-output flagged swaps -------------------------
        // The realized input amount is known only now; charge it on the unspecified (input)
        // currency via a positive afterSwap return delta and settle it to the Reserve.
        int128 unspecifiedReturn = 0;
        bool exactInput = params.amountSpecified < 0;
        if (pre.tier == ReputationLedger.Tier.Flagged && !exactInput && flaggedPremiumBps > 0) {
            uint256 premium = (amountIn * flaggedPremiumBps) / 10_000;
            if (premium > 0 && premium <= uint256(uint128(type(int128).max))) {
                pre.premiumTaken = premium;
                unspecifiedReturn = premium.toInt128();
                _takeToReserve(pre.premiumCurrency, premium);
                emit PremiumRouted(poolId, pre.premiumCurrency, premium);
            }
        }

        // ---- Book escrowed premium into the verification queue -------------
        if (pre.premiumTaken > 0) {
            reserve.recordPremium({
                key: key,
                currency: pre.premiumCurrency,
                amount: pre.premiumTaken,
                // Anchor verification at the PRE-trade price so deviation0 captures only
                // execution-time slippage; post-window drift beyond it proves real harm.
                sqrtPriceT0: pre.sqrtPriceBefore,
                zeroForOne: pre.zeroForOne,
                liquidityAtBlock: pre.liquidityBefore
            });
        }

        // ---- Reputation update ---------------------------------------------
        SignalLib.Observation memory current = SignalLib.Observation({
            swapper: swapper,
            zeroForOne: pre.zeroForOne,
            amountIn: amountIn,
            priceImpactBps: SignalLib.impactBps(pre.sqrtPriceBefore, sqrtPriceAfter),
            blockNumber: uint64(block.number)
        });

        bool hadPrior = hasOwnObservation[poolId][swapper];
        SignalLib.Observation memory priorOwn = lastOwnObservation[poolId][swapper];
        SignalLib.Observation memory priorPool = lastPoolObservation[poolId];

        ledger.applySwapSignals(swapper, current, hadPrior, priorOwn, priorPool);

        lastPoolObservation[poolId] = current;
        lastOwnObservation[poolId][swapper] = current;
        hasOwnObservation[poolId][swapper] = true;

        return (BaseHook.afterSwap.selector, unspecifiedReturn);
    }

    // ------------------------------------------------------------------
    // Liquidity hooks — the LP registry feeding pro-rata compensation
    // ------------------------------------------------------------------

    function _afterAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta,
        BalanceDelta,
        bytes calldata hookData
    ) internal override returns (bytes4, BalanceDelta) {
        _trackLiquidity(key, sender, hookData, params.liquidityDelta, true);
        return (BaseHook.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function _afterRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta,
        BalanceDelta,
        bytes calldata hookData
    ) internal override returns (bytes4, BalanceDelta) {
        // liquidityDelta is signed: positive for adds, negative for removes.
        _trackLiquidity(key, sender, hookData, params.liquidityDelta, false);
        return (BaseHook.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function _trackLiquidity(PoolKey calldata key, address sender, bytes calldata hookData, int256 deltaL, bool)
        internal
    {
        PoolId poolId = key.toId();
        address lp = _resolveSwapper(sender, hookData);

        uint256 net = lpNet_[poolId][lp];
        if (deltaL >= 0) {
            net += uint256(deltaL);
            if (lpLastChangeBlock_[poolId][lp] == 0 && net > 0) {
                lpOwners_[poolId].push(lp);
            }
        } else {
            uint256 sub = uint256(-deltaL);
            net = net >= sub ? net - sub : 0;
        }
        lpNet_[poolId][lp] = net;
        lpLastChangeBlock_[poolId][lp] = uint64(block.number);
    }

    // ------------------------------------------------------------------
    // IParityLpRegistry
    // ------------------------------------------------------------------

    function lpNet(PoolId poolId, address lp) external view returns (uint256) {
        return lpNet_[poolId][lp];
    }

    function lpLastChangeBlock(PoolId poolId, address lp) external view returns (uint64) {
        return lpLastChangeBlock_[poolId][lp];
    }

    function lpCount(PoolId poolId) external view returns (uint256) {
        return lpOwners_[poolId].length;
    }

    function lpAt(PoolId poolId, uint256 index) external view returns (address) {
        return lpOwners_[poolId][index];
    }

    // ------------------------------------------------------------------
    // Internals
    // ------------------------------------------------------------------

    /// @notice Resolves the economic actor for a swap/liquidity event. Routers are msg.sender
    ///         into the PoolManager, so integrators pass the end-user address in hookData
    ///         (first ABI-encoded word). Direct interactions fall back to the sender.
    function _resolveSwapper(address sender, bytes calldata hookData) internal pure returns (address) {
        if (hookData.length >= 32) {
            address claimed = abi.decode(hookData, (address));
            if (claimed != address(0)) return claimed;
        }
        return sender;
    }

    /// @dev Moves tokens held by the PoolManager on this hook's behalf out to the LVRReserve.
    ///      Must be called inside the lock (hook context always is).
    function _takeToReserve(Currency currency, uint256 amount) internal {
        poolManager.sync(currency);
        poolManager.take(currency, address(reserve), amount);
    }
}
