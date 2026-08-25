// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {ChainlinkPriceAdapter} from "./ChainlinkPriceAdapter.sol";
import {IParityLpRegistry} from "./interfaces/IParityLpRegistry.sol";

/// @title LVRReserve
/// @notice Escrows risk premiums collected from Flagged-tier flow, verifies realized LVR
///         against an independent Chainlink reference price over an N-block window, and closes
///         the loop: verified harm is paid back to the liquidity providers who bore it;
///         unverified premiums roll into the pool's general LP fee revenue.
/// @dev    Verification is permissionless and lazy — any keeper or observer can call
///         `settlePending` once a record's window has elapsed. Payouts are batched and
///         permissionless for the same reason.
contract LVRReserve is Ownable, IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    // ------------------------------------------------------------------
    // Types
    // ------------------------------------------------------------------

    /// @notice Governance-tunable verification parameters.
    struct VerifyConfig {
        uint32 verifyBlocks; // N-block comparison window (doc §5.2)
        uint256 minNoiseBps; // floor of the calibrated noise threshold
        uint256 maxNoiseBps; // ceiling of the calibrated noise threshold
        uint64 ewmaNum; // EWMA numerator (adaptive calibration speed)
        uint64 ewmaDen; // EWMA denominator; alpha = num/den
    }

    /// @notice A premium awaiting Chainlink-referenced verification.
    struct Pending {
        PoolKey key; // full key so unverified premiums can be donated back to LPs
        Currency currency; // token the premium was taken in
        uint256 amount; // premium escrowed
        uint160 sqrtPriceT0; // pool execution anchor at the flagged swap
        uint256 refPriceT0_18; // Chainlink reference at t0; 0 = oracle unavailable (auto-unverified)
        bool zeroForOne; // direction of the flagged trade
        uint128 liquidityAtBlock; // active pool liquidity during the affected block
        uint64 recordedBlock;
        uint256 scaleNum; // decimal normalization: human price = raw * num / den
        uint256 scaleDen;
    }

    /// @notice A verified-LVR compensation pot awaiting pro-rata distribution.
    struct Payout {
        PoolKey key; // full pool identity for residual donations
        Currency currency;
        uint256 amount; // total to distribute
        uint256 distributed; // running total already paid to LPs
        uint128 liquidityAtBlock; // active liquidity during the affected block
        uint64 affectedBlock; // block of the verified toxic trade
        uint256 cursor; // next registry index to scan across batched distributions
        bool complete;
    }

    // ------------------------------------------------------------------
    // Storage
    // ------------------------------------------------------------------

    IPoolManager public immutable poolManager;
    ChainlinkPriceAdapter public immutable priceAdapter;
    address public hook; // IParityLpRegistry — set once after deployment

    VerifyConfig public config;

    Pending[] internal pendings;
    Payout[] internal payouts;

    /// @notice Per-pool EWMA of observed post-window drift (bps) — the adaptive noise threshold.
    ///         Updated ONLY on unverified outcomes so natural volatility trains the threshold
    ///         and confirmed toxic events cannot inflate it.
    mapping(PoolId => uint256) public noiseEwmaBps;

    mapping(PoolId => uint256) public totalVerifiedPaid;
    mapping(PoolId => uint256) public totalUnverifiedDonated;

    // ------------------------------------------------------------------
    // Errors
    // ------------------------------------------------------------------

    error Unauthorized();
    error HookAlreadySet();
    error WindowNotElapsed();
    error AlreadySettled();
    error UnknownPayout();
    error PayoutComplete();

    // ------------------------------------------------------------------
    // Events
    // ------------------------------------------------------------------

    event PremiumRecorded(uint256 indexed pendingIndex, PoolId indexed poolId, Currency currency, uint256 amount);
    event LvrVerificationResult(
        uint256 indexed pendingIndex,
        PoolId indexed poolId,
        bool verified,
        int256 driftSigned18,
        uint256 deviation0_18,
        uint256 thresholdAbs18,
        uint256 observedDriftBps
    );
    event UnverifiedRolledToLpFees(uint256 indexed pendingIndex, PoolId indexed poolId, uint256 amount);
    event VerifiedPayoutQueued(uint256 indexed pendingIndex, uint256 indexed payoutIndex, uint256 amount);
    event CompensationPaid(
        uint256 indexed payoutIndex, PoolId indexed poolId, address indexed lp, Currency currency, uint256 amount
    );
    event PayoutResidualRolledToLpFees(uint256 indexed payoutIndex, uint256 amount);

    // ------------------------------------------------------------------
    // Constructor / admin
    // ------------------------------------------------------------------

    constructor(IPoolManager _poolManager, ChainlinkPriceAdapter _priceAdapter, address initialOwner)
        Ownable(initialOwner)
    {
        poolManager = _poolManager;
        priceAdapter = _priceAdapter;
        config = VerifyConfig({verifyBlocks: 3, minNoiseBps: 20, maxNoiseBps: 500, ewmaNum: 1, ewmaDen: 4});
    }

    /// @notice Wires the registry after both contracts are deployed (breaks the deploy-time
    ///         dependency cycle between hook and reserve). Callable exactly once.
    function setHook(address _hook) external onlyOwner {
        if (hook != address(0)) revert HookAlreadySet();
        hook = _hook;
    }

    function setVerifyConfig(VerifyConfig memory _config) external onlyOwner {
        require(_config.ewmaDen > 0 && _config.ewmaNum <= _config.ewmaDen, "bad ewma");
        require(_config.minNoiseBps <= _config.maxNoiseBps, "bad thresholds");
        config = _config;
    }

    // ------------------------------------------------------------------
    // Premium intake (ParityHook only)
    // ------------------------------------------------------------------

    /// @dev Records a premium that has ALREADY been transferred into this contract by the hook.
    function recordPremium(
        PoolKey calldata key,
        Currency currency,
        uint256 amount,
        uint160 sqrtPriceT0,
        bool zeroForOne,
        uint128 liquidityAtBlock
    ) external returns (uint256 pendingIndex) {
        if (msg.sender != hook) revert Unauthorized();
        if (amount == 0) return type(uint256).max; // nothing escrowed; caller skips booking

        // Snapshot the independent reference now. Oracle failure degrades gracefully:
        // refPriceT0 = 0 marks the record auto-unverifiable rather than bricking flagged flow.
        uint256 refT0;
        try priceAdapter.latestPrice18() returns (uint256 p, uint256) {
            refT0 = p;
        } catch {
            refT0 = 0;
        }

        // Resolve the pool's decimal normalization once so the execution anchor and the
        // settle-time pool price share identical scaling.
        (uint256 scaleNum, uint256 scaleDen) = _decimalScale(key.currency0, key.currency1);

        pendings.push(
            Pending({
                key: key,
                currency: currency,
                amount: amount,
                sqrtPriceT0: sqrtPriceT0,
                refPriceT0_18: refT0,
                zeroForOne: zeroForOne,
                liquidityAtBlock: liquidityAtBlock,
                recordedBlock: uint64(block.number),
                scaleNum: scaleNum,
                scaleDen: scaleDen
            })
        );
        pendingIndex = pendings.length - 1;
        emit PremiumRecorded(pendingIndex, key.toId(), currency, amount);
    }

    // ------------------------------------------------------------------
    // Verification (permissionless, lazily evaluated)
    // ------------------------------------------------------------------

    /// @notice Aggregated result of the doc §5.2 comparison.
    struct DriftOutcome {
        bool verified;
        int256 driftSigned;
        uint256 deviation0;
        uint256 noiseAbs;
        uint256 observedBps;
    }

    /// @notice Settles a pending verification once its N-block window has elapsed.
    ///         Implements doc §5.2: verified iff the pool's drift away from the Chainlink
    ///         reference exceeds the initial execution deviation plus the calibrated noise
    ///         threshold, in the direction consistent with the flagged trade.
    function settlePending(uint256 pendingIndex) external returns (bool verified) {
        if (pendingIndex >= pendings.length) revert UnknownPayout();
        Pending storage p = pendings[pendingIndex];
        if (p.amount == 0) revert AlreadySettled(); // settled records are zeroed
        if (block.number < uint256(p.recordedBlock) + config.verifyBlocks) revert WindowNotElapsed();

        PoolId poolId = p.key.toId();
        (uint160 sqrtNow, , , ) = poolManager.getSlot0(poolId);
        (uint256 refNow18, bool refOk) = _referencePrice18Safe();

        // Any oracle failure ⇒ unverifiable ⇒ premium rolls into general LP fees. Deterministic,
        // never reverts on oracle conditions, and LPs are still compensated collectively.
        if (p.refPriceT0_18 == 0 || !refOk) {
            _finalizeUnverified(pendingIndex, p, poolId);
            return false;
        }

        DriftOutcome memory outcome =
            _compareDrift(p.sqrtPriceT0, p.refPriceT0_18, p.zeroForOne, sqrtNow, p.scaleNum, p.scaleDen, refNow18, poolId);
        emit LvrVerificationResult(
            pendingIndex, poolId, outcome.verified, outcome.driftSigned, outcome.deviation0, outcome.noiseAbs, outcome.observedBps
        );

        if (outcome.verified) {
            payouts.push(
                Payout({
                    key: p.key,
                    currency: p.currency,
                    amount: p.amount,
                    distributed: 0,
                    liquidityAtBlock: p.liquidityAtBlock,
                    affectedBlock: p.recordedBlock,
                    cursor: 0,
                    complete: false
                })
            );
            emit VerifiedPayoutQueued(pendingIndex, payouts.length - 1, p.amount);
        } else {
            // Natural volatility trains the adaptive threshold; confirmed toxicity does not.
            VerifyConfig memory c = config;
            uint256 prev = noiseEwmaBps[poolId];
            noiseEwmaBps[poolId] =
                (prev * (c.ewmaDen - c.ewmaNum) + outcome.observedBps * c.ewmaNum) / c.ewmaDen;
            emit UnverifiedRolledToLpFees(pendingIndex, poolId, p.amount);
            _donateToPool(poolId, p.key, p.currency, p.amount);
        }

        // Zero out the record to mark it settled and refund its storage gas.
        delete pendings[pendingIndex];
        verified = outcome.verified;
    }

    /// @notice Effective per-pool noise threshold: the EWMA clamped to governance bounds.
    function effectiveThresholdBps(PoolId poolId) external view returns (uint256) {
        return _clampThreshold(noiseEwmaBps[poolId]);
    }

    // ------------------------------------------------------------------
    // Compensation distribution (permissionless, batched)
    // ------------------------------------------------------------------

    /// @notice Pays up to `maxBatch` eligible LPs their pro-rata share of a verified payout.
    ///         Eligibility: tracked net liquidity > 0 and last change at or before the affected
    ///         block. Share base: active pool liquidity at the affected block.
    /// @return paid Total distributed in this call.
    /// @return complete True when every eligible LP has been paid and residuals rolled over.
    function distributeVerified(uint256 payoutIndex, uint256 maxBatch)
        external
        returns (uint256 paid, bool complete)
    {
        if (payoutIndex >= payouts.length) revert UnknownPayout();
        Payout storage payout = payouts[payoutIndex];
        if (payout.complete) revert PayoutComplete();

        PoolId poolId = payout.key.toId();
        IParityLpRegistry registry = IParityLpRegistry(hook);
        uint256 lpCount = registry.lpCount(poolId);
        uint256 processed = 0;

        // Scan resumes at the cursor so batched calls never pay an LP twice.
        uint256 i = payout.cursor;
        for (; i < lpCount && processed < maxBatch; ++i) {
            if (payout.amount - payout.distributed == 0) break;
            ++processed;
            (uint256 paidNow, bool halt) = _payEligibleLp(payoutIndex, payout, registry, poolId, i);
            paid += paidNow;
            if (halt) break;
        }
        payout.cursor = i;

        complete = payout.cursor >= lpCount || payout.amount == payout.distributed;
        uint256 remaining = payout.amount - payout.distributed;
        if (complete && remaining > 0) {
            // Residual dust (rounding or ineligible LPs) rolls into general LP fee revenue.
            payout.distributed += remaining;
            emit PayoutResidualRolledToLpFees(payoutIndex, remaining);
            _donateToPool(poolId, payout.key, payout.currency, remaining);
        }
        if (complete) payout.complete = true;
    }

    /// @dev Pays a single LP if eligible. Returns the amount paid and whether distribution
    ///      should halt (funds exhausted or zero base).
    function _payEligibleLp(
        uint256 payoutIndex,
        Payout storage payout,
        IParityLpRegistry registry,
        PoolId poolId,
        uint256 index
    ) internal returns (uint256 paidOut, bool halt) {
        uint256 base = payout.liquidityAtBlock;
        if (base == 0) return (0, true);

        address lp = registry.lpAt(poolId, index);
        uint256 net = registry.lpNet(poolId, lp);
        if (net == 0) return (0, false);
        if (registry.lpLastChangeBlock(poolId, lp) > payout.affectedBlock) return (0, false);

        uint256 share = (net * payout.amount) / base;
        if (share == 0) return (0, false);

        uint256 remaining = payout.amount - payout.distributed;
        if (share > remaining) share = remaining;

        // Checks-Effects-Interactions: book the payment BEFORE the token transfer so a
        // receiving contract reentering `distributeVerified` observes updated state and
        // can never draw against the same premium twice.
        payout.distributed += share;
        totalVerifiedPaid[poolId] += share;
        payout.currency.transfer(lp, share);
        emit CompensationPaid(payoutIndex, poolId, lp, payout.currency, share);

        return (share, payout.amount - payout.distributed == 0);
    }

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------

    function pendingsLength() external view returns (uint256) {
        return pendings.length;
    }

    function getPending(uint256 i)
        external
        view
        returns (
            PoolId poolId,
            Currency currency,
            uint256 amount,
            uint160 sqrtPriceT0,
            uint256 refPriceT0_18,
            bool zeroForOne,
            uint128 liquidityAtBlock,
            uint64 recordedBlock
        )
    {
        Pending storage p = pendings[i];
        return (p.key.toId(), p.currency, p.amount, p.sqrtPriceT0, p.refPriceT0_18, p.zeroForOne, p.liquidityAtBlock, p.recordedBlock);
    }

    function payoutsLength() external view returns (uint256) {
        return payouts.length;
    }

    function getPayout(uint256 i)
        external
        view
        returns (PoolId poolId, Currency currency, uint256 amount, uint256 distributed, uint64 affectedBlock, bool complete)
    {
        Payout storage p = payouts[i];
        return (p.key.toId(), p.currency, p.amount, p.distributed, p.affectedBlock, p.complete);
    }

    // ------------------------------------------------------------------
    // Unlock callback — donations back into the pool's LP fee stream
    // ------------------------------------------------------------------

    /// @notice Executes inside the PoolManager lock: donates `amount` of one currency to the
    ///         pool, converting unverified premiums into fee growth for all in-range LPs.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(poolManager), "caller not manager");
        (PoolKey memory key, Currency currency, uint256 amount) = abi.decode(data, (PoolKey, Currency, uint256));

        // Route the donation into the slot matching the premium's currency.
        bool isCurrency0 = Currency.unwrap(currency) == Currency.unwrap(key.currency0);
        poolManager.donate(key, isCurrency0 ? amount : 0, isCurrency0 ? 0 : amount, "");

        if (!currency.isAddressZero()) {
            // ERC20 path: sync snapshot, pull tokens in, settle against the delta.
            poolManager.sync(currency);
            currency.transfer(address(poolManager), amount);
            poolManager.settle();
        } else {
            poolManager.sync(currency);
            poolManager.settle{value: amount}();
        }
        return "";
    }

    // ------------------------------------------------------------------
    // Internals
    // ------------------------------------------------------------------

    function _finalizeUnverified(uint256 pendingIndex, Pending storage p, PoolId poolId) internal {
        // Oracle-failure path: no drift observation exists, so the adaptive threshold is left
        // untouched. The premium still rolls into general LP fee revenue.
        emit LvrVerificationResult(pendingIndex, poolId, false, 0, 0, 0, 0);
        emit UnverifiedRolledToLpFees(pendingIndex, poolId, p.amount);
        _donateToPool(poolId, p.key, p.currency, p.amount);
        delete pendings[pendingIndex];
    }

    function _donateToPool(PoolId poolId, PoolKey memory key, Currency currency, uint256 amount) internal {
        totalUnverifiedDonated[poolId] += amount;
        poolManager.unlock(abi.encode(key, currency, amount));
    }

    function _clampThreshold(uint256 ewmaBps) internal view returns (uint256) {
        VerifyConfig memory c = config;
        if (ewmaBps < c.minNoiseBps) return c.minNoiseBps;
        if (ewmaBps > c.maxNoiseBps) return c.maxNoiseBps;
        return ewmaBps;
    }

    /// @dev Reference price that degrades to `ok = false` on any oracle failure.
    function _referencePrice18Safe() internal view returns (uint256 price18, bool ok) {
        try priceAdapter.latestPrice18() returns (uint256 p, uint256) {
            return (p, true);
        } catch {
            return (0, false);
        }
    }

    /// @dev Pure comparison of doc §5.2 against current prices. Anchor and current pool prices
    ///      share the pending record's decimal scaling, so both are in human 18-decimal units.
    function _compareDrift(
        uint160 sqrtPriceT0,
        uint256 refT0_18,
        bool zeroForOne,
        uint160 sqrtNow,
        uint256 scaleNum,
        uint256 scaleDen,
        uint256 refNow18,
        PoolId poolId
    ) internal view returns (DriftOutcome memory o) {
        int256 driftSigned = int256(_price18(sqrtNow, scaleNum, scaleDen)) - int256(refNow18);
        uint256 driftAbs = driftSigned < 0 ? uint256(-driftSigned) : uint256(driftSigned);

        int256 devSigned = int256(_price18(sqrtPriceT0, scaleNum, scaleDen)) - int256(refT0_18);
        o.deviation0 = devSigned < 0 ? uint256(-devSigned) : uint256(devSigned);

        o.driftSigned = driftSigned;
        o.observedBps = (driftAbs * 10_000) / refNow18;
        o.noiseAbs = (refNow18 * _clampThreshold(noiseEwmaBps[poolId])) / 10_000;

        bool directionOk = zeroForOne ? driftSigned < 0 : driftSigned > 0;
        o.verified = directionOk && driftAbs > o.deviation0 + o.noiseAbs;
    }

    /// @dev Converts a square-root price to an 18-decimal HUMAN price:
    ///      sqrtP^2 * 1e18 * scaleNum / (2^192 * scaleDen).
    ///      scaleNum/scaleDen encode 10^(dec0-dec1) so raw smallest-unit ratios become
    ///      human-unit prices comparable to the normalized Chainlink reference.
    ///      Math.mulDiv handles the full 512-bit intermediate: sqrtP^2 alone can reach
    ///      ~2^320 near TickMath's MAX_SQRT_RATIO, which would overflow plain uint256 math.
    ///      Scaling happens BEFORE division so sub-1.0 prices keep full precision.
    function _price18(uint160 sqrtP, uint256 scaleNum, uint256 scaleDen) internal pure returns (uint256) {
        uint256 sq = uint256(sqrtP);
        // Intermediate staging at raw*2^96 keeps every factor within range while
        // preserving precision for prices far below 1.0.
        uint256 shifted = Math.mulDiv(sq, sq, 1 << 96); // = raw price * 2^96
        return Math.mulDiv(shifted, 1e18 * scaleNum, (1 << 96) * scaleDen);
    }

    /// @dev Human-price normalization for a pair: humanPrice = rawPrice * num / den,
    ///      where num/den = 10^(dec0 - dec1). Native currency counts as 18 decimals;
    ///      non-standard tokens fall back to 18 rather than reverting flagged flow.
    function _decimalScale(Currency c0, Currency c1) internal view returns (uint256 num, uint256 den) {
        uint256 d0 = _tokenDecimals(c0);
        uint256 d1 = _tokenDecimals(c1);
        if (d0 >= d1) return (10 ** (d0 - d1), 1);
        return (1, 10 ** (d1 - d0));
    }

    function _tokenDecimals(Currency c) internal view returns (uint256) {
        address token = Currency.unwrap(c);
        if (token == address(0)) return 18;
        try IERC20Metadata(token).decimals() returns (uint8 d) {
            return d == 0 ? 18 : d; // 0 is never a meaningful ERC20 answer
        } catch {
            return 18;
        }
    }
}
