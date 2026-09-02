// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {console2} from "forge-std/console2.sol";

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";

import {ReputationLedger} from "../src/ReputationLedger.sol";
import {ParityCrossPoolOracle} from "../src/eigenlayer/ParityCrossPoolOracle.sol";
import {MockTokenMessenger} from "../test/mocks/MockCctp.sol";
import {EasyPosm} from "test/utils/libraries/EasyPosm.sol";

import {DeployParity} from "./00_DeployParity.s.sol";

/// @dev On-chain helper: EasyPosm's balance snapshots use `address(this)`, which Foundry
///      forbids in script contracts — so the LP seeding lives on a deployed contract,
///      exactly like ParitySeeder.
contract DemoLp {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;

    function seed(IPoolManager pm, IPositionManager posm, IHooks hookAddr, address owner)
        external
        returns (PoolKey memory key, MockERC20 tokenA, MockERC20 tokenB)
    {
        (key, tokenA, tokenB) = _createPool(pm, hookAddr);
        _approveAll(tokenA, tokenB, posm);
        _mintFullRange(posm, key, owner);
    }

    function _createPool(IPoolManager pm, IHooks hookAddr)
        private
        returns (PoolKey memory key, MockERC20 tokenA, MockERC20 tokenB)
    {
        tokenA = new MockERC20("Demo Token A", "DTA", 18);
        tokenB = new MockERC20("Demo Token B", "DTB", 18);
        if (address(tokenA) > address(tokenB)) (tokenA, tokenB) = (tokenB, tokenA);
        key = PoolKey(Currency.wrap(address(tokenA)), Currency.wrap(address(tokenB)), 3000, 60, hookAddr);
        pm.initialize(key, Constants.SQRT_PRICE_1_1);
    }

    function _approveAll(MockERC20 tokenA, MockERC20 tokenB, IPositionManager posm) private {
        tokenA.mint(address(this), type(uint256).max / 4);
        tokenB.mint(address(this), type(uint256).max / 4);
        IPermit2 p2 = IPermit2(0x000000000022D473030F116dDEE9F6B43aC78BA3);
        tokenA.approve(address(p2), type(uint256).max);
        tokenB.approve(address(p2), type(uint256).max);
        p2.approve(address(tokenA), address(posm), type(uint160).max, type(uint48).max);
        p2.approve(address(tokenB), address(posm), type(uint160).max, type(uint48).max);
    }

    function _mintFullRange(IPositionManager posm, PoolKey memory key, address owner) private {
        // EasyPosm packs calldata into structs to dodge stack-too-deep on wide calls.
        posm.mint(
            key,
            TickMath.minUsableTick(key.tickSpacing),
            TickMath.maxUsableTick(key.tickSpacing),
            100e18,
            type(uint256).max,
            type(uint256).max,
            owner,
            block.timestamp,
            abi.encode(owner)
        );
    }
}

