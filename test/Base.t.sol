// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {EasyPosm} from "./utils/libraries/EasyPosm.sol";
import {BaseTest} from "./utils/BaseTest.sol";
import {IUniswapV4Router04} from "hookmate/interfaces/router/IUniswapV4Router04.sol";

import {ParityHook} from "../../src/ParityHook.sol";
import {ReputationLedger} from "../../src/ReputationLedger.sol";
import {LVRReserve} from "../../src/LVRReserve.sol";
import {ChainlinkPriceAdapter} from "../../src/ChainlinkPriceAdapter.sol";
import {MockAggregator} from "./mocks/MockAggregator.sol";

/// @dev Narrow view of the router used only to hand-encode failing swap calls
///      (the full interface has overloads that break abi.encodeCall).
interface ISinglePoolExactIn {
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        bool zeroForOne,
        PoolKey calldata poolKey,
        bytes calldata hookData,
        address receiver,
        uint256 deadline
    ) external payable returns (BalanceDelta);
}

/// @notice Shared fixture: full Parity stack deployed against the canonical v4 artifacts,
///         with a seeded full-range LP position so donations and fee accounting have a target.
abstract contract ParityTest is BaseTest {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    Currency currency0;
    Currency currency1;
    PoolKey poolKey;
    PoolId poolId;

    MockAggregator aggregator;
    ChainlinkPriceAdapter adapter;
    LVRReserve reserve;
    ParityHook hook;
    ReputationLedger ledger;

    uint256 lpTokenId;

    /// @dev Hook permissions required by Parity, encoded as address flags.
    function _parityFlags() internal pure returns (address) {
        return address(
            uint160(
                Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                    | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
                    | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
            ) ^ (0x5041 << 144) // "PA" namespace to avoid collisions
        );
    }

    function _deployParity() internal {
        deployArtifactsAndLabel();
        (currency0, currency1) = deployCurrencyPair();

        aggregator = new MockAggregator(8, 1e8); // reference price = 1.0 (8 decimals)
        adapter = new ChainlinkPriceAdapter(aggregator, 3600);
        reserve = new LVRReserve(poolManager, adapter, address(this));

        bytes memory constructorArgs = abi.encode(poolManager, address(reserve), address(this));
        deployCodeTo("ParityHook.sol:ParityHook", constructorArgs, _parityFlags());
        hook = ParityHook(_parityFlags());
        ledger = hook.ledger();

        reserve.setHook(hook);

        // Mirror production deployment: the canonical PositionManager attests position
        // owners through hookData so LP attribution survives the identity corroboration.
        hook.setRouterAuthorization(address(positionManager), true);

        vm.label(address(aggregator), "MockAggregator");
        vm.label(address(adapter), "ChainlinkPriceAdapter");
        vm.label(address(reserve), "LVRReserve");
        vm.label(address(hook), "ParityHook");
        vm.label(address(ledger), "ReputationLedger");
    }

    function _createPoolAndSeedLiquidity(uint128 liquidityAmount) internal {
        poolKey = PoolKey(currency0, currency1, 3000, 60, IHooks(hook));
        poolId = poolKey.toId();
        poolManager.initialize(poolKey, Constants.SQRT_PRICE_1_1);

        int24 tickLower = TickMath.minUsableTick(poolKey.tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(poolKey.tickSpacing);

        (uint256 amount0Expected, uint256 amount1Expected) = LiquidityAmounts.getAmountsForLiquidity(
            Constants.SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            liquidityAmount
        );

        // hookData carries the true LP identity through the PositionManager.
        (lpTokenId,) = positionManager.mint(
            poolKey,
            tickLower,
            tickUpper,
            liquidityAmount,
            amount0Expected + 1,
            amount1Expected + 1,
            address(this),
            block.timestamp,
            abi.encode(address(this))
        );
    }

    // ------------------------------------------------------------------
    // Swapper utilities
    // ------------------------------------------------------------------

    function _makeSwapper(uint256 seed) internal returns (address swapper) {
        swapper = makeAddr(string.concat("swapper-", vm.toString(seed)));
        _fundApprove(swapper);
    }

    /// @notice Adds a full-range position attributed to `who` through the PositionManager,
    ///         registering them in the hook's LP registry via hookData identity.
    function _addFullRangeLp(address who, uint128 liquidity) internal returns (uint256 tokenId) {
        _approvePosm(who);
        (int24 lower, int24 upper) =
            (TickMath.minUsableTick(poolKey.tickSpacing), TickMath.maxUsableTick(poolKey.tickSpacing));
        // Two-arg prank sets tx.origin too, which ParityHook requires to corroborate
        // hookData identity claims (production EOAs always satisfy tx.origin == user).
        vm.startPrank(who, who);
        (tokenId,) = positionManager.mint(
            poolKey, lower, upper, liquidity, type(uint256).max, type(uint256).max, who, block.timestamp, abi.encode(who)
        );
        vm.stopPrank();
    }

    /// @dev The canonical PositionManager settles user deltas through Permit2, so each
    ///      LP needs token→Permit2 and Permit2→positionManager allowances.
    function _approvePosm(address who) internal {
        vm.startPrank(who);
        MockERC20(Currency.unwrap(currency0)).approve(address(permit2), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(permit2), type(uint256).max);
        permit2.approve(Currency.unwrap(currency0), address(positionManager), type(uint160).max, type(uint48).max);
        permit2.approve(Currency.unwrap(currency1), address(positionManager), type(uint160).max, type(uint48).max);
        vm.stopPrank();
    }

    function _fundApprove(address who) internal {
        MockERC20(Currency.unwrap(currency0)).mint(who, 1_000_000e18);
        MockERC20(Currency.unwrap(currency1)).mint(who, 1_000_000e18);
        vm.startPrank(who);
        MockERC20(Currency.unwrap(currency0)).approve(address(permit2), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(permit2), type(uint256).max);
        // The canonical router settles against the PoolManager by pulling tokens
        // directly as spender, so it needs plain ERC20 approvals as well.
        MockERC20(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);
        permit2.approve(Currency.unwrap(currency0), address(swapRouter), type(uint160).max, type(uint48).max);
        permit2.approve(Currency.unwrap(currency1), address(swapRouter), type(uint160).max, type(uint48).max);
        vm.stopPrank();
    }

    /// @notice Exact-input swap executed by `who`, identity carried in hookData.
    ///         Two-arg prank: tx.origin == who, corroborating the identity claim exactly
    ///         as a production EOA-signed transaction would.
    function _swap(address who, bool zeroForOne, uint256 amountIn)
        internal
        returns (BalanceDelta delta)
    {
        vm.startPrank(who, who);
        delta = swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: zeroForOne,
            poolKey: poolKey,
            hookData: abi.encode(who),
            receiver: who,
            deadline: block.timestamp + 100
        });
        vm.stopPrank();
    }

    /// @notice Exact-output swap executed by `who`.
    function _swapExactOut(address who, bool zeroForOne, uint256 amountOut)
        internal
        returns (BalanceDelta delta)
    {
        vm.startPrank(who, who);
        delta = swapRouter.swapTokensForExactTokens({
            amountOut: amountOut,
            amountInMax: type(uint256).max,
            zeroForOne: zeroForOne,
            poolKey: poolKey,
            hookData: abi.encode(who),
            receiver: who,
            deadline: block.timestamp + 100
        });
        vm.stopPrank();
    }

    /// @dev Runs an exact-input swap expected to be rejected by the ordering delay.
    ///      v4-core wraps hook reverts as WrappedError(target, selector, result, reason),
    ///      so we unwrap one level and assert on the inner DelayWindowActive payload.
    function _swapExpectingDelay(address who, uint256 amountIn, uint64 eligibleAtExpected) internal {
        vm.startPrank(who, who);
        (bool ok, bytes memory ret) = address(swapRouter).call(
            abi.encodeCall(
                ISinglePoolExactIn.swapExactTokensForTokens,
                (amountIn, 0, true, poolKey, abi.encode(who), who, block.timestamp + 100)
            )
        );
        vm.stopPrank();

        assertFalse(ok, "swap should have been rejected by the delay window");

        // v4-core wraps hook reverts as an ERC-7751 WrappedError, but its assembly
        // encoder can emit non-word-aligned payloads, so we locate the inner error
        // by selector instead of decoding the wrapper struct.
        bytes4 innerSelector = ParityHook.DelayWindowActive.selector;
        int256 pos = _findSelector(ret, innerSelector);
        assertTrue(pos >= 0 && ret.length >= uint256(pos) + 4 + 64, "DelayWindowActive payload not found");

        bytes memory args = new bytes(64);
        for (uint256 i; i < 64; ++i) {
            args[i] = ret[uint256(pos) + 4 + i];
        }
        (address swapperId, uint64 eligibleAt) = abi.decode(args, (address, uint64));
        assertEq(swapperId, who);
        assertEq(uint256(eligibleAt), uint256(eligibleAtExpected));
    }

    /// @dev Byte search: the ERC-7751 wrapper's assembly encoding is not always
    ///      word-aligned, so struct decoding is unreliable — find the selector.
    function _findSelector(bytes memory data, bytes4 sel) internal pure returns (int256) {
        for (uint256 i; i + 4 <= data.length; ++i) {
            if (
                data[i] == sel[0] && data[i + 1] == sel[1] && data[i + 2] == sel[2]
                    && data[i + 3] == sel[3]
            ) {
                return int256(i);
            }
        }
        return -1;
    }
}
