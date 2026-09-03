// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {ParityHook} from "../src/ParityHook.sol";
import {LVRReserve} from "../src/LVRReserve.sol";
import {ChainlinkPriceAdapter} from "../src/ChainlinkPriceAdapter.sol";
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
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/// @dev Unambiguous single-pool exact-input view of the router (the full interface has overloads
///      that break abi.encodeCall).
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

/// @notice End-to-end fork proof against the LIVE Base Sepolia (chain 84532) deployment of the
///         ParityHook. Mirrors the `CircleLiveFork` proof standard: rather than redeploying, it
///         drives the ALREADY-DEPLOYED hook/reserve/ledger by address on a fork, using the same
///         canonical v4 PoolManager/PositionManager/Router the deployment is pinned to, and
///         proves the core MVP treatment path works on-chain:
///           - wiring: hook ↔ reserve ↔ chainlink adapter ↔ live ETH/USD feed ↔ canonical PoolManager
///           - a flagged exact-input swap escrows its risk premium into the DEPLOYED LVRReserve
///           - the same-block re-entry gate reverts (sandwich atomicity killed on the live hook)
///           - the pending record settles/donates cleanly through the DEPLOYED reserve
///
/// What is NOT asserted here (by design): the verified-vs-donated settlement outcome, which
/// depends on live Chainlink feed direction vs. the pool's drift at runtime. That branch is
/// covered deterministically by test/LVRVerification.t.sol. This fork test proves the
/// deployed-treatment plumbing and wiring that a judge can reproduce.
///
/// Run (requires an RPC):
///     forge test --match-path test/HookLiveFork.t.sol --fork-url <BASE_RPC>
/// Without a fork these assertions are skipped.
contract HookLiveForkTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using EasyPosm for IPositionManager;

    // ---- Live Base Sepolia (84532) deploy ---
    address internal constant PARITY_HOOK = 0x95E4a3Aa11c44EB8de369830E9f956703F5585cC;
    address internal constant LVR_RESERVE = 0x07fabE011c4BB617a12E33098258586fD066EcDF;
    address internal constant CHAINLINK_ADAPTER = 0x81e9bb58e41888E4c3f9b4523d4c62290F2AAa46;
    address internal constant CHAINLINK_FEED = 0x4aDC67696bA383F43DD60A9e78F2C97Fbbfc7cb1;
    address internal constant OWNER = 0x664C1791ad9189ebAEB63716d29EeCaA405c732D;
    address internal constant CANONICAL_POOL_MANAGER = 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408;

    ParityHook hook;
    LVRReserve reserve;
    ReputationLedger ledger;
    ChainlinkPriceAdapter adapter;

    PoolKey poolKey;
    PoolId poolId;
    uint256 lpTokenId;

    MockERC20 token0;
    MockERC20 token1;

    function setUp() public {
        vm.skip(block.chainid == 31_337); // skip on plain Anvil (no fork)
        vm.skip(PARITY_HOOK.code.length == 0); // skip when not forked

        // Canonical v4 artifacts on the fork (Deployers resolves these by chain id 84532).
        deployArtifactsAndLabel();

        _useDeployed();
        _createPoolAndSeed();
    }

    function deployArtifactsAndLabel() internal {
        deployPermit2();
        deployPoolManager();
        deployPositionManager();
        deployRouter();
    }

    function _useDeployed() internal {
        // Assert the deployed contracts are mutually coherent before driving them.
        hook = ParityHook(PARITY_HOOK);
        reserve = LVRReserve(LVR_RESERVE);
        adapter = ChainlinkPriceAdapter(CHAINLINK_ADAPTER);
        ledger = ReputationLedger(hook.ledger());

        // ---- Wiring proof (deployed graph) ----
        assertEq(address(hook.poolManager()), CANONICAL_POOL_MANAGER, "hook must be pinned to canonical PoolManager");
        assertEq(address(hook.reserve()), LVR_RESERVE, "hook must point at the deployed reserve");
        assertEq(address(reserve.hook()), PARITY_HOOK, "reserve must point back at the deployed hook");
        assertEq(address(reserve.priceAdapter()), CHAINLINK_ADAPTER, "reserve must use the deployed adapter");
        assertEq(address(adapter.feed()), CHAINLINK_FEED, "adapter must wrap the live ETH/USD feed");
        assertEq(adapter.maxStalenessSeconds(), 3600, "one-hour staleness guard expected");

        // The Chainlink reference must be live & fresh — this is the non-circular verification anchor.
        (uint256 price18, uint256 updatedAt) = adapter.latestPrice18();
        assertGt(price18, 0, "live ETH/USD reference must be non-zero");
        assertTrue(block.timestamp - updatedAt <= adapter.maxStalenessSeconds(), "live feed must be fresh");

        // Governance: the deployer must control the hook and the ledger's score setter path.
        assertEq(hook.owner(), OWNER, "deployer must own the hook");
    }

    function _createPoolAndSeed() internal {
        // Two fresh 18-decimals mocks for a deterministic pool the deployed hook can serve.
        // (The deployed hook is pool-agnostic; it treats any pool on its canonical PoolManager.)
        MockERC20 a = new MockERC20("Parity Token A", "PTA", 18);
        MockERC20 b = new MockERC20("Parity Token B", "PTB", 18);
        if (a > b) (a, b) = (b, a);
        token0 = a;
        token1 = b;
        token0.mint(address(this), 1_000_000 ether);
        token1.mint(address(this), 1_000_000 ether);
        token0.approve(address(permit2), type(uint256).max);
        token1.approve(address(permit2), type(uint256).max);
        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);
        permit2.approve(address(token0), address(positionManager), type(uint160).max, type(uint48).max);
        permit2.approve(address(token1), address(positionManager), type(uint160).max, type(uint48).max);
        permit2.approve(address(token0), address(poolManager), type(uint160).max, type(uint48).max);
        permit2.approve(address(token1), address(poolManager), type(uint160).max, type(uint48).max);

        poolKey = PoolKey(
            Currency.wrap(address(token0)),
            Currency.wrap(address(token1)),
            3000,
            60,
            IHooks(PARITY_HOOK)
        );
        poolId = poolKey.toId();
        poolManager.initialize(poolKey, Constants.SQRT_PRICE_1_1);

        int24 tickLower = TickMath.minUsableTick(poolKey.tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(poolKey.tickSpacing);
        uint128 liquidity = 1_000e18;
        (uint256 amt0, uint256 amt1) = LiquidityAmounts.getAmountsForLiquidity(
            Constants.SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            liquidity
        );
        (lpTokenId,) = positionManager.mint(
            poolKey, tickLower, tickUpper, liquidity, amt0 + 1, amt1 + 1, address(this), block.timestamp, abi.encode(address(this))
        );
    }

    // ---- MVP treatment path against the deployed hook ----

    /// @dev A Flagged exact-input swap escrows its risk premium into the DEPLOYED LVRReserve,
    ///      and the same-block re-entry gate reverts (sandwich atomicity killed on the live hook).
    function test_deployed_hook_treats_flagged_flow_and_escrows_premium() public {
        address mallory = _makeSwapper(99);
        vm.prank(OWNER);
        ledger.forceSetScore(mallory, 100); // Flagged tier

        // First swap in this block passes freely and books a premium into the deployed reserve.
        uint256 amountIn = 5 ether;
        _swap(mallory, true, amountIn);

        uint256 premium = (amountIn * uint256(hook.flaggedPremiumBps())) / 10_000;
        assertEq(reserve.pendingsLength(), 1, "flagged exact-input must book one pending record");
        (, , uint256 recordedAmount, , , , , ) = reserve.getPending(0);
        assertEq(recordedAmount, premium, "deployed reserve must record the flag premium");

        // Same-block follow-up (second sandwich leg) must be rejected by the delay window.
        vm.startPrank(mallory, mallory);
        (bool ok, ) = address(swapRouter).call(
            abi.encodeCall(
                ISinglePoolExactIn.swapExactTokensForTokens,
                (2 ether, 0, true, poolKey, abi.encode(mallory), mallory, block.timestamp + 100)
            )
        );
        vm.stopPrank();
        assertFalse(ok, "same-block flagged re-entry must revert via the delay gate");

        // Verified/Flagged tier is delayed, so re-entry requires a later block.
        vm.roll(block.number + 1);
    }

    /// @dev Wiring + governance proof that does not need a pool.
    function test_deployed_wiring_is_live() public view {
        (uint256 price18,) = adapter.latestPrice18();
        assertGt(price18, 0);

        (uint32 v, , , , ) = reserve.config();
        assertGt(v, 0, "deployed reserve must have a verification window");

        assertTrue(address(hook.crossPoolOracle()) != address(0), "live hook must be wired to the cross-pool oracle");
    }

    /// @dev After the verification window elapses, the deployed reserve settles the pending record
    ///      (verified -> LP payout queued, or unverified -> rolled to LP fees) without reverting.
    ///      Outcome is feed-dependent (covered deterministically by LVRVerification.t.sol); what we
    ///      prove here is that the deployed settlement/donation plumbing runs end-to-end.
    function test_deployed_reserve_settles_after_window() public {
        address mallory = _makeSwapper(99);
        vm.prank(OWNER);
        ledger.forceSetScore(mallory, 100); // Flagged tier

        uint256 amountIn = 5 ether;
        _swap(mallory, true, amountIn);

        assertEq(reserve.pendingsLength(), 1, "must book one pending record");
        (, , , , , , , uint64 recordedBlock) = reserve.getPending(0);
        assertGt(uint256(recordedBlock), 0);

        // Can't settle inside the window.
        vm.expectRevert(LVRReserve.WindowNotElapsed.selector);
        reserve.settlePending(0);

        // Elapse the window and settle against the deployed reserve.
        (uint32 verifyBlocks, , , , ) = reserve.config();
        vm.roll(uint256(recordedBlock) + uint256(verifyBlocks) + 1);
        bool verified = reserve.settlePending(0);

        // Record is settled (zeroed) regardless of outcome — a second settle reverts.
        vm.expectRevert(LVRReserve.AlreadySettled.selector);
        reserve.settlePending(0);

        if (verified) {
            assertEq(reserve.payoutsLength(), 1, "verified premium must be queued as an LP payout");
            (uint256 paid, ) = reserve.distributeVerified(0, 100);
            assertTrue(paid > 0, "verified payout must distribute to the seeded LP");
        }
        // (unverified path: premium rolls directly into pool LP fees; nothing further to check)
    }

    // ---- Helpers (from ParityTest) ----

    function _makeSwapper(uint256 seed) internal returns (address swapper) {
        swapper = makeAddr(string.concat("swapper-", vm.toString(seed)));
        token0.mint(swapper, 1_000_000 ether);
        token1.mint(swapper, 1_000_000 ether);
        vm.startPrank(swapper);
        token0.approve(address(permit2), type(uint256).max);
        token1.approve(address(permit2), type(uint256).max);
        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);
        permit2.approve(address(token0), address(swapRouter), type(uint160).max, type(uint48).max);
        permit2.approve(address(token1), address(swapRouter), type(uint160).max, type(uint48).max);
        vm.stopPrank();
    }

    function _swap(address who, bool zeroForOne, uint256 amountIn) internal {
        vm.startPrank(who, who);
        swapRouter.swapExactTokensForTokens({
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
}
