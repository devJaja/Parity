// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {EasyPosm} from "./EasyPosm.sol";
import {BaseTest} from "../BaseTest.sol";

/// @notice Tiny unlock callback harness so tests can donate fee revenue into a pool the way a
///      donateRouter would — `PoolManager.donate` must be called from inside the lock.
contract DonateHelper is IUnlockCallback {
    using CurrencyLibrary for Currency;

    IPoolManager public immutable poolManager;

    constructor(IPoolManager _poolManager) {
        poolManager = _poolManager;
    }

    /// @notice Donates `amount0`/`amount1` of the pool's currencies as fee revenue.
    function donate(PoolKey calldata key, uint256 amount0, uint256 amount1) external {
        poolManager.unlock(abi.encode(key, amount0, amount1));
    }

    function unlockCallback(bytes calldata rawData) external returns (bytes memory) {
        require(msg.sender == address(poolManager), "caller not manager");
        (PoolKey memory key, uint256 amount0, uint256 amount1) = abi.decode(rawData, (PoolKey, uint256, uint256));

        poolManager.donate(key, amount0, amount1, "");
        _settle(key.currency0, amount0);
        _settle(key.currency1, amount1);
        return "";
    }

    /// @dev Mirrors how the canonical periphery settles positive deltas from a lock.
    function _settle(Currency currency, uint256 amount) internal {
        if (amount == 0) return;
        poolManager.sync(currency);
        if (currency.isAddressZero()) {
            poolManager.settle{value: amount}();
        } else {
            currency.transfer(address(poolManager), amount);
            poolManager.settle();
        }
    }
}

