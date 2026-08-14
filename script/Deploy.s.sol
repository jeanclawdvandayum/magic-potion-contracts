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
/// @notice Deploys all contracts in correct order with CREATE address prediction.
/// @dev Required env vars:
///   USDC_ADDRESS, ALUSD_ADDRESS, ALCHEMIST_ADDRESS, YIELD_TOKEN_ADDRESS,
///   VRF_COORDINATOR, VRF_SUBSCRIPTION_ID, VRF_KEY_HASH,
///   TREASURY_ADDRESS (receives 5% of alUSD)
/// Optional:
///   KEEPER_BASE_REWARD (LUCK wei, default 1e18)
///   KEEPER_RATE_PER_STEP (LUCK wei, default 0.1e18)
///   KEEPER_STEP_DURATION (seconds, default 300)
contract DeployScript is Script {
    function run() external {
        address usdc = vm.envAddress("USDC_ADDRESS");
        address alUSD = vm.envAddress("ALUSD_ADDRESS");
        address alchemist = vm.envAddress("ALCHEMIST_ADDRESS");
        address mytVault = vm.envAddress("MYT_VAULT_ADDRESS");
        address drandBeacon = vm.envAddress("DRAND_BEACON");
        address treasury = vm.envAddress("TREASURY_ADDRESS");

        vm.startBroadcast();

        // LuckyPotion is the 6th contract deployed
        uint64 nonce = vm.getNonce(msg.sender);
        address predictedCoordinator = vm.computeCreateAddress(msg.sender, nonce + 5);

        DrawingManager dm = new DrawingManager(
            drandBeacon,
            predictedCoordinator
        );

        TicketNFT nft = new TicketNFT(predictedCoordinator);
        LuckToken luck = new LuckToken(predictedCoordinator);
        LuckStaking staking = new LuckStaking(address(luck), alUSD, predictedCoordinator);
        PrizeVault vault = new PrizeVault(alUSD, predictedCoordinator);

        LuckyPotion coordinator = new LuckyPotion(
            usdc,
            alUSD,
            alchemist,
            mytVault,
            address(nft),
            address(luck),
            address(staking),
            address(dm),
            address(vault),
            treasury
        );

        require(address(coordinator) == predictedCoordinator, "Address prediction failed");

        // Optionally override keeper params (defaults baked into contract)
        try vm.envUint("KEEPER_BASE_REWARD") returns (uint256 kr) {
            uint256 rate = vm.envOr("KEEPER_RATE_PER_STEP", uint256(0.1e18));
            uint256 step = vm.envOr("KEEPER_STEP_DURATION", uint256(300));
            coordinator.setKeeperParams(kr, rate, step);
        } catch {}

        vm.stopBroadcast();

        console.log("=== Magic Potion Deployed ===");
        console.log("LuckyPotion:", address(coordinator));
        console.log("TicketNFT:", address(nft));
        console.log("LuckToken:", address(luck));
        console.log("LuckStaking:", address(staking));
        console.log("DrawingManager:", address(dm));
        console.log("PrizeVault:", address(vault));
        console.log("Treasury:", treasury);
        console.log("");
        console.log("Fee split: 83% prize / 12% LUCK / 5% treasury");
        console.log("LUCK: 1 per ticket + 0.1 on burn");
        console.log("Keeper: 1 LUCK base, +0.1 per 5min delay");
        console.log("");
        console.log("Next steps:");
        console.log("1. Add coordinator as VRF consumer");
        console.log("2. Run Initialize.s.sol");
    }
}
