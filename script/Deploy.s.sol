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
contract DeployScript is Script {
    function run() external {
        address[6] memory addrs = [
            vm.envAddress("USDC_ADDRESS"),
            vm.envAddress("ALUSD_ADDRESS"),
            vm.envAddress("ALCHEMIST_ADDRESS"),
            vm.envAddress("YIELD_TOKEN_ADDRESS"),
            vm.envAddress("VRF_COORDINATOR"),
            vm.envAddress("OPS_MULTISIG")
        ];
        uint256 subId = vm.envUint("VRF_SUBSCRIPTION_ID");
        bytes32 keyHash = vm.envBytes32("VRF_KEY_HASH");

        vm.startBroadcast();

        uint64 nonce = vm.getNonce(msg.sender);
        address predicted = vm.computeCreateAddress(msg.sender, nonce + 5);

        DrawingManager dm = new DrawingManager(addrs[4], predicted, subId, keyHash, 500_000, 3);
        TicketNFT nft = new TicketNFT(predicted);
        LuckToken luck = new LuckToken(predicted);
        LuckStaking staking = new LuckStaking(address(luck), addrs[1], predicted);
        PrizeVault vault = new PrizeVault(addrs[1], predicted);

        new LuckyPotion(
            addrs[0], addrs[1], addrs[2], addrs[3],
            address(nft), address(luck), address(staking),
            address(dm), address(vault), addrs[5]
        );

        vm.stopBroadcast();
    }
}
