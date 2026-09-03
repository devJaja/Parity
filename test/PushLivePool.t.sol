// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {ParityHook} from "../src/ParityHook.sol";
import {LVRReserve} from "../src/LVRReserve.sol";
import {ReputationLedger} from "../src/ReputationLedger.sol";

import {Deployers} from "./utils/Deployers.sol";
import {EasyPosm} from "./utils/libraries/EasyPosm.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";

/// @dev Canonical USDC is a Circle FiatToken: to mint in a fork we impersonate the
///      masterMinter, configureMinter(testAddr), then testAddr.mint(...).
interface IFiatToken {
    function configureMinter(address minter, uint256 minterAllowedAmount) external;
    function mint(address to, uint256 amount) external;
    function minterAllowance(address minter) external view returns (uint256);
    function updateMinter(address minter) external;
}

interface IWETH {
    function deposit() external payable;
    function approve(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

/// @dev Fork proof seeding a REAL canonical WETH/USDC pool against the DEPLOYED ParityHook and
///      driving the full MVP treatment path with canonical tokens (no mocks):
///        create pool -> seed LP (canonical POSM) -> flag swapper -> one-sided swap
///        -> premium escrowed into deployed LVRReserve -> same-block re-entry rejected
///        -> settle after window.
///      Uses the live ETH/USD Chainlink feed, so settlement semantics are the real ones (a
///      confirmed one-sided drift in the flagged direction classifies as *verified*).
///      Run: forge test --match-path test/PushLivePool.t.sol --fork-url $BASE_RPC
contract PushLivePoolTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using EasyPosm for IPositionManager;

    // ---- Live Base Sepolia (84532) ----
    address internal constant PARITY_HOOK = 0x95E4a3Aa11c44EB8de369830E9f956703F5585cC;
    address internal constant LVR_RESERVE = 0x07fabE011c4BB617a12E33098258586fD066EcDF;
    address internal constant OWNER = 0x664C1791ad9189ebAEB63716d29EeCaA405c732D;
    address internal constant WETH = 0x4200000000000000000000000000000000000006;
    address internal constant USDC = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;
    address internal constant USDC_MASTER_MINTER = 0xD52081E444544C744B3ECbb0dE7fF06e63ef4E1c;

    ParityHook hook;
    LVRReserve reserve;
    ReputationLedger ledger;
    IWETH weth;
    IFiatToken usdc;

    PoolKey poolKey;
    PoolId poolId;
    address lp;
    uint256 lpTokenId;

    function setUp() public {
        vm.skip(block.chainid == 31_337);
        vm.skip(PARITY_HOOK.code.length == 0);

        deployPermit2();
        deployPoolManager();
        deployPositionManager();
        deployRouter();

        hook = ParityHook(PARITY_HOOK);
        reserve = LVRReserve(LVR_RESERVE);
        ledger = ReputationLedger(hook.ledger());
        weth = IWETH(WETH);
        usdc = IFiatToken(USDC);

        _fundLp();
        _createPoolAndSeed();
    }

    function _fundLp() internal {
        lp = makeAddr("lp");

        // Give the LP fork ETH, wrap into canonical WETH.
        vm.deal(lp, 10 ether);
        vm.startPrank(lp);
        weth.deposit{value: 5 ether}();

        // Mint canonical USDC by impersonating the FiatToken masterMinter.
        vm.stopPrank();
        vm.startPrank(USDC_MASTER_MINTER);
        usdc.configureMinter(address(this), type(uint256).max); // this test is the minter
        vm.stopPrank();

        // Mint to the LP account.
        vm.prank(address(this));
        usdc.mint(lp, 100_000e6); // $100k in 6-dec
        vm.stopPrank();
    }

    function _createPoolAndSeed() internal {
        vm.startPrank(lp);
        weth.approve(address(permit2), type(uint256).max);
        IERC20_6(USDC).approve(address(permit2), type(uint256).max);
        weth.approve(address(swapRouter), type(uint256).max);
        IERC20_6(USDC).approve(address(swapRouter), type(uint256).max);
        permit2.approve(WETH, address(positionManager), type(uint160).max, type(uint48).max);
        permit2.approve(USDC, address(positionManager), type(uint160).max, type(uint48).max);

        poolKey = PoolKey(
            Currency.wrap(USDC), // currency0 (0x036C… < 0x4200…)
            Currency.wrap(WETH), // currency1
            3000,
            60,
            IHooks(PARITY_HOOK)
        );
        poolId = poolKey.toId();

        // Initialize at the real WETH/USDC price (~2400 USDC/WETH → WETH-per-USDC price 1/2400).
        uint160 sqrtPriceX96 = 0x539bf7ccf3c0c8000000000;
        poolManager.initialize(poolKey, sqrtPriceX96);

        // Concentrated range narrowly around the current price so token commitments stay small.
        int24 currentTick = -77_880;
        int24 tickLower = currentTick - 3 * int24(poolKey.tickSpacing);
        int24 tickUpper = currentTick + 3 * int24(poolKey.tickSpacing);
        uint128 liquidity = 1e11; // small concentrated position (~tens of $k either side)

        // Max-pull caps generous; the POSM pulls only what liquidity requires (LP is funded far above).
        (uint256 amount0Expected, uint256 amount1Expected) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            liquidity
        );
        (lpTokenId,) = positionManager.mint(
            poolKey,
            tickLower,
            tickUpper,
            liquidity,
            amount0Expected + 1,
            amount1Expected + 1,
            lp,
            block.timestamp,
            abi.encode(lp)
        );
        vm.stopPrank();
    }

