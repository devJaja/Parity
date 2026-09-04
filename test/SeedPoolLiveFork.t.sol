// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";

import {CanonicalPoolSeeder} from "../script/SeedParityPool.s.sol";
import {Deployers} from "./utils/Deployers.sol";

interface IFiatToken {
    function configureMinter(address minter, uint256 minterAllowedAmount) external;
    function mint(address to, uint256 amount) external;
}
interface IWETH {
    function deposit() external payable;
    function approve(address, uint256) external returns (bool);
}
interface IERC20ish {
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

/// @dev Fork proof that the deployer-owned CanonicalPoolSeeder (DeploySeeder + SeedPool scripts)
///      seeds a REAL canonical WETH/USDC pool and that a subsequent canonical swap against the
///      DEPLOYED ParityHook SUCCEEDS (no revert: pool initialized + LP in range).
///      On the live chain the owner must first fund the seeder with USDC + WETH; on this fork we
///      mint canonical USDC (masterMinter) + wrap fork ETH to simulate that funding.
///      Cheap band: liquidity=1e9, tick±120, ~$186 USDC + 0.0002 WETH funding.
///      Run: forge test --match-path test/SeedPoolLiveFork.t.sol --fork-url $BASE_RPC
contract SeedPoolLiveForkTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    address internal constant PARITY_HOOK = 0x95E4a3Aa11c44EB8de369830E9f956703F5585cC;
    address internal constant OWNER = 0x664C1791ad9189ebAEB63716d29EeCaA405c732D;
    address internal constant WETH = 0x4200000000000000000000000000000000000006;
    address internal constant USDC = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;
    address internal constant USDC_MASTER_MINTER = 0xD52081E444544C744B3ECbb0dE7fF06e63ef4E1c;

    function setUp() public {
        vm.skip(block.chainid == 31_337);
        vm.skip(PARITY_HOOK.code.length == 0);

        deployPermit2();
        deployPoolManager();
        deployPositionManager();
        deployRouter();
    }

    function test_seeder_seeds_and_swap_succeeds() public {
        // Deploy the seeder owned by the deployer (as DeploySeeder.run() does).
        CanonicalPoolSeeder seeder = new CanonicalPoolSeeder(
            OWNER, USDC, WETH, address(poolManager), address(positionManager),
            address(permit2), address(swapRouter), PARITY_HOOK
        );

        // Simulate the owner having funded the seeder (cheap 1e9 band: ~$186 USDC + 0.0002 WETH).
        _fund(address(seeder), 300e6, 0.001e18);

        // Owner seeds (mirrors SeedPool.run() at the live price: 1e9 liquidity, tick ±120).
        PoolKey memory key = PoolKey(Currency.wrap(USDC), Currency.wrap(WETH), 3000, 60, IHooks(PARITY_HOOK));
        int24 priceTick = -77_880;
        int24 tickLower = priceTick - 2 * 60;
        int24 tickUpper = priceTick + 2 * 60;
        uint128 liquidity = 1e9;
        (uint256 amt0, uint256 amt1) = _amountsFor(tickLower, tickUpper, liquidity);

        vm.prank(OWNER);
        seeder.seed(tickLower, tickUpper, liquidity, amt0 + 1, amt1 + 1);

        console2.log("seeder.seed() SUCCEEDED; pool initialized + LP minted");

        // A real canonical swap now succeeds against the deployed hook (would revert pre-seed).
        address trader = makeAddr("trader");
        _fund(trader, 200e6, 0);

        vm.startPrank(trader);
        IERC20ish(USDC).approve(address(swapRouter), type(uint256).max);
        IERC20ish(USDC).approve(address(permit2), type(uint256).max);
        swapRouter.swapExactTokensForTokens({
            amountIn: 20e6, // $20 USDC in (cheap band fits ~$20 before price exits range)
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: key,
            hookData: abi.encode(trader),
            receiver: trader,
            deadline: block.timestamp + 100
        });
        uint256 wethRecv = _wethReceived(trader);
        assertGt(wethRecv, 0, "trader must receive WETH from the seeded pool");
        console2.log("post-seed swap SUCCEEDED; WETH received:", wethRecv);
        vm.stopPrank();
    }

    function _fund(address to, uint256 usdcAmt, uint256 wethAmt) internal {
        if (wethAmt > 0) {
            vm.deal(to, wethAmt + 1 ether);
            vm.startPrank(to);
            IWETH(WETH).deposit{value: wethAmt}();
            vm.stopPrank();
        }
        // canonical USDC via masterMinter (simulates owner-held USDC funding the seeder)
        vm.startPrank(USDC_MASTER_MINTER);
        IFiatToken(USDC).configureMinter(address(this), type(uint256).max);
        vm.stopPrank();
        if (usdcAmt > 0) {
            vm.prank(address(this));
            IFiatToken(USDC).mint(to, usdcAmt);
        }
    }

    function _wethReceived(address who) internal view returns (uint256) {
        return IERC20ish(WETH).balanceOf(who);
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
