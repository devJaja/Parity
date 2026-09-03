// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {console2} from "forge-std/console2.sol";
import {Script} from "forge-std/Script.sol";

import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";

/// @notice Canonical-token wrapper around the canonical WETH/USDC erc20s (6/18-dec), so the
///         seeder only needs the four functions it uses.
interface ICanonicalToken {
    function approve(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

/// @notice On-chain helper that initializes the real WETH/USDC pool on the deployed ParityHook
///         and mints a narrow concentrated LP, mirroring `test/PushLivePool.t.sol`.
///         Lives on-chain because EasyPosm's balance snapshots use `address(this)`, which
///         Foundry forbids inside a script contract.
///         The OWNER funds this seeder with USDC + WETH (canonical, real tokens), then calls
///         `seed()`. On success it sweeps any unused tokens + refunds back to the seeder.
contract CanonicalPoolSeeder {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using SafeCast for uint256;

    address public immutable owner;
    address public immutable usdc; // 6-dec
    address public immutable weth; // 18-dec
    address public immutable poolManager;
    address public immutable positionManager;
    address public immutable permit2;
    address public immutable router;
    address public immutable hookAddr;

    bool public seeded;

    constructor(
        address owner_,
        address usdc_,
        address weth_,
        address poolManager_,
        address positionManager_,
        address permit2_,
        address router_,
        address hook_
    ) {
        owner = owner_;
        usdc = usdc_;
        weth = weth_;
        poolManager = poolManager_;
        positionManager = positionManager_;
        permit2 = permit2_;
        router = router_;
        hookAddr = hook_;
    }

    /// @dev Initialize the pool at the live ~2400 USDC/WETH price and mint a concentrated LP
    ///      sized to the CANONICAL tokens actually held by this seeder. Requires the pool not
    ///      to be initialized yet. Any residual tokens are returned to the owner.
    function seed(
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint256 amount0Max,
        uint256 amount1Max
    ) external returns (PoolId poolId) {
        require(msg.sender == owner, "only owner");
        require(!seeded, "already seeded");

        ICanonicalToken(usdc).approve(permit2, type(uint256).max);
        ICanonicalToken(weth).approve(permit2, type(uint256).max);
        ICanonicalToken(usdc).approve(router, type(uint256).max);
        ICanonicalToken(weth).approve(router, type(uint256).max);
        IPermit2(permit2).approve(usdc, positionManager, type(uint160).max, type(uint48).max);
        IPermit2(permit2).approve(weth, positionManager, type(uint160).max, type(uint48).max);

        address c0 = usdc < weth ? usdc : weth;
        address c1 = usdc < weth ? weth : usdc;
        PoolKey memory key = PoolKey(Currency.wrap(c0), Currency.wrap(c1), 3000, 60, IHooks(hookAddr));
        poolId = key.toId();

        // Live ~2400 USDC/WETH (WETH-per-USDC 1/2400): sqrt price & tick from the fork proof.
        uint160 sqrtPriceX96 = 0x539bf7ccf3c0c8000000000;
        IPoolManager(poolManager).initialize(key, sqrtPriceX96);

        // Approve == mint via the POSM; POSM pulls the canonical tokens via Permit2.
        _mint(key, tickLower, tickUpper, liquidity, amount0Max, amount1Max);

        seeded = true;

        // Sweep any residual (and unwrap nothing since both are canonical ERC20s).
        _sweep(usdc);
        _sweep(weth);
    }

    function _mint(
        PoolKey memory key,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint256 amount0Max,
        uint256 amount1Max
    ) internal {
        // POSM mint action sequence (EasyPosm parity): MINT_POSITION, SETTLE_PAIR, SWEEP, SWEEP.
        bytes[] memory params = new bytes[](4);
        params[0] = abi.encode(key, tickLower, tickUpper, liquidity, amount0Max, amount1Max, owner, abi.encode(owner));
        params[1] = abi.encode(key.currency0, key.currency1);
        params[2] = abi.encode(key.currency0, owner);
        params[3] = abi.encode(key.currency1, owner);

        IPositionManager(positionManager).modifyLiquidities(
            abi.encode(
                abi.encodePacked(
                    uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR), uint8(Actions.SWEEP), uint8(Actions.SWEEP)
                ),
                params
            ),
            block.timestamp + 100
        );
    }

    function _sweep(address token) internal {
        uint256 bal = ICanonicalToken(token).balanceOf(address(this));
        if (bal > 0) {
            ICanonicalToken(token).approve(address(this), 0);
            // transfer to owner if possible (solmate helper below)
            _transfer(token, bal);
        }
    }

    function _transfer(address token, uint256 amount) internal {
        (bool ok,) = token.call(abi.encodeWithSelector(bytes4(keccak256("transfer(address,uint256)")), owner, amount));
        require(ok, "sweep failed");
    }

    /// @notice Pull funding into this seeder (owner-only convenience).
    function pull(uint256 usdcAmount, uint256 wethAmount) external {
        require(msg.sender == owner, "only owner");
        _transferFrom(usdc, msg.sender, address(this), usdcAmount);
        _transferFrom(weth, msg.sender, address(this), wethAmount);
    }

    function _transferFrom(address token, address from, address to, uint256 amount) internal {
        (bool ok,) =
            token.call(abi.encodeWithSelector(bytes4(keccak256("transferFrom(address,address,uint256)")), from, to, amount));
        require(ok, "transferFrom failed");
    }
}

/// @notice Deploys a CanonicalPoolSeeder owned by the deployer, then (optionally pulls funding).
///         `seed(...)` is called in a SEPARATE broadcast after the owner funds the seeder.
///   Steps:
///     1.  forge script script/SeedParityPool.s.sol:DeploySeeder --rpc-url $BASE_RPC \
///             --private-key $PRIVATE_KEY --broadcast
///        (logs the CanonicalPoolSeeder address; fund it with USDC + WETH next)
///     2.  fund CanonicalPoolSeeder with USDC + WETH (via token transfer or seeder.pull()),
///        then set PARITY_SEEDER=<seeder address> in .env
///     3.  forge script script/SeedParityPool.s.sol:SeedPool --rpc-url $BASE_RPC \
///             --private-key $PRIVATE_KEY --broadcast
contract DeploySeeder is Script {
    // Canonical Base Sepolia addresses (overridable via env).
    address internal constant HOOK = 0x95E4a3Aa11c44EB8de369830E9f956703F5585cC;
    address internal constant USDC_ = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;
    address internal constant WETH_ = 0x4200000000000000000000000000000000000006;
    address internal constant PM = 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408;
    address internal constant POSM = 0x4B2C77d209D3405F41a037Ec6c77F7F5b8e2ca80;
    address internal constant PERMIT2_ = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address internal constant ROUTER = 0x71cD4Ea054F9Cb3D3BF6251A00673303411A7DD9;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        address hook = vm.envOr("PARITY_HOOK", HOOK);
        address usdc = vm.envOr("PARITY_USDC", USDC_);
        address weth = vm.envOr("PARITY_WETH", WETH_);
        address pm = vm.envOr("PARITY_POOL_MANAGER", PM);
        address posm = vm.envOr("PARITY_POSM", POSM);
        address permit2 = vm.envOr("PARITY_PERMIT2", PERMIT2_);
        address router = vm.envOr("PARITY_SWAP_ROUTER", ROUTER);

        vm.startBroadcast(pk);
        CanonicalPoolSeeder seeder = new CanonicalPoolSeeder(
            deployer, usdc, weth, pm, posm, permit2, router, hook
        );
        vm.stopBroadcast();

        console2.log("CanonicalPoolSeeder:", address(seeder));
        console2.log("  owner:", deployer);
        console2.log("  hook :", hook);
    }
}

