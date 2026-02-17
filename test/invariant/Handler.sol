// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {LuckyPotion} from "../../src/LuckyPotion.sol";
import {TicketNFT} from "../../src/TicketNFT.sol";
import {LuckToken} from "../../src/LuckToken.sol";
import {LuckStaking} from "../../src/LuckStaking.sol";
import {DrawingManager} from "../../src/DrawingManager.sol";
import {PrizeVault} from "../../src/PrizeVault.sol";
import {Constants} from "../../src/libraries/Constants.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockAlchemistV3} from "../mocks/MockAlchemistV3.sol";
import {MockVRFCoordinator} from "../mocks/MockVRFCoordinator.sol";

/// @title Handler — Wraps protocol actions with bounded inputs for invariant testing
contract Handler is Test {
    LuckyPotion public coordinator;
    TicketNFT public ticketNFT;
    LuckToken public luckToken;
    LuckStaking public luckStaking;
    DrawingManager public drawingManager;
    PrizeVault public prizeVault;
    MockERC20 public usdc;
    MockERC20 public alUSD;
    MockVRFCoordinator public vrfCoordinator;

    address[] public actors;
    uint256[] public allTicketIds;

    // Ghost variables for invariant checking
    uint256 public ghost_totalTicketsBought;
    uint256 public ghost_totalTicketsBurned;
    uint256 public ghost_totalLuckMinted;
    uint256 public ghost_totalDrawingsTriggered;
    uint256 public ghost_totalPrizesClaimed;

    constructor(
        LuckyPotion _coordinator,
        TicketNFT _ticketNFT,
        LuckToken _luckToken,
        LuckStaking _luckStaking,
        DrawingManager _drawingManager,
        PrizeVault _prizeVault,
        MockERC20 _usdc,
        MockERC20 _alUSD,
        MockVRFCoordinator _vrfCoordinator,
        address[] memory _actors
    ) {
        coordinator = _coordinator;
        ticketNFT = _ticketNFT;
        luckToken = _luckToken;
        luckStaking = _luckStaking;
        drawingManager = _drawingManager;
        prizeVault = _prizeVault;
        usdc = _usdc;
        alUSD = _alUSD;
        vrfCoordinator = _vrfCoordinator;
        actors = _actors;
    }

    // ──── Actions ────

    function buyTicket(uint256 actorSeed, uint8 canvasSeed) external {
        address actor = actors[actorSeed % actors.length];
        bytes memory canvas = _makeCanvas(canvasSeed);

        vm.prank(actor);
        try coordinator.buyTicket(canvas) returns (uint256 ticketId) {
            allTicketIds.push(ticketId);
            ghost_totalTicketsBought++;
            ghost_totalLuckMinted += Constants.LUCK_PER_TICKET;
        } catch {}
    }

    function advanceTime(uint256 seconds_) external {
        seconds_ = bound(seconds_, 1, 15 days);
        vm.warp(block.timestamp + seconds_);
    }

    function triggerDrawing() external {
        try coordinator.triggerDrawing() {
            ghost_totalDrawingsTriggered++;
        } catch {}
    }

    function fulfillVRF(uint256 randomSeed) external {
        uint256 drawingId = drawingManager.currentDrawingId();
        DrawingManager.Drawing memory d = drawingManager.getDrawing(drawingId);
        if (d.state != DrawingManager.DrawingState.PENDING_VRF) return;

        uint256[] memory words = new uint256[](1);
        words[0] = randomSeed;
        try vrfCoordinator.fulfillRandomWordsWithOverride(d.vrfRequestId, words) {} catch {}
    }

    function finalizeDrawing() external {
        try coordinator.finalizeDrawing() {} catch {}
    }

    function claimPrize(uint256 ticketSeed) external {
        if (allTicketIds.length == 0) return;
        uint256 ticketId = allTicketIds[ticketSeed % allTicketIds.length];

        // Find the owner
        try ticketNFT.ownerOf(ticketId) returns (address owner) {
            vm.prank(owner);
            try coordinator.claimPrize(ticketId) {
                ghost_totalPrizesClaimed++;
            } catch {}
        } catch {}
    }

    function burnTicket(uint256 ticketSeed) external {
        if (allTicketIds.length == 0) return;
        uint256 ticketId = allTicketIds[ticketSeed % allTicketIds.length];

        try ticketNFT.ownerOf(ticketId) returns (address owner) {
            vm.prank(owner);
            try coordinator.burnTicket(ticketId) {
                ghost_totalTicketsBurned++;
                ghost_totalLuckMinted += Constants.BURN_LUCK_REWARD;
            } catch {}
        } catch {}
    }

    function stakeLuck(uint256 actorSeed, uint256 amount) external {
        address actor = actors[actorSeed % actors.length];
        uint256 balance = luckToken.balanceOf(actor);
        if (balance == 0) return;
        amount = bound(amount, 1, balance);

        vm.startPrank(actor);
        luckToken.approve(address(luckStaking), amount);
        try luckStaking.stake(amount) {} catch {}
        vm.stopPrank();
    }

    function unstakeLuck(uint256 actorSeed, uint256 amount) external {
        address actor = actors[actorSeed % actors.length];
        (uint256 staked,) = luckStaking.userInfo(actor);
        if (staked == 0) return;
        amount = bound(amount, 1, staked);

        vm.prank(actor);
        try luckStaking.unstake(amount) {} catch {}
    }

    function claimStakingRewards(uint256 actorSeed) external {
        address actor = actors[actorSeed % actors.length];
        vm.prank(actor);
        try luckStaking.claimRewards() {} catch {}
    }

    // ──── Internal ────

    function _makeCanvas(uint8 seed) internal pure returns (bytes memory) {
        bytes memory c = new bytes(Constants.CANVAS_DATA_LENGTH);
        for (uint256 i = 0; i < Constants.CANVAS_DATA_LENGTH; i++) {
            c[i] = bytes1(uint8((i + seed) % 256));
        }
        return c;
    }

    function getTicketCount() external view returns (uint256) {
        return allTicketIds.length;
    }
}
