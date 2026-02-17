// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {LuckyPotion} from "../src/LuckyPotion.sol";
import {DrawingManager} from "../src/DrawingManager.sol";

/// @title Initialize — Start the first drawing after deployment
/// @notice Call this after deploying + setting up VRF subscription.
/// @dev Environment variables:
///   COORDINATOR_ADDRESS — LuckyPotion coordinator address
contract InitializeScript is Script {
    function run() external {
        address coordinatorAddr = vm.envAddress("COORDINATOR_ADDRESS");
        LuckyPotion coordinator = LuckyPotion(coordinatorAddr);

        vm.startBroadcast();

        coordinator.initialize();

        vm.stopBroadcast();

        // Verify
        require(coordinator.initialized(), "Initialize failed");

        DrawingManager dm = coordinator.drawingManager();
        uint256 drawingId = dm.currentDrawingId();
        DrawingManager.Drawing memory d = dm.getDrawing(drawingId);

        console.log("Protocol initialized!");
        console.log("First drawing ID:", drawingId);
        console.log("Drawing state: OPEN");
        console.log("Open time:", d.openTime);
        console.log("Close time:", d.closeTime);
        console.log("Draw time:", d.drawTime);
    }
}