contract EasyPosmTest is Test, BaseTest {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    Currency currency0;
    Currency currency1;

    int24 tickLower;
    int24 tickUpper;

    PoolKey key;
    PoolKey nativeKey;

    function setUp() public {
        deployArtifacts();

        (currency0, currency1) = deployCurrencyPair();

        // Create the pool
        key = PoolKey(currency0, currency1, 3000, 60, IHooks(address(0)));
        nativeKey = PoolKey(Currency.wrap(address(0)), currency1, 3000, 60, IHooks(address(0)));

        poolManager.initialize(key, Constants.SQRT_PRICE_1_1);
        poolManager.initialize(nativeKey, Constants.SQRT_PRICE_1_1);

        // full-range liquidity
        tickLower = TickMath.minUsableTick(key.tickSpacing);
        tickUpper = TickMath.maxUsableTick(key.tickSpacing);
    }

    function test_mintLiquidity() public {
        uint256 liquidityToMint = 100e18;
        address recipient = address(this);

        (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
            Constants.SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            uint128(liquidityToMint)
        );

        (, BalanceDelta delta) = positionManager.mint(
            key,
            tickLower,
            tickUpper,
            liquidityToMint,
            type(uint256).max,
            type(uint256).max,
            recipient,
            block.timestamp + 1,
            Constants.ZERO_BYTES
        );
        assertEq(delta.amount0(), -int128(uint128(amount0 + 1 wei)));
        assertEq(delta.amount1(), -int128(uint128(amount1 + 1 wei)));
    }

    function test_mintLiquidityNative() public {
        uint256 liquidityToMint = 100e18;
        address recipient = address(this);

        (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
            Constants.SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            uint128(liquidityToMint)
        );

        vm.deal(address(this), amount0 + 1);
        (, BalanceDelta delta) = positionManager.mint(
            nativeKey,
            tickLower,
            tickUpper,
            liquidityToMint,
            amount0 + 1,
            amount1 + 1,
            recipient,
            block.timestamp + 1,
            Constants.ZERO_BYTES
        );
        assertEq(delta.amount0(), -int128(uint128(amount0 + 1 wei)));
        assertEq(delta.amount1(), -int128(uint128(amount1 + 1 wei)));
    }

    function test_increaseLiquidity() public {
        (uint256 tokenId,) = positionManager.mint(
            key,
            tickLower,
            tickUpper,
            100e18,
            type(uint256).max,
            type(uint256).max,
            address(this),
            block.timestamp + 1,
            Constants.ZERO_BYTES
        );

        uint256 liquidityToAdd = 1e18;

        (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
            Constants.SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            uint128(liquidityToAdd)
        );

        BalanceDelta delta = positionManager.increaseLiquidity(
            tokenId, liquidityToAdd, type(uint256).max, type(uint256).max, block.timestamp + 1, Constants.ZERO_BYTES
        );
        assertEq(delta.amount0(), -int128(uint128(amount0 + 1 wei)));
        assertEq(delta.amount1(), -int128(uint128(amount1 + 1 wei)));
    }

    function test_increaseLiquidityNative() public {
        uint256 liquidityToMint = 100e18;
        address recipient = address(this);

        (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
            Constants.SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            uint128(liquidityToMint)
        );

        vm.deal(address(this), amount0 + 1);
        (uint256 tokenId, BalanceDelta delta) = positionManager.mint(
            nativeKey,
            tickLower,
            tickUpper,
            liquidityToMint,
            amount0 + 1,
            amount1 + 1,
            recipient,
            block.timestamp + 1,
            Constants.ZERO_BYTES
        );

        uint256 liquidityToIncrease = 1e18;

        (amount0, amount1) = LiquidityAmounts.getAmountsForLiquidity(
            Constants.SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            uint128(liquidityToIncrease)
        );

        vm.deal(address(this), amount0 + 1);
        delta = positionManager.increaseLiquidity(
            tokenId, liquidityToIncrease, amount0 + 1, amount1 + 1, block.timestamp + 1, Constants.ZERO_BYTES
        );
        assertEq(delta.amount0(), -int128(uint128(amount0 + 1 wei)));
        assertEq(delta.amount1(), -int128(uint128(amount1 + 1 wei)));
    }

    function test_decreaseLiquidity() public {
        (uint256 tokenId,) = positionManager.mint(
            key,
            tickLower,
            tickUpper,
            100e18,
            type(uint256).max,
            type(uint256).max,
            address(this),
            block.timestamp + 1,
            Constants.ZERO_BYTES
        );

        uint256 liquidityToRemove = 1e18;

        (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
            Constants.SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            uint128(liquidityToRemove)
        );

        BalanceDelta delta = positionManager.decreaseLiquidity(
            tokenId, liquidityToRemove, 0, 0, address(this), block.timestamp + 1, Constants.ZERO_BYTES
        );
        assertEq(delta.amount0(), int128(uint128(amount0)));
        assertEq(delta.amount1(), int128(uint128(amount1)));
    }

    function test_burn() public {
        (uint256 tokenId, BalanceDelta mintDelta) = positionManager.mint(
            key,
            tickLower,
            tickUpper,
            100e18,
            type(uint256).max,
            type(uint256).max,
            address(this),
            block.timestamp + 1,
            Constants.ZERO_BYTES
        );

        BalanceDelta delta =
            positionManager.burn(tokenId, 0, 0, address(this), block.timestamp + 1, Constants.ZERO_BYTES);
        assertEq(delta.amount0(), -mintDelta.amount0() - 1 wei);
        assertEq(delta.amount1(), -mintDelta.amount1() - 1 wei);
    }

    function test_collect() public {
        DonateHelper helper = new DonateHelper(poolManager);
        (uint256 tokenId,) = positionManager.mint(
            key,
            tickLower,
            tickUpper,
            100e18,
            type(uint256).max,
            type(uint256).max,
            address(this),
            block.timestamp + 1,
            Constants.ZERO_BYTES
        );

        // Fund the helper and donate fee revenue into the pool (position is the only LP,
        // so it captures the full donation minus one wei of fee-growth rounding).
        uint256 feeRevenue0 = 1e18;
        uint256 feeRevenue1 = 0.1e18;
        MockERC20(Currency.unwrap(currency0)).mint(address(helper), feeRevenue0);
        MockERC20(Currency.unwrap(currency1)).mint(address(helper), feeRevenue1);
        vm.prank(address(this));
        helper.donate(key, feeRevenue0, feeRevenue1);

        // Collect the accrued fees to a fresh recipient.
        uint256 recipient0Before = currency0.balanceOf(address(0x123));
        uint256 recipient1Before = currency1.balanceOf(address(0x123));
        BalanceDelta delta = positionManager.collect(
            tokenId, 0, 0, address(0x123), block.timestamp + 1, Constants.ZERO_BYTES
        );

        assertEq(uint128(delta.amount0()), feeRevenue0 - 1 wei);
        assertEq(uint128(delta.amount1()), feeRevenue1 - 1 wei);
        assertEq(uint256(currency0.balanceOf(address(0x123)) - recipient0Before), uint128(delta.amount0()));
        assertEq(uint256(currency1.balanceOf(address(0x123)) - recipient1Before), uint128(delta.amount1()));
    }
}
