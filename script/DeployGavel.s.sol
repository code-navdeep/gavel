// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {GavelRegistry} from "../src/GavelRegistry.sol";
import {GavelYesNo} from "../src/GavelYesNo.sol";
import {GavelChoice} from "../src/GavelChoice.sol";
import {GavelRanked} from "../src/GavelRanked.sol";
import {GavelThreshold} from "../src/GavelThreshold.sol";

/// @notice Deploys the whole Gavel toolkit — the registry and all four decision modules — to
///         any EVM-compatible network.
///
/// Required environment variable:
///   GAVEL_OWNER — the address that will run the registry and every decision module.
///
/// Usage (the deploying key is passed with Foundry's usual wallet options):
///   forge script script/DeployGavel.s.sol --rpc-url <your network URL> --broadcast
contract DeployGavel is Script {
    function run() external {
        address owner = vm.envAddress("GAVEL_OWNER");

        vm.startBroadcast();

        GavelRegistry registry = new GavelRegistry(owner);
        GavelYesNo yesNo = new GavelYesNo(registry);
        GavelChoice choice = new GavelChoice(registry);
        GavelRanked ranked = new GavelRanked(registry);
        GavelThreshold threshold = new GavelThreshold(registry);

        vm.stopBroadcast();

        console.log("Owner:          ", owner);
        console.log("GavelRegistry:  ", address(registry));
        console.log("GavelYesNo:     ", address(yesNo));
        console.log("GavelChoice:    ", address(choice));
        console.log("GavelRanked:    ", address(ranked));
        console.log("GavelThreshold: ", address(threshold));
    }
}
