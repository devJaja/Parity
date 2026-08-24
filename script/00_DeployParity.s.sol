// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import {Deployers} from "test/utils/Deployers.sol";
import {EasyPosm} from "test/utils/libraries/EasyPosm.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {MockAggregator} from "../test/mocks/MockAggregator.sol";

import {AggregatorV3Interface, ChainlinkPriceAdapter} from "../src/ChainlinkPriceAdapter.sol";
import {ParityHook} from "../src/ParityHook.sol";
import {LVRReserve} from "../src/LVRReserve.sol";

/// @notice Deploys the full Parity stack:
///         ChainlinkPriceAdapter -> LVRReserve -> ParityHook (CREATE2-mined address),
///         then optionally initializes a demo pool and seeds a full-range LP.
///
/// Environment variables:
///   PARITY_POOL_MANAGER   canonical IPoolManager   (required off-Anvil)
///   PARITY_FEED           Chainlink AggregatorV3   (required off-Anvil)
///   PARITY_STALENESS      max oracle staleness s   (default 3600)
///   PARITY_NO_SEED        set to 1 to skip demo-pool LP seeding
contract DeployParity is Script, Deployers {
    /// @dev Arachnid's Deterministic Deployment Proxy (forge's default CREATE2 route).
    address internal constant PROXY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function run() external {
        uint256 deployerKey = vm.envOr("PRIVATE_KEY", uint256(0));
        if (deployerKey != 0) vm.startBroadcast(deployerKey);
        else vm.startBroadcast();

        bool isAnvil = block.chainid == 31_337;

        if (vm.envOr("PARITY_POOL_MANAGER", address(0)) != address(0)) {
            require(vm.envAddress("PARITY_POOL_MANAGER").code.length > 0, "invalid PARITY_POOL_MANAGER");
        } else {
            require(isAnvil, "PARITY_POOL_MANAGER required on production chains");
            deployArtifacts(); // Permit2 + PoolManager + PositionManager + Router
        }

        ChainlinkPriceAdapter adapter = _deployAdapter(isAnvil);
        LVRReserve reserve = new LVRReserve(poolManager, adapter, msg.sender);
        ParityHook hook = _deployMinedHook(reserve, isAnvil);
        reserve.setHook(address(hook));

        _log(adapter, reserve, hook);

        if (!vm.envOr("PARITY_NO_SEED", false) && address(positionManager) != address(0)) {
            new ParitySeeder().seed(poolManager, positionManager, hook, msg.sender);
        } else {
            console2.log("  (skipping demo pool / LP seeding)");
        }

        vm.stopBroadcast();
    }

    function _deployAdapter(bool isAnvil) internal returns (ChainlinkPriceAdapter) {
        uint256 staleness = vm.envOr("PARITY_STALENESS", uint256(3600));
        if (!isAnvil) {
            address feed = vm.envOr("PARITY_FEED", address(0));
            require(feed != address(0), "PARITY_FEED required on production chains");
            require(feed.code.length > 0, "no code at PARITY_FEED");
            return new ChainlinkPriceAdapter(AggregatorV3Interface(feed), staleness);
        }
        // Reference price 1.0 with 8 decimals, matching standard Chainlink feeds.
        return new ChainlinkPriceAdapter(AggregatorV3Interface(address(new MockAggregator(8, 1e8))), staleness);
    }

    function _deployMinedHook(LVRReserve reserve, bool isAnvil) internal returns (ParityHook) {
        // Broadcasted `new C{salt}` cannot originate from the ephemeral script
        // contract, so we mine against - and deploy through - Arachnid's
        // Deterministic Deployment Proxy (predeployed on every major chain;
        // etched locally when missing, e.g. fresh Anvil).
        if (PROXY.code.length == 0) {
            require(isAnvil, "Deterministic Deployment Proxy missing on this chain");
            vm.etch(
                PROXY,
                hex"7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf3"
            );
        }

        bytes memory constructorArgs = abi.encode(poolManager, address(reserve), msg.sender);

        (address expected, bytes32 salt) =
            HookMiner.find(PROXY, _parityFlags(), type(ParityHook).creationCode, constructorArgs);
        (bool ok,) = PROXY.call(abi.encodePacked(salt, type(ParityHook).creationCode, constructorArgs));
        require(ok && expected.code.length > 0, "hook deployment failed");

        return ParityHook(expected);
    }

    function _log(ChainlinkPriceAdapter adapter, LVRReserve reserve, ParityHook hook) internal view {
        console2.log("Parity deployed:");
        console2.log("  owner                ", msg.sender);
        console2.log("  ChainlinkPriceAdapter", address(adapter));
        console2.log("  LVRReserve           ", address(reserve));
        console2.log("  ParityHook           ", address(hook));
        console2.log("  PoolManager          ", address(poolManager));
    }

    /// @dev Template artifacts are etched at canonical addresses; only possible on Anvil.
    function _etch(address target, bytes memory bytecode) internal override {
        require(block.chainid == 31_337, "etch unsupported on this network");
        vm.rpc("anvil_setCode", string.concat('["', vm.toString(target), '",', '"', vm.toString(bytecode), '"]'));
    }

    /// @dev Hook permissions required by Parity, encoded as address flags.
    ///      Must match ParityTest._parityFlags so mined addresses are reproducible.
    function _parityFlags() internal pure returns (uint160) {
        return uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
                | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
        ) ^ (0x5041 << 144); // "PA" namespace to avoid collisions
    }
}

