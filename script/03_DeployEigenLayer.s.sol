// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {ParityCrossPoolOracle} from "../src/eigenlayer/ParityCrossPoolOracle.sol";
import {IECDSAStakeRegistry} from "../src/eigenlayer/IECDSAStakeRegistry.sol";

/// @notice Deploys `ParityCrossPoolOracle` (EigenLayer AVS consumer) to Base Sepolia.
///
///         The oracle's `stakeRegistry` is pointed at the address of the Parity AVS's real
///         `ECDSAStakeRegistry` (EigenLayer middleware) once that registry proxy is available;
///         ABI/encoding compatibility with the audited registry is proven by
///         test/EigenLayerLiveFork.t.sol without importing the full EigenLayer build graph.
///
///         Usage:
///           forge script script/03_DeployEigenLayer.s.sol:DeployEigenLayer \
///             --rpc-url $BASE_RPC --private-key $PRIVATE_KEY --broadcast
contract DeployEigenLayer is Script {
    function run() external {
        address deployer = msg.sender;
        IECDSAStakeRegistry stakeRegistry = IECDSAStakeRegistry(vm.envOr("EIGENLAYER_REGISTRY", address(0)));

        vm.startBroadcast();
        uint256 freshness = 50; // blocks
        ParityCrossPoolOracle oracle = new ParityCrossPoolOracle(stakeRegistry, freshness, deployer);
        console2.log("CrossPoolOracle:    ", address(oracle));
        console2.log("Wired stakeRegistry:", address(stakeRegistry));
        vm.stopBroadcast();
    }
}
