// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {SimpleSemaphorePaymaster} from "../src/SimpleSemaphorePaymaster.sol";
import {console} from "forge-std/console.sol";

contract DeploySimpleSemaphorePaymaster is Script {
    address verifier = 0x6C42599435B82121794D835263C846384869502d; // base sepolia
    address entryPoint = 0x5FF137D4b0FDCD49DcA30c7CF57E578a026d2789;

    function run() external returns (SimpleSemaphorePaymaster) {
        // Begin sending transactions
        vm.startBroadcast();

        // Deploy the contract
        SimpleSemaphorePaymaster paymaster = new SimpleSemaphorePaymaster(entryPoint, verifier);
        paymaster.addStake{value: 1000000000000000000}(1);

        // Stop broadcasting transactions
        vm.stopBroadcast();

        // Log the deployment address
        console.log("SimpleSemaphorePaymaster deployed at:", address(paymaster));

        return paymaster;
    }
}