    /// @notice Full live-pool MVP flow with canonical WETH/USDC and the real ETH/USD feed.
    function test_live_weth_usdc_pool_treats_flagged_flow() public {
        address mallory = makeAddr("mallory");
        _fundTrader(mallory, 0.1 ether, 50_000e6);

        // Owner flags mallory on the deployed ledger (owner-only governance call).
        vm.prank(OWNER);
        ledger.forceSetScore(mallory, 100);

        // One-sided exact-input swap: mallory buys WETH with USDC (zeroForOne=true inputs USDC = currency0).
        _swap(mallory, 1_000e6); // ~$1000 USDC in

        // Premium booked into the DEPLOYED reserve.
        assertEq(reserve.pendingsLength(), 1, "one pending record in deployed reserve");
        (, , uint256 recordedAmount, , , , , ) = reserve.getPending(0);
        uint256 expectedPremium = (1_000e6 * uint256(hook.flaggedPremiumBps())) / 10_000; // 150 bps of USDC
        assertEq(recordedAmount, expectedPremium, "150 bps premium escrowed into deployed reserve");

        // Same-block second leg reverted by the delay gate.
        _expectDelayRevert(mallory, 500e6);

        // Elapse verify window and settle on the deployed reserve.
        (uint32 verifyBlocks, , , , ) = reserve.config();
        vm.roll(block.number + uint256(verifyBlocks) + 1);
        bool verified = reserve.settlePending(0);
        vm.expectRevert(LVRReserve.AlreadySettled.selector);
        reserve.settlePending(0);

        if (verified) {
            assertEq(reserve.payoutsLength(), 1, "verified -> payout queued");
            (uint256 paid, ) = reserve.distributeVerified(0, 100);
            assertTrue(paid > 0, "native LP paid");
        }
    }

    function _fundTrader(address who, uint256 ethAmount, uint256 usdcAmount) internal {
        vm.deal(who, ethAmount);
        vm.startPrank(who);
        weth.deposit{value: ethAmount}();
        vm.stopPrank();
        // give USDC by minting to trader as well (test is minter)
        vm.prank(address(this));
        usdc.mint(who, usdcAmount);
        vm.startPrank(who);
        IERC20_6(USDC).approve(address(swapRouter), type(uint256).max);
        IERC20_6(USDC).approve(address(permit2), type(uint256).max);
        vm.stopPrank();
    }

    function _swap(address who, uint256 usdcIn) internal {
        vm.startPrank(who, who);
        swapRouter.swapExactTokensForTokens({
            amountIn: usdcIn,
            amountOutMin: 0,
            zeroForOne: true, // input USDC (currency0), buy WETH (currency1)
            poolKey: poolKey,
            hookData: abi.encode(who),
            receiver: who,
            deadline: block.timestamp + 100
        });
        vm.stopPrank();
    }

    function _expectDelayRevert(address who, uint256 usdcIn) internal {
        vm.startPrank(who, who);
        (bool ok, ) = address(swapRouter).call(
            abi.encodeCall(
                SwapRouterCallbacks.swapExactTokensForTokens,
                (usdcIn, 0, true, poolKey, abi.encode(who), who, block.timestamp + 100)
            )
        );
        vm.stopPrank();
        assertFalse(ok, "same-block re-entry must be rejected by delay gate");
    }
}

interface SwapRouterCallbacks {
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

interface IERC20_6 {
    function approve(address, uint256) external returns (bool);
}
