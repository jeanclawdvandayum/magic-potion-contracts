// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {LuckyPotion} from "../src/LuckyPotion.sol";
import {TicketNFT} from "../src/TicketNFT.sol";
import {LuckToken} from "../src/LuckToken.sol";
import {LuckStaking} from "../src/LuckStaking.sol";
import {DrawingManager} from "../src/DrawingManager.sol";
import {PrizeVault} from "../src/PrizeVault.sol";

/// @title Deploy — Magic Potion protocol deployment script
/// @notice Deploys all contracts in correct order with cross-references.
///         Does NOT call initialize() — that's a separate step after VRF subscription setup.
/// @dev Environment variables required:
///   USDC_ADDRESS — USDC token address
///   ALUSD_ADDRESS — alUSD token address
///   ALCHEMIST_ADDRESS — Alchemix V3 AlchemistV3 address
///   YIELD_TOKEN_ADDRESS — Alchemist yield token (e.g. yvUSDC)
///   VRF_COORDINATOR — Chainlink VRF V2.5 coordinator address
///   VRF_SUBSCRIPTION_ID — VRF subscription ID
///   VRF_KEY_HASH — VRF key hash
///   VRF_CALLBACK_GAS — VRF callback gas limit
///   VRF_CONFIRMATIONS — VRF request confirmations
///   OPS_MULTISIG — Operations multisig address
contract DeployScript is Script {
    function run() external {
        // Read config from env
        address usdc = vm.envAddress("USDC_ADDRESS");
        address alUSD = vm.envAddress("ALUSD_ADDRESS");
        address alchemist = vm.envAddress("ALCHEMIST_ADDRESS");
        address yieldToken = vm.envAddress("YIELD_TOKEN_ADDRESS");
        address vrfCoordinator = vm.envAddress("VRF_COORDINATOR");
        uint256 subscriptionId = vm.envUint("VRF_SUBSCRIPTION_ID");
        bytes32 keyHash = vm.envBytes32("VRF_KEY_HASH");
        uint32 callbackGas = uint32(vm.envUint("VRF_CALLBACK_GAS"));
        uint16 confirmations = uint16(vm.envUint("VRF_CONFIRMATIONS"));
        address opsMultisig = vm.envAddress("OPS_MULTISIG");

        vm.startBroadcast();

        // 1. Predict coordinator address (deployed after 5 sub-contracts)
        uint64 nonce = vm.getNonce(msg.sender);
        address predictedCoordinator = vm.computeCreateAddress(msg.sender, nonce + 5);
        console.log("Predicted coordinator:", predictedCoordinator);

        // 2. Deploy sub-contracts
        DrawingManager drawingManager = new DrawingManager(
            vrfCoordinator,
            predictedCoordinator,
            subscriptionId,
            keyHash,
            callbackGas,
            confirmations
        );
        console.log("DrawingManager:", address(drawingManager));

        TicketNFT ticketNFT = new TicketNFT(predictedCoordinator);
        console.log("TicketNFT:", address(ticketNFT));

        LuckToken luckToken = new LuckToken(predictedCoordinator);
        console.log("LuckToken:", address(luckToken));

        LuckStaking luckStaking = new LuckStaking(
            address(luckToken),
            alUSD,
            predictedCoordinator
        );
        console.log("LuckStaking:", address(luckStaking));

        PrizeVault prizeVault = new PrizeVault(alUSD, predictedCoordinator);
        console.log("PrizeVault:", address(prizeVault));

        // 3. Deploy coordinator
        LuckyPotion coordinator = new LuckyPotion(
            usdc,
            alUSD,
            alchemist,
            yieldToken,
            address(ticketNFT),
            address(luckToken),
            address(luckStaking),
            address(drawingManager),
            address(prizeVault),
            opsMultisig
        );
        console.log("LuckyPotion:", address(coordinator));

        // 4. Verify address prediction
        require(address(coordinator) == predictedCoordinator, "Address prediction failed!");

        vm.stopBroadcast();

        // Summary
        console.log("\n=== DEPLOYMENT COMPLETE ===");
        console.log("LuckyPotion (coordinator):", address(coordinator));
        console.log("DrawingManager:           ", address(drawingManager));
        console.log("TicketNFT:                ", address(ticketNFT));
        console.log("LuckToken:                ", address(luckToken));
        console.log("LuckStaking:              ", address(luckStaking));
        console.log("PrizeVault:               ", address(prizeVault));
        console.log("\nNEXT STEPS:");
        console.log("1. Add coordinator as VRF consumer on subscription");
        console.log("2. Call coordinator.initialize() to start first drawing");
    }
}
