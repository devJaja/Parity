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
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IECDSAStakeRegistry} from "../src/eigenlayer/IECDSAStakeRegistry.sol";
import {ParityCrossPoolOracle} from "../src/eigenlayer/ParityCrossPoolOracle.sol";
import {CctpBridge, ITokenMessengerV2} from "../src/circle/CctpBridge.sol";
import {MockStakeRegistry} from "../test/mocks/MockStakeRegistry.sol";
import {MockTokenMessenger} from "../test/mocks/MockCctp.sol";

/// @notice Deploys the full Parity stack:
///         ChainlinkPriceAdapter -> LVRReserve -> ParityHook (CREATE2-mined address),
///         then optionally initializes a demo pool and seeds a full-range LP.
///
/// Environment variables:
///   PARITY_POOL_MANAGER   IPoolManager to target   (required off-Anvil; Permit2,
///                           PositionManager and swap router resolve canonically)
///   PARITY_FEED           Chainlink AggregatorV3   (required off-Anvil)
///   PARITY_STALENESS      max oracle staleness s   (default 3600)
///   PARITY_NO_SEED        set to 1 to skip demo-pool LP seeding
contract DeployParity is Script, Deployers {
    /// @dev Arachnid's Deterministic Deployment Proxy (forge's default CREATE2 route).
    address internal constant PROXY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    // Deployed stack, exposed for downstream scripts (live demos, smoke tests).
    ChainlinkPriceAdapter internal adapter;
    LVRReserve internal reserve;
    ParityHook internal hook;

    // Partner modules (canonical addresses off-Anvil; local stand-ins on Anvil).
    IERC20Metadata internal usdc;
    CctpBridge internal cctpBridge;
    MockStakeRegistry internal stakeRegistry;
    ParityCrossPoolOracle internal crossPoolOracle;

    function run() external virtual {
        _deployStack();
    }

    function _deployStack() internal {
        uint256 deployerKey = vm.envOr("PRIVATE_KEY", uint256(0));
        if (deployerKey != 0) vm.startBroadcast(deployerKey);
        else vm.startBroadcast();

        bool isAnvil = block.chainid == 31_337;

        if (vm.envOr("PARITY_POOL_MANAGER", address(0)) != address(0)) {
            poolManager = IPoolManager(vm.envAddress("PARITY_POOL_MANAGER"));
            require(address(poolManager).code.length > 0, "invalid PARITY_POOL_MANAGER");
        } else {
            require(isAnvil, "PARITY_POOL_MANAGER required on production chains");
            deployPoolManager();
        }

        // Permit2, PositionManager and the swap router resolve to the canonical
        // deployments on non-Anvil chains (and local stand-ins on Anvil).
        deployPermit2();
        deployPositionManager();
        deployRouter();

        adapter = _deployAdapter(isAnvil);
        reserve = new LVRReserve(poolManager, adapter, msg.sender);
        hook = _deployMinedHook(reserve, isAnvil);
        reserve.setHook(hook);

        // The PositionManager attests position owners through hookData so LP attribution
        // also works for smart wallets, whose tx.origin differs from the owner address.
        hook.setRouterAuthorization(address(positionManager), true);

        _deployPartnerModules(hook, reserve);
        _log(adapter, reserve, hook);

        if (!vm.envOr("PARITY_NO_SEED", false) && address(positionManager) != address(0)) {
            new ParitySeeder().seed(poolManager, positionManager, hook, msg.sender);
        } else {
            console2.log("  (skipping demo pool / LP seeding)");
        }

        vm.stopBroadcast();
    }

    /// @dev Optional partner integrations, enabled per-chain by environment variables:
    ///   PARITY_STAKE_REGISTRY   ECDSAStakeRegistry proxy of the Parity AVS on this chain.
    ///                           Deploys the cross-pool oracle consumer and wires it into
    ///                           the hook, which forwards fresh scores to the ledger.
    ///                           On Anvil a local MockStakeRegistry stand-in is deployed.
    ///   PARITY_USDC             Native USDC on this chain (Anvil: local 6-decimals mock).
    ///   PARITY_TOKEN_MESSENGER  Canonical Circle CCTP TokenMessenger on this chain
    ///                           (Anvil: local MockTokenMessenger). Deploys the reserve
    ///                           rebalance bridge, authorizes it on the reserve, and opens
    ///                           destination domain 6 (Base) for demo flows.
    function _deployPartnerModules(ParityHook hook_, LVRReserve reserve_) internal {
        bool isAnvil = block.chainid == 31_337;
        address deployer = msg.sender;

        // ---- Circle CCTP -------------------------------------------------
        usdc = IERC20Metadata(vm.envOr("PARITY_USDC", address(0)));
        ITokenMessengerV2 messenger = ITokenMessengerV2(vm.envOr("PARITY_TOKEN_MESSENGER", address(0)));
        if (isAnvil && address(usdc) == address(0)) {
            usdc = IERC20Metadata(address(new MockERC20("USD Coin", "USDC", 6)));
            messenger = ITokenMessengerV2(address(new MockTokenMessenger()));
        }
        if (address(usdc) != address(0) && address(messenger) != address(0)) {
            cctpBridge = new CctpBridge(usdc, reserve_, messenger, deployer);
            reserve_.setBridge(address(cctpBridge));
            if (isAnvil) cctpBridge.setDestinationDomain(6, true);
            console2.log("  USDC:          ", address(usdc));
            console2.log("  CctpBridge:    ", address(cctpBridge));
        }

        // ---- EigenLayer AVS consumer ------------------------------------
        address registryAddr = vm.envOr("PARITY_STAKE_REGISTRY", address(0));
        if (isAnvil && registryAddr == address(0)) {
            stakeRegistry = new MockStakeRegistry();
            registryAddr = address(stakeRegistry);
            console2.log("  StakeRegistry: ", registryAddr);
        }
        if (registryAddr != address(0)) {
            crossPoolOracle =
                new ParityCrossPoolOracle(IECDSAStakeRegistry(registryAddr), vm.envOr("PARITY_FRESHNESS", uint256(50)), deployer);
            hook_.setCrossPoolOracle(crossPoolOracle);
            console2.log("  CrossPoolOracle:", address(crossPoolOracle));
        }
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
        vm.etch(target, bytecode);
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
