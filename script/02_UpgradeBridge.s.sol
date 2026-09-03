// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {LVRReserve} from "../src/LVRReserve.sol";
import {CctpBridge, ITokenMessengerV2} from "../src/circle/CctpBridge.sol";

/// @notice Surgical upgrade of the CctpBridge pointed at an already-deployed LVRReserve.
///         Deploys a fresh CctpBridge with the current canonical token messenger, then points
///         the existing reserve at it — preserving the confirmed hook/reserve/adapter addresses.
///         Usage:
///           forge script script/02_UpgradeBridge.s.sol:UpgradeBridge \
///             --rpc-url $BASE_RPC --private-key $PRIVATE_KEY --broadcast
///         Env vars:
///           PARITY_RESERVE   Already-deployed LVRReserve address.
///           PARITY_USDC      Native USDC on this chain.
///           PARITY_TOKEN_MESSENGER  Canonical Circle CCTP TokenMessengerV2.
contract UpgradeBridge is Script {
    function run() external {
        address deployer = msg.sender;
        vm.startBroadcast();

        LVRReserve reserve = LVRReserve(vm.envAddress("PARITY_RESERVE"));
        IERC20Metadata usdc = IERC20Metadata(vm.envAddress("PARITY_USDC"));
        ITokenMessengerV2 messenger = ITokenMessengerV2(vm.envAddress("PARITY_TOKEN_MESSENGER"));

        CctpBridge bridge = new CctpBridge(usdc, reserve, messenger, deployer);
        console2.log("new CctpBridge: ", address(bridge));

        reserve.setBridge(address(bridge));
        console2.log("reserve.bridge ->", address(reserve.bridge()));

        vm.stopBroadcast();
    }
}
