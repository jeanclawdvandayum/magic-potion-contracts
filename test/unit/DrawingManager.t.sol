// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {DrawingManager} from "../../src/DrawingManager.sol";
import {Constants} from "../../src/libraries/Constants.sol";
import {Errors} from "../../src/libraries/Errors.sol";
import {MockVRFCoordinator} from "../mocks/MockVRFCoordinator.sol";

contract DrawingManagerTest is Test {
    DrawingManager dm;
    MockVRFCoordinator vrfCoord;
    address coordinator = address(0xC00D);

    bytes32 constant KEY_HASH = keccak256("test");
    uint32 constant CALLBACK_GAS = 200_000;
    uint16 constant CONFIRMATIONS = 3;
    uint256 constant SUB_ID = 1;

    function setUp() public {
        vrfCoord = new MockVRFCoordinator();
        dm = new DrawingManager(
            address(vrfCoord),
            coordinator,
            SUB_ID,
            KEY_HASH,
            CALLBACK_GAS,
            CONFIRMATIONS
        );
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

        // Warp past close time
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
        dm.closeTicketSales(1); // permissionless

        DrawingManager.Drawing memory d = dm.getDrawing(1);
        assertEq(uint8(d.state), uint8(DrawingManager.DrawingState.CLOSED));
    }

    // ──── Trigger Drawing ────

    function test_triggerDrawing_beforeDrawTime_reverts() public {
        vm.prank(coordinator);
        dm.startDrawing();

        // Close sales
        vm.warp(block.timestamp + Constants.DRAWING_DURATION - Constants.TICKET_CUTOFF);
        dm.closeTicketSales(1);

        // Try to trigger before drawTime
        vm.prank(coordinator);
        vm.expectRevert(Errors.DrawingNotReady.selector);
        dm.triggerDrawing(1);
    }

    function test_triggerDrawing_requestsVRF() public {
        vm.prank(coordinator);
        dm.startDrawing();

        // Warp to drawTime (auto-closes)
        vm.warp(block.timestamp + Constants.DRAWING_DURATION);

        vm.prank(coordinator);
        dm.triggerDrawing(1);

        DrawingManager.Drawing memory d = dm.getDrawing(1);
        assertEq(uint8(d.state), uint8(DrawingManager.DrawingState.PENDING_VRF));
        assertTrue(d.vrfRequestId > 0);
    }

    // ──── VRF Fulfillment ────

    function test_fulfillRandomWords_setsWinningHash() public {
        vm.prank(coordinator);
        dm.startDrawing();

        // Register some tickets
        vm.startPrank(coordinator);
        dm.registerTicket(1, 100, 0x00AB); // hash = 0x00AB
        dm.registerTicket(1, 101, 0x00AB);
        vm.stopPrank();

        // Warp and trigger
        vm.warp(block.timestamp + Constants.DRAWING_DURATION);
        vm.prank(coordinator);
        dm.triggerDrawing(1);

        DrawingManager.Drawing memory d = dm.getDrawing(1);

        // Fulfill with random word that maps to 0x00AB
        uint256[] memory words = new uint256[](1);
        words[0] = uint256(0x00AB); // lower 16 bits = 0x00AB
        vrfCoord.fulfillRandomWordsWithOverride(d.vrfRequestId, words);

        d = dm.getDrawing(1);
        assertEq(d.winningHash, 0x00AB);
        assertEq(d.winnerCount, 2);
        assertEq(uint8(d.state), uint8(DrawingManager.DrawingState.RESOLVED));
    }

    function test_fulfillRandomWords_noWinner() public {
        vm.prank(coordinator);
        dm.startDrawing();

        // Register tickets with hash 0x0001
        vm.prank(coordinator);
        dm.registerTicket(1, 100, 0x0001);

        // Warp and trigger
        vm.warp(block.timestamp + Constants.DRAWING_DURATION);
        vm.prank(coordinator);
        dm.triggerDrawing(1);

        DrawingManager.Drawing memory d = dm.getDrawing(1);

        // Fulfill with random that doesn't match any ticket hash
        uint256[] memory words = new uint256[](1);
        words[0] = uint256(0x9999); // no tickets have this hash
        vrfCoord.fulfillRandomWordsWithOverride(d.vrfRequestId, words);

        d = dm.getDrawing(1);
        assertEq(d.winningHash, 0x9999);
        assertEq(d.winnerCount, 0);
    }

    // ──── Retry VRF ────

    function test_retryVRF_afterTimeout() public {
        vm.prank(coordinator);
        dm.startDrawing();

        vm.warp(block.timestamp + Constants.DRAWING_DURATION);
        vm.prank(coordinator);
        dm.triggerDrawing(1);

        // Warp past VRF timeout
        vm.warp(block.timestamp + Constants.VRF_TIMEOUT + 1);

        vm.prank(coordinator);
        dm.retryVRF(1);

        // Should still be PENDING_VRF but with new request
        DrawingManager.Drawing memory d = dm.getDrawing(1);
        assertEq(uint8(d.state), uint8(DrawingManager.DrawingState.PENDING_VRF));
    }

    function test_retryVRF_beforeTimeout_reverts() public {
        vm.prank(coordinator);
        dm.startDrawing();

        vm.warp(block.timestamp + Constants.DRAWING_DURATION);
        vm.prank(coordinator);
        dm.triggerDrawing(1);

        // Try retry immediately
        vm.prank(coordinator);
        vm.expectRevert(Errors.VRFTimeoutNotReached.selector);
        dm.retryVRF(1);
    }

    // ──── State Transitions ────

    function test_stateTransitions_onlyForward() public {
        vm.prank(coordinator);
        dm.startDrawing();

        DrawingManager.Drawing memory d = dm.getDrawing(1);
        assertEq(uint8(d.state), 0); // OPEN

        // Close
        vm.warp(block.timestamp + Constants.DRAWING_DURATION - Constants.TICKET_CUTOFF);
        dm.closeTicketSales(1);
        d = dm.getDrawing(1);
        assertEq(uint8(d.state), 1); // CLOSED

        // Trigger
        vm.warp(block.timestamp + Constants.TICKET_CUTOFF);
        vm.prank(coordinator);
        dm.triggerDrawing(1);
        d = dm.getDrawing(1);
        assertEq(uint8(d.state), 2); // PENDING_VRF

        // Fulfill
        uint256[] memory words = new uint256[](1);
        words[0] = 42;
        vrfCoord.fulfillRandomWordsWithOverride(d.vrfRequestId, words);
        d = dm.getDrawing(1);
        assertEq(uint8(d.state), 3); // RESOLVED
    }

    // ──── View Functions ────

    function test_isDrawingOpen() public {
        vm.prank(coordinator);
        dm.startDrawing();

        assertTrue(dm.isDrawingOpen(1));

        // Warp past close
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

        // Warp, trigger, fulfill with 0x00FF
        vm.warp(block.timestamp + Constants.DRAWING_DURATION);
        vm.prank(coordinator);
        dm.triggerDrawing(1);

        DrawingManager.Drawing memory d = dm.getDrawing(1);
        uint256[] memory words = new uint256[](1);
        words[0] = uint256(0x00FF);
        vrfCoord.fulfillRandomWordsWithOverride(d.vrfRequestId, words);

        uint256[] memory winners = dm.getWinningTickets(1);
        assertEq(winners.length, 2);
        assertEq(winners[0], 100);
        assertEq(winners[1], 101);
    }
}