/// @notice Deploys demo tokens, initializes a pool, and seeds a full-range LP.
///         Lives on-chain so EasyPosm's balance snapshots reference real code
///         instead of the ephemeral script contract.
contract ParitySeeder {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;

    IPermit2 internal constant PERMIT2 = IPermit2(0x000000000022D473030F116dDEE9F6B43aC78BA3);

    struct MintJob {
        IPositionManager posm;
        PoolKey key;
        int24 tickLower;
        int24 tickUpper;
        uint256 amt0Max;
        uint256 amt1Max;
        address owner;
    }

    MintJob internal job;

    function seed(IPoolManager pm, IPositionManager posm, IHooks hook, address owner) external returns (PoolId) {
        MockERC20 tokenA = new MockERC20("Parity Token A", "PTA", 18);
        MockERC20 tokenB = new MockERC20("Parity Token B", "PTB", 18);
        if (address(tokenA) > address(tokenB)) (tokenA, tokenB) = (tokenB, tokenA);

        PoolKey memory key = PoolKey(Currency.wrap(address(tokenA)), Currency.wrap(address(tokenB)), 3000, 60, hook);
        pm.initialize(key, Constants.SQRT_PRICE_1_1);
        console2.logBytes32(PoolId.unwrap(key.toId()));

        tokenA.mint(address(this), type(uint256).max / 4);
        tokenB.mint(address(this), type(uint256).max / 4);
        tokenA.approve(address(PERMIT2), type(uint256).max);
        tokenB.approve(address(PERMIT2), type(uint256).max);
        PERMIT2.approve(address(tokenA), address(posm), type(uint160).max, type(uint48).max);
        PERMIT2.approve(address(tokenB), address(posm), type(uint160).max, type(uint48).max);

        int24 tickLower = TickMath.minUsableTick(60);
        int24 tickUpper = TickMath.maxUsableTick(60);
        (uint256 amt0, uint256 amt1) = LiquidityAmounts.getAmountsForLiquidity(
            Constants.SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            100e18
        );

        job = MintJob(posm, key, tickLower, tickUpper, amt0 + 1, amt1 + 1, owner);
        this.executeMint();
        console2.log("  Seeded full-range LP");

        return key.toId();
    }

    /// @notice hookData carries the true LP identity through the PositionManager.
    function executeMint() external {
        job.posm.mint(
            job.key,
            job.tickLower,
            job.tickUpper,
            100e18,
            job.amt0Max,
            job.amt1Max,
            job.owner,
            block.timestamp,
            abi.encode(job.owner)
        );
    }
}