/// @notice Live end-to-end demonstration on a running chain (Anvil by default):
///     1. toxic flow detected -> Flagged tier -> ordering delay + premium escrowed
///     2. Chainlink-referenced N-block verification settles the premium
///     3. verified premiums paid out to in-range LPs (unverified roll to LP fees)
///     4. Circle CCTP: idle USDC rebalanced cross-domain, minted USDC swept back
///     5. EigenLayer AVS: quorum-attested cross-pool score seeds a fresh address,
///        which then receives Trusted treatment from its first swap
contract LiveDemo is DeployParity {
    using PoolIdLibrary for PoolKey;

    uint256 internal constant ATTACKER_KEY = 0xA7AC4;
    uint256 internal constant FRESH_KEY = 0xFE057;
    /// @dev Anvil's default funded key, used when PRIVATE_KEY is unset.
    uint256 internal constant ANVIL_DEFAULT_KEY = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;

    uint256 internal govKey;

    function run() external override {
        // Pin the deployer identity so contract ownership and later keyed broadcasts
        // share one address (env key wins; bare Anvil falls back to its funded #0).
        if (vm.envOr("PRIVATE_KEY", uint256(0)) == 0) {
            vm.setEnv("PRIVATE_KEY", vm.toString(ANVIL_DEFAULT_KEY));
        }
        govKey = vm.envUint("PRIVATE_KEY");

        _deployStack(); // full stack + partner modules live (broadcast closed inside)

        vm.startBroadcast(govKey);
        // ------------------------------------------------------------------
        // Pool + seeded full-range LP attributed to this deployer
        // ------------------------------------------------------------------
        (PoolKey memory key, MockERC20 tokenA,) = new DemoLp().seed(
            poolManager, positionManager, IHooks(address(hook)), msg.sender
        );
        console2.log("[1] pool live with seeded LP:");
        console2.logBytes32(PoolId.unwrap(key.toId()));
        vm.stopBroadcast();

        _runToxicFlowAndVerification(key, tokenA);
        _runCctpRoundTrip();
        _attestAndSwapAsTrusted(key, tokenA);

        console2.log("LIVE DEMO COMPLETE - all modules exercised on-chain");
    }

    /// @dev Toxic flow -> Flagged premium escrowed -> Chainlink-referenced verification
    ///      -> LP compensation (verified) or donation to LP fees (unverified). Identities
    ///      are switched via keyed broadcasts (prank is forbidden for broadcasted txs).
    function _runToxicFlowAndVerification(PoolKey memory key, MockERC20 tokenA) internal {
        address attacker = vm.addr(ATTACKER_KEY);

        // Governance marks the address toxic -> Flagged tier.
        vm.startBroadcast(govKey);
        hook.ledger().forceSetScore(attacker, 100);
        vm.stopBroadcast();

        // Attacker swaps; the ordering delay must have elapsed by now.
        vm.roll(block.number + 2 + hook.flaggedExtraGapBlocks());
        vm.startBroadcast(ATTACKER_KEY);
        tokenA.mint(attacker, 1_000_000e18);
        tokenA.approve(address(swapRouter), type(uint256).max);
        swapRouter.swapExactTokensForTokens({
            amountIn: 5_000e18,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: key,
            hookData: abi.encode(attacker),
            receiver: attacker,
            deadline: block.timestamp + 100
        });
        vm.stopBroadcast();

        (, , uint256 premAmount, , , , , ) = reserve.getPending(0);
        require(premAmount > 0, "expected escrowed flagged premium");
        console2.log("[2] flagged swap executed; premium escrowed:", premAmount);

        // Verification window elapses, then anyone settles and distributes.
        (uint32 verifyBlocks, , , , ) = reserve.config();
        vm.roll(block.number + verifyBlocks);
        vm.startBroadcast(govKey);
        bool verified = reserve.settlePending(0);
        if (verified) {
            (uint256 paid,) = reserve.distributeVerified(0, 100);
            console2.log("[3] VERIFIED LVR -> LP compensation paid:", paid);
            require(paid > 0, "LP payout expected");
            (, , , uint256 distributed, , bool complete) = reserve.getPayout(0);
            require(complete, "payout must be fully settled");
            console2.log("    settled amount:", distributed);
        } else {
            console2.log("[3] unverified (within noise) -> premium rolled to LP fees");
        }
        vm.stopBroadcast();
    }

    /// @dev Circle CCTP round trip: burn idle USDC toward domain 6, then (simulating the
    ///      destination arrival minted by Circle's MessageTransmitter) sweep it back in.
    function _runCctpRoundTrip() internal {
        vm.startBroadcast(govKey); // rebalance is owner-gated
        MockERC20(address(usdc)).mint(address(reserve), 1_000e6); // e.g. accumulated USDC premiums
        cctpBridge.rebalance(400e6, 6);

        MockERC20(address(usdc)).mint(address(cctpBridge), 600e6); // arrival: Circle mints to bridge
        cctpBridge.sweepMintedUsdc();
        vm.stopBroadcast();

        (uint256 burnedAmt,, bytes32 recipient,,,,,) =
            MockTokenMessenger(address(cctpBridge.tokenMessenger())).burns(1);
        require(burnedAmt == 400e6 && recipient == bytes32(uint256(uint160(address(cctpBridge)))), "CCTP burn mismatch");
        console2.log("[4] CCTP burn live; 400 USDC en route to domain 6");
        require(usdc.balanceOf(address(reserve)) >= 1_200e6, "swept USDC must be back in the reserve");
        console2.log("    minted USDC swept back into reserve");
    }

    /// @dev Registers a 3-operator set on the (mock) stake registry, submits a quorum-signed
    ///      cross-pool reputation attestation for a fresh address, then proves the seeded
    ///      Trusted tier live with two same-block swaps (Neutral flow would hit the delay).
    function _attestAndSwapAsTrusted(PoolKey memory key, MockERC20 tokenA) internal {
        (uint256 pkA, uint256 pkB, uint256 pkC) = (0x0E9A, 0x0E9B, 0x0E9C);

        address fresh = vm.addr(FRESH_KEY);
        uint256 nonce = crossPoolOracle.nextNonce();
        bytes32 digest = keccak256(
            abi.encode(
                crossPoolOracle.attestationDomain(),
                block.chainid,
                address(crossPoolOracle),
                fresh,
                int256(800),
                uint32(block.number),
                nonce
            )
        );
        address[] memory ops = new address[](3);
        bytes[] memory sigs = new bytes[](3);
        uint256[3] memory pks = [pkA, pkB, pkC];
        for (uint256 i; i < 3; ++i) {
            ops[i] = vm.addr(pks[i]);
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(pks[i], digest);
            sigs[i] = abi.encodePacked(r, s, v);
        }
        for (uint256 i; i < 3; ++i) {
            for (uint256 j = i + 1; j < 3; ++j) {
                if (ops[j] < ops[i]) {
                    (ops[i], ops[j]) = (ops[j], ops[i]);
                    (sigs[i], sigs[j]) = (sigs[j], sigs[i]);
                }
            }
        }

        vm.startBroadcast(govKey);
        stakeRegistry.setOperator(vm.addr(pkA), vm.addr(pkA), 40e18);
        stakeRegistry.setOperator(vm.addr(pkB), vm.addr(pkB), 30e18);
        stakeRegistry.setOperator(vm.addr(pkC), vm.addr(pkC), 30e18);
        crossPoolOracle.attestReputation(fresh, 800, uint32(block.number), nonce, ops, sigs);
        vm.stopBroadcast();

        (bool isFresh, int256 attScore) = crossPoolOracle.freshScore(fresh);
        require(isFresh && attScore == 800, "attestation must be live and fresh");
        console2.log("[5] AVS attestation verified live for fresh address, score:", uint256(attScore));

        // The fresh address swaps under its own key: tx.origin == msg.sender corroborates
        // the hookData claim, the hook seeds 800 from the oracle, and Trusted treatment
        // lets a second same-block swap through (Neutral flow would be delayed).
        vm.startBroadcast(FRESH_KEY);
        tokenA.mint(fresh, 10_000e18);
        tokenA.approve(address(swapRouter), type(uint256).max);
        _swapOnce(key, fresh, 0.05e18);
        _swapOnce(key, fresh, 0.05e18);
        vm.stopBroadcast();
        console2.log("    same-block double-swap passed: Trusted treatment live");
        console2.log("    ledger score after seeding+signals:", uint256(hook.ledger().scoreOf(fresh)));
    }

    function _swapOnce(PoolKey memory key, address who, uint256 amountIn) internal {
        swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: key,
            hookData: abi.encode(who),
            receiver: who,
            deadline: block.timestamp + 100
        });
    }
}
