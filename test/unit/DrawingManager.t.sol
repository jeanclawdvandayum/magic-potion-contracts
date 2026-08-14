// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Test.sol";
import {DrawingManager} from "../../src/DrawingManager.sol";
import {Constants} from "../../src/libraries/Constants.sol";
import {Errors} from "../../src/libraries/Errors.sol";
import {MockDrandBeacon} from "../mocks/MockDrandBeacon.sol";

contract DrawingManagerTest is Test {
    DrawingManager dm;
    MockDrandBeacon drandBeacon;
    address coordinator = address(0xC00D);

    function setUp() public {
        // Warp to a realistic mainnet-era timestamp first: setUp below does
        // block.timestamp-relative arithmetic and foundry defaults to ts=1.
        vm.warp(1_750_000_000);
        drandBeacon = new MockDrandBeacon();
        // Set genesis far in the past so rounds work with current block.timestamp
        drandBeacon.setGenesis(block.timestamp - 10000);
        dm = new DrawingManager(address(drandBeacon), coordinator);
    }

    function _fulfillRandomness(uint256 drawingId) internal {
        DrawingManager.Drawing memory d = dm.getDrawing(drawingId);
        uint256[2] memory sig = [uint256(1), uint256(2)];
        drandBeacon.setSignature(d.targetRound, sig);
        dm.submitRandomness(drawingId, d.targetRound, sig);
    }

    function _fulfillRandomnessWithHash(uint256 drawingId, uint16 desiredHash) internal {
        DrawingManager.Drawing memory d = dm.getDrawing(drawingId);
        // We need the randomness to produce a specific lower 16 bits.
        // The randomness is keccak256(sig0, sig1, chainid, address(this), drawingId).
        // For testing, brute-force the sig[0] value until we get the right hash.
        uint256[2] memory sig = [uint256(0), uint256(0)];
        for (uint256 i = 1; i < 100_000; i++) {
            sig[0] = i;
            uint256 randomness = uint256(keccak256(abi.encode(sig[0], sig[1], block.chainid, address(dm), drawingId)));
            if (uint16(randomness & 0xFFFF) == desiredHash) {
                break;
            }
        }
        drandBeacon.setSignature(d.targetRound, sig);
        dm.submitRandomness(drawingId, d.targetRound, sig);
    }

    // ──── Start Drawing ────

    function test_startDrawing_setsTimings() public {
        vm.prank(coordinator);
        uint256 id = dm.startDrawing();
        assertEq(id, 1);

        DrawingManager.Drawing memory d = dm.getDrawing(1);
        assertEq(uint8(d.state), uint8(DrawingManager.DrawingState.OPEN));
        assertEq(d.openTime, block.timestamp);
        assertEq(d.closeTime, block.timestamp + Constants.DRAWING_DURATION - Constants.TICKET_CUTOFF);
        assertEq(d.drawTime, block.timestamp + Constants.DRAWING_DURATION);
    }

    function test_startDrawing_nonCoordinator_reverts() public {
        vm.expectRevert(Errors.OnlyCoordinator.selector);
        dm.startDrawing();
    }

    // ──── Register Ticket ────

    function test_registerTicket_incrementsCounts() public {
        vm.prank(coordinator);
        dm.startDrawing();

        vm.prank(coordinator);
        dm.registerTicket(1, 100, 0x1234);

        assertEq(dm.getHashPopularity(1, 0x1234), 1);

        vm.prank(coordinator);
        dm.registerTicket(1, 101, 0x1234);

        assertEq(dm.getHashPopularity(1, 0x1234), 2);
    }

    function test_registerTicket_afterClose_reverts() public {
        vm.prank(coordinator);
        dm.startDrawing();

        vm.warp(block.timestamp + Constants.DRAWING_DURATION - Constants.TICKET_CUTOFF);

        vm.prank(coordinator);
        vm.expectRevert(Errors.TicketSalesClosed.selector);
        dm.registerTicket(1, 100, 0x1234);
    }

    // ──── Close Ticket Sales ────

    function test_closeTicketSales_beforeTime_reverts() public {
        vm.prank(coordinator);
        dm.startDrawing();

        vm.expectRevert(Errors.TicketSalesClosed.selector);
        dm.closeTicketSales(1);
    }

    function test_closeTicketSales_afterTime() public {
        vm.prank(coordinator);
        dm.startDrawing();

        vm.warp(block.timestamp + Constants.DRAWING_DURATION - Constants.TICKET_CUTOFF);
        dm.closeTicketSales(1);

        DrawingManager.Drawing memory d = dm.getDrawing(1);
        assertEq(uint8(d.state), uint8(DrawingManager.DrawingState.CLOSED));
    }

    // ──── Trigger Drawing ────

    function test_triggerDrawing_beforeDrawTime_reverts() public {
        vm.prank(coordinator);
        dm.startDrawing();

        vm.warp(block.timestamp + Constants.DRAWING_DURATION - Constants.TICKET_CUTOFF);
        dm.closeTicketSales(1);

        vm.prank(coordinator);
        vm.expectRevert(Errors.DrawingNotReady.selector);
        dm.triggerDrawing(1);
    }

    function test_triggerDrawing_commitsToRound() public {
        vm.prank(coordinator);
        dm.startDrawing();

        vm.warp(block.timestamp + Constants.DRAWING_DURATION);

        vm.prank(coordinator);
        dm.triggerDrawing(1);

        DrawingManager.Drawing memory d = dm.getDrawing(1);
        assertEq(uint8(d.state), uint8(DrawingManager.DrawingState.PENDING_RANDOMNESS));
        assertTrue(d.targetRound > 0);
    }

    // ──── Submit Randomness ────

    function test_submitRandomness_resolvesDrawing() public {
        vm.prank(coordinator);
        dm.startDrawing();

        vm.startPrank(coordinator);
        dm.registerTicket(1, 100, 0x00AB);
        dm.registerTicket(1, 101, 0x00AB);
        vm.stopPrank();

        vm.warp(block.timestamp + Constants.DRAWING_DURATION);
        vm.prank(coordinator);
        dm.triggerDrawing(1);

        // Submit drand signature for the target round
        _fulfillRandomnessWithHash(1, 0x00AB);

        DrawingManager.Drawing memory d = dm.getDrawing(1);
        assertEq(d.winningHash, 0x00AB);
        assertEq(d.winnerCount, 2);
        assertEq(uint8(d.state), uint8(DrawingManager.DrawingState.RESOLVED));
    }

    function test_submitRandomness_noWinner() public {
        vm.prank(coordinator);
        dm.startDrawing();

        vm.prank(coordinator);
        dm.registerTicket(1, 100, 0x0001);

        vm.warp(block.timestamp + Constants.DRAWING_DURATION);
        vm.prank(coordinator);
        dm.triggerDrawing(1);

        _fulfillRandomnessWithHash(1, 0x9999);

        DrawingManager.Drawing memory d = dm.getDrawing(1);
        assertEq(d.winningHash, 0x9999);
        assertEq(d.winnerCount, 0);
    }

    function test_submitRandomness_wrongRound_reverts() public {
        vm.prank(coordinator);
        dm.startDrawing();

        vm.warp(block.timestamp + Constants.DRAWING_DURATION);
        vm.prank(coordinator);
        dm.triggerDrawing(1);

        uint256[2] memory sig = [uint256(1), uint256(2)];
        drandBeacon.setSignature(99999, sig);
        vm.expectRevert(Errors.InvalidDrandRound.selector);
        dm.submitRandomness(1, 99999, sig);
    }

    // ──── Retry Round ────

    function test_retryRound_afterTimeout() public {
        vm.prank(coordinator);
        dm.startDrawing();

        vm.warp(block.timestamp + Constants.DRAWING_DURATION);
        vm.prank(coordinator);
        dm.triggerDrawing(1);

        vm.warp(block.timestamp + Constants.DRAND_TIMEOUT + 1);

        vm.prank(coordinator);
        dm.retryRound(1);

        DrawingManager.Drawing memory d = dm.getDrawing(1);
        assertEq(uint8(d.state), uint8(DrawingManager.DrawingState.PENDING_RANDOMNESS));
    }

    function test_retryRound_beforeTimeout_reverts() public {
        vm.prank(coordinator);
        dm.startDrawing();

        vm.warp(block.timestamp + Constants.DRAWING_DURATION);
        vm.prank(coordinator);
        dm.triggerDrawing(1);

        vm.prank(coordinator);
        vm.expectRevert(Errors.DrandTimeoutNotReached.selector);
        dm.retryRound(1);
    }

    // ──── State Transitions ────

    function test_stateTransitions_onlyForward() public {
        vm.prank(coordinator);
        dm.startDrawing();

        DrawingManager.Drawing memory d = dm.getDrawing(1);
        assertEq(uint8(d.state), 0); // OPEN

        vm.warp(block.timestamp + Constants.DRAWING_DURATION - Constants.TICKET_CUTOFF);
        dm.closeTicketSales(1);
        d = dm.getDrawing(1);
        assertEq(uint8(d.state), 1); // CLOSED

        vm.warp(block.timestamp + Constants.TICKET_CUTOFF);
        vm.prank(coordinator);
        dm.triggerDrawing(1);
        d = dm.getDrawing(1);
        assertEq(uint8(d.state), 2); // PENDING_RANDOMNESS

        _fulfillRandomness(1);
        d = dm.getDrawing(1);
        assertEq(uint8(d.state), 3); // RESOLVED
    }

    // ──── View Functions ────

    function test_isDrawingOpen() public {
        vm.prank(coordinator);
        dm.startDrawing();

        assertTrue(dm.isDrawingOpen(1));

        vm.warp(block.timestamp + Constants.DRAWING_DURATION - Constants.TICKET_CUTOFF);
        assertFalse(dm.isDrawingOpen(1));
    }

    function test_getWinningTickets() public {
        vm.prank(coordinator);
        dm.startDrawing();

        vm.startPrank(coordinator);
        dm.registerTicket(1, 100, 0x00FF);
        dm.registerTicket(1, 101, 0x00FF);
        dm.registerTicket(1, 102, 0x0001);
        vm.stopPrank();

        vm.warp(block.timestamp + Constants.DRAWING_DURATION);
        vm.prank(coordinator);
        dm.triggerDrawing(1);

        _fulfillRandomnessWithHash(1, 0x00FF);

        uint256[] memory winners = dm.getWinningTickets(1);
        assertEq(winners.length, 2);
        assertEq(winners[0], 100);
        assertEq(winners[1], 101);
    }
}
