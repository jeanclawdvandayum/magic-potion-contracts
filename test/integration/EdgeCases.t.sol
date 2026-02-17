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

/// @title EdgeCases — Unusual scenarios and boundary conditions
contract EdgeCasesTest is Test {
    LuckyPotion public coordinator;
    TicketNFT public ticketNFT;
    LuckToken public luckToken;
    LuckStaking public luckStaking;
    DrawingManager public drawingManager;
    PrizeVault public prizeVault;
    MockERC20 public usdc;
    MockERC20 public alUSD;
    MockAlchemistV3 public alchemist;
    MockVRFCoordinator public vrfCoordinator;

    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public randoAddress = makeAddr("rando");
    address public opsMultisig = makeAddr("opsMultisig");
    address public yieldToken = makeAddr("yieldToken");

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        alUSD = new MockERC20("Alchemix USD", "alUSD", 18);
        alchemist = new MockAlchemistV3(address(alUSD), address(usdc));
        vrfCoordinator = new MockVRFCoordinator();

        uint64 nonce = vm.getNonce(address(this));
        address predicted = vm.computeCreateAddress(address(this), nonce + 5);

        drawingManager = new DrawingManager(address(vrfCoordinator), predicted, 1, bytes32(uint256(1)), 500_000, 3);
        ticketNFT = new TicketNFT(predicted);
        luckToken = new LuckToken(predicted);
        luckStaking = new LuckStaking(address(luckToken), address(alUSD), predicted);
        prizeVault = new PrizeVault(address(alUSD), predicted);

        coordinator = new LuckyPotion(
            address(usdc), address(alUSD), address(alchemist), yieldToken,
            address(ticketNFT), address(luckToken), address(luckStaking),
            address(drawingManager), address(prizeVault), opsMultisig
        );

        usdc.mint(alice, 100_000e6);
        usdc.mint(bob, 100_000e6);
        vm.prank(alice);
        usdc.approve(address(coordinator), type(uint256).max);
        vm.prank(bob);
        usdc.approve(address(coordinator), type(uint256).max);

        coordinator.initialize();
    }

    function _canvas(uint8 seed) internal pure returns (bytes memory) {
        bytes memory c = new bytes(Constants.CANVAS_DATA_LENGTH);
        for (uint256 i = 0; i < Constants.CANVAS_DATA_LENGTH; i++) {
            c[i] = bytes1(uint8((i + seed) % 256));
        }
        return c;
    }

    function _advanceDraw() internal {
        vm.warp(block.timestamp + Constants.DRAWING_DURATION + 1);
    }

    // ══════════════════════════════════════════════

    function test_zeroTickets_drawingResolves() public {
        // Nobody buys tickets. Drawing still resolves (no alUSD to distribute).
        _advanceDraw();
        coordinator.triggerDrawing();

        DrawingManager.Drawing memory d = drawingManager.getDrawing(1);
        uint256[] memory words = new uint256[](1);
        words[0] = 12345;
        vrfCoordinator.fulfillRandomWordsWithOverride(d.vrfRequestId, words);
        coordinator.finalizeDrawing();

        assertEq(drawingManager.currentDrawingId(), 2);
    }

    function test_singleTicket_wins() public {
        vm.prank(alice);
        uint256 ticketId = coordinator.buyTicket(_canvas(77));
        TicketNFT.TicketData memory ticket = ticketNFT.getTicket(ticketId);

        _advanceDraw();
        coordinator.triggerDrawing();

        // Resolve to winning hash
        DrawingManager.Drawing memory d = drawingManager.getDrawing(1);
        uint256[] memory words = new uint256[](1);
        words[0] = uint256(ticket.canvasHash);
        vrfCoordinator.fulfillRandomWordsWithOverride(d.vrfRequestId, words);
        coordinator.finalizeDrawing();

        // Alice is sole winner
        assertTrue(coordinator.isWinner(ticketId));

        vm.prank(alice);
        coordinator.claimPrize(ticketId);
        assertTrue(alUSD.balanceOf(alice) > 0);
    }

    function test_maxBatchBuy() public {
        bytes[] memory canvases = new bytes[](100);
        for (uint256 i = 0; i < 100; i++) {
            canvases[i] = _canvas(uint8(i));
        }

        vm.prank(alice);
        uint256[] memory ids = coordinator.buyTickets(canvases);

        assertEq(ids.length, 100);
        DrawingManager.Drawing memory d = drawingManager.getDrawing(1);
        assertEq(d.totalTickets, 100);
        assertEq(usdc.balanceOf(alice), 100_000e6 - (Constants.TICKET_PRICE * 100));
    }

    function test_triggerDrawing_permissionless() public {
        vm.prank(alice);
        coordinator.buyTicket(_canvas(1));

        _advanceDraw();

        // Random address triggers — should succeed
        vm.prank(randoAddress);
        coordinator.triggerDrawing();

        DrawingManager.Drawing memory d = drawingManager.getDrawing(1);
        assertEq(uint8(d.state), uint8(DrawingManager.DrawingState.PENDING_VRF));
    }

    function test_finalizeDrawing_permissionless() public {
        vm.prank(alice);
        coordinator.buyTicket(_canvas(1));
        _advanceDraw();
        coordinator.triggerDrawing();

        DrawingManager.Drawing memory d = drawingManager.getDrawing(1);
        uint256[] memory words = new uint256[](1);
        words[0] = 999;
        vrfCoordinator.fulfillRandomWordsWithOverride(d.vrfRequestId, words);

        // Random address finalizes — should succeed
        vm.prank(randoAddress);
        coordinator.finalizeDrawing();
        assertEq(drawingManager.currentDrawingId(), 2);
    }

    function test_burnAfterTransfer() public {
        vm.prank(alice);
        uint256 ticketId = coordinator.buyTicket(_canvas(1));

        // Transfer to bob
        vm.prank(alice);
        ticketNFT.transferFrom(alice, bob, ticketId);

        _advanceDraw();
        coordinator.triggerDrawing();
        DrawingManager.Drawing memory d = drawingManager.getDrawing(1);
        uint256[] memory words = new uint256[](1);
        words[0] = type(uint256).max;
        vrfCoordinator.fulfillRandomWordsWithOverride(d.vrfRequestId, words);
        coordinator.finalizeDrawing();

        TicketNFT.TicketData memory ticket = ticketNFT.getTicket(ticketId);
        DrawingManager.Drawing memory resolved = drawingManager.getDrawing(1);
        if (ticket.canvasHash == resolved.winningHash) return;

        // Bob (new owner) burns
        vm.prank(bob);
        coordinator.burnTicket(ticketId);
        assertEq(luckToken.balanceOf(bob), Constants.BURN_LUCK_REWARD);
    }

    function test_claimAfterTransfer() public {
        vm.prank(alice);
        uint256 ticketId = coordinator.buyTicket(_canvas(55));
        TicketNFT.TicketData memory ticket = ticketNFT.getTicket(ticketId);

        // Transfer to bob before drawing resolves
        vm.prank(alice);
        ticketNFT.transferFrom(alice, bob, ticketId);

        // Add more tickets for pot
        for (uint256 i = 0; i < 5; i++) {
            vm.prank(alice);
            coordinator.buyTicket(_canvas(uint8(100 + i)));
        }

        _advanceDraw();
        coordinator.triggerDrawing();

        // Resolve to ticket's hash
        DrawingManager.Drawing memory d = drawingManager.getDrawing(1);
        uint256[] memory words = new uint256[](1);
        words[0] = uint256(ticket.canvasHash);
        vrfCoordinator.fulfillRandomWordsWithOverride(d.vrfRequestId, words);
        coordinator.finalizeDrawing();

        // Bob (new owner) claims
        vm.prank(bob);
        coordinator.claimPrize(ticketId);
        assertTrue(alUSD.balanceOf(bob) > 0, "bob should receive prize as new owner");

        // Alice cannot claim (not owner)
        // (Alice doesn't own the ticket anymore, so any attempt would revert)
    }

    function test_canvasHashCollisions() public {
        // Buy 10 tickets with same canvas data → same hash
        bytes memory sameCanvas = _canvas(42);
        uint256[] memory tickets = new uint256[](10);

        for (uint256 i = 0; i < 10; i++) {
            vm.prank(alice);
            tickets[i] = coordinator.buyTicket(sameCanvas);
        }

        TicketNFT.TicketData memory t = ticketNFT.getTicket(tickets[0]);
        uint256 popularity = coordinator.getHashPopularity(1, t.canvasHash);
        assertEq(popularity, 10, "hash should have 10 tickets");

        DrawingManager.Drawing memory d = drawingManager.getDrawing(1);
        assertEq(d.totalTickets, 10);
    }
}