/// @notice Seed the WETH/USDC pool for the deployed ParityHook using the (already funded)
///         deployed CanonicalPoolSeeder. See DeploySeeder for the two-step flow.
contract SeedPool is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address seederAddr = vm.envAddress("PARITY_SEEDER");
        CanonicalPoolSeeder seeder = CanonicalPoolSeeder(seederAddr);

        // Narrow concentrated range around the live price; liquidity sized to seeder funding.
        int24 priceTick = -77_880;
        int24 tickLower = priceTick - 3 * 60;
        int24 tickUpper = priceTick + 3 * 60;
        uint128 liquidity = 1e11;
        (uint256 amt0, uint256 amt1) = _amountsFor(tickLower, tickUpper, liquidity);

        vm.startBroadcast(pk);
        PoolId id = seeder.seed(tickLower, tickUpper, liquidity, amt0 + 1, amt1 + 1);
        vm.stopBroadcast();

        console2.log("poolId:");
        console2.logBytes32(PoolId.unwrap(id));
        console2.log("pool seeded at live WETH/USDC price.");
    }

    function _amountsFor(int24 tickLower, int24 tickUpper, uint128 liquidity)
        internal
        pure
        returns (uint256 amt0, uint256 amt1)
    {
        uint160 sqrtPriceX96 = 0x539bf7ccf3c0c8000000000;
        return LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96, TickMath.getSqrtPriceAtTick(tickLower), TickMath.getSqrtPriceAtTick(tickUpper), liquidity
        );
    }
}
