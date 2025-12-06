// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {ZjsStake} from "../src/ZjsStake.sol";
import {ZjsToken} from "../src/ZjsToken.sol";

contract DeployZjsStake is Script {
    function run() external {
        // Load environment variables
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address admin = vm.envAddress("Account2");
        address upgrader = vm.envAddress("Account3");

        // Start broadcasting transactions
        vm.startBroadcast(deployerPrivateKey);

        // Deploy ZjsToken
        ZjsToken zjsToken = new ZjsToken(1000000 * 1e18);

        // Deploy ZjsStake
        ZjsStake zjsStake = new ZjsStake();

        // Initialize ZjsStake
        zjsStake.initialize(
            zjsToken,
            100 * 1e18, // zjsTokenPerBlock
            1000,       // startBlock
            2000,       // endBlock
            admin,      // admin
            upgrader    // upgrader
        );

        // Stop broadcasting transactions
        vm.stopBroadcast();

        // Log deployed addresses
        console.log("ZjsToken deployed at:", address(zjsToken));
        console.log("ZjsStake deployed at:", address(zjsStake));
    }
}