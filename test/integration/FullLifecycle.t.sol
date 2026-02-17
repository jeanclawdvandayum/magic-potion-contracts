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

/// @title FullLifecycle — End-to-end integration tests
contract FullLifecycleTest is Test {
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
    address public charlie = makeAddr("charlie");
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

        // Fund users
        address[3] memory users = [alice, bob, charlie];
        for (uint256 i = 0; i < 3; i++) {
            usdc.mint(users[i], 10_000e6);
            vm.prank(users[i]);
            usdc.approve(address(coordinator), type(uint256).max);
        }

        coordinator.initialize();
    }

    // ──── Helpers ────

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

    function _triggerAndResolve(uint256 drawingId, uint256 randomSeed) internal {
        coordinator.triggerDrawing();
        DrawingManager.Drawing memory d = drawingManager.getDrawing(drawingId);
        uint256[] memory words = new uint256[](1);
        words[0] = randomSeed;
        vrfCoordinator.fulfillRandomWordsWithOverride(d.vrfRequestId, words);
        coordinator.finalizeDrawing();
    }

    // ══════════════════════════════════════════════
    //               FULL LIFECYCLE
    // ══════════════════════════════════════════════

    function test_fullLifecycle_buyTicket_triggerDrawing_claimPrize() public {
        // Alice buys ticket
        vm.prank(alice);
        uint256 ticketId = coordinator.buyTicket(_canvas(42));
        TicketNFT.TicketData memory ticket = ticketNFT.getTicket(ticketId);

        // More tickets to fund pot
        for (uint256 i = 0; i < 9; i++) {
            vm.prank(bob);
            coordinator.buyTicket(_canvas(uint8(100 + i)));
        }

        // Advance and trigger
        _advanceDraw();
        coordinator.triggerDrawing();

        // Resolve VRF to alice's hash
        DrawingManager.Drawing memory d = drawingManager.getDrawing(1);
        uint256[] memory words = new uint256[](1);
        words[0] = uint256(ticket.canvasHash);
        vrfCoordinator.fulfillRandomWordsWithOverride(d.vrfRequestId, words);
        coordinator.finalizeDrawing();

        // Alice claims
        uint256 before = alUSD.balanceOf(alice);
        vm.prank(alice);
        coordinator.claimPrize(ticketId);
        assertTrue(alUSD.balanceOf(alice) > before, "alice should receive alUSD prize");
    }

    function test_fullLifecycle_noWinner_rollover() public {
        // Drawing 1: buy tickets, resolve with no-winner hash
        for (uint256 i = 0; i < 5; i++) {
            vm.prank(alice);
            coordinator.buyTicket(_canvas(uint8(i)));
        }
        _advanceDraw();
        _triggerAndResolve(1, type(uint256).max - 1); // unlikely matching hash

        // After finalizeDrawing, rollover was applied to drawing 2's allocation
        // Check drawing 2 has inherited the rollover
        PrizeVault.DrawingPrize memory d2Before = prizeVault.getPrizeInfo(2);
        uint256 drawing2AllocBefore = d2Before.allocated;
        assertTrue(drawing2AllocBefore > 0, "drawing 2 should have rollover from drawing 1");

        // Drawing 2: buy more tickets, resolve with no winner again
        for (uint256 i = 0; i < 5; i++) {
            vm.prank(alice);
            coordinator.buyTicket(_canvas(uint8(50 + i)));
        }
        _advanceDraw();
        _triggerAndResolve(2, type(uint256).max - 2);

        // Drawing 3 should have accumulated rollover (drawing 1 rollover + drawing 2 new prize)
        PrizeVault.DrawingPrize memory d3 = prizeVault.getPrizeInfo(3);
        assertTrue(d3.allocated > drawing2AllocBefore, "drawing 3 should have more than drawing 2 had");
    }

    function test_fullLifecycle_multipleWinners_splitPot() public {
        // Three users buy tickets with same canvas → same hash
        bytes memory sameCanvas = _canvas(99);

        vm.prank(alice);
        uint256 t1 = coordinator.buyTicket(sameCanvas);
        vm.prank(bob);
        uint256 t2 = coordinator.buyTicket(sameCanvas);
        vm.prank(charlie);
        uint256 t3 = coordinator.buyTicket(sameCanvas);

        TicketNFT.TicketData memory ticket = ticketNFT.getTicket(t1);

        // More tickets for pot size
        for (uint256 i = 0; i < 7; i++) {
            vm.prank(alice);
            coordinator.buyTicket(_canvas(uint8(200 + i)));
        }

        _advanceDraw();
        coordinator.triggerDrawing();

        // Resolve to matching hash
        DrawingManager.Drawing memory d = drawingManager.getDrawing(1);
        uint256[] memory words = new uint256[](1);
        words[0] = uint256(ticket.canvasHash);
        vrfCoordinator.fulfillRandomWordsWithOverride(d.vrfRequestId, words);
        coordinator.finalizeDrawing();

        // All three claim
        vm.prank(alice);
        coordinator.claimPrize(t1);
        uint256 aliceGot = alUSD.balanceOf(alice);

        vm.prank(bob);
        coordinator.claimPrize(t2);
        uint256 bobGot = alUSD.balanceOf(bob);

        vm.prank(charlie);
        coordinator.claimPrize(t3);
        uint256 charlieGot = alUSD.balanceOf(charlie);

        // All should get equal share
        assertEq(aliceGot, bobGot, "alice and bob should get same prize");
        assertEq(bobGot, charlieGot, "bob and charlie should get same prize");
        assertTrue(aliceGot > 0, "prize should be nonzero");
    }

    function test_fullLifecycle_burnForLuck() public {
        vm.prank(alice);
        uint256 ticketId = coordinator.buyTicket(_canvas(1));

        _advanceDraw();
        _triggerAndResolve(1, type(uint256).max); // no winner

        TicketNFT.TicketData memory ticket = ticketNFT.getTicket(ticketId);
        DrawingManager.Drawing memory d = drawingManager.getDrawing(1);
        if (ticket.canvasHash == d.winningHash) return; // edge case

        uint256 luckBefore = luckToken.balanceOf(alice);
        vm.prank(alice);
        coordinator.burnTicket(ticketId);
        assertEq(luckToken.balanceOf(alice) - luckBefore, Constants.BURN_LUCK_REWARD);
    }

    function test_fullLifecycle_stakingRewards() public {
        // Alice buys ticket → gets LUCK → stakes it
        vm.prank(alice);
        coordinator.buyTicket(_canvas(1));
        uint256 luckBalance = luckToken.balanceOf(alice);
        assertEq(luckBalance, Constants.LUCK_PER_TICKET);

        vm.startPrank(alice);
        luckToken.approve(address(luckStaking), luckBalance);
        luckStaking.stake(luckBalance);
        vm.stopPrank();

        // Buy more tickets to generate yield
        for (uint256 i = 0; i < 20; i++) {
            vm.prank(bob);
            coordinator.buyTicket(_canvas(uint8(50 + i)));
        }

        // Trigger drawing (distributes alUSD to staking)
        _advanceDraw();
        coordinator.triggerDrawing();

        // Check staking has rewards
        uint256 pending = luckStaking.pendingRewards(alice);
        assertTrue(pending > 0, "alice should have pending staking rewards");

        // Claim
        vm.prank(alice);
        luckStaking.claimRewards();
        assertTrue(alUSD.balanceOf(alice) > 0, "alice should have received alUSD from staking");
    }

    function test_multiDrawing_prizeGrowth() public {
        uint256 prevAlloc;

        // 5 drawings with no winner — prize carried to next drawing should grow
        for (uint256 drawing = 1; drawing <= 5; drawing++) {
            // Buy tickets each drawing
            for (uint256 i = 0; i < 5; i++) {
                vm.prank(alice);
                coordinator.buyTicket(_canvas(uint8(drawing * 20 + i)));
            }
            _advanceDraw();
            _triggerAndResolve(drawing, type(uint256).max - drawing);

            // Check the NEXT drawing's allocation (it received the rollover)
            uint256 nextDrawing = drawing + 1;
            PrizeVault.DrawingPrize memory info = prizeVault.getPrizeInfo(nextDrawing);
            assertTrue(info.allocated >= prevAlloc, "allocation should grow across drawings");
            prevAlloc = info.allocated;
        }

        assertTrue(prevAlloc > 0, "final allocation should be nonzero");
    }

    function test_stakingAcrossMultipleDrawings() public {
        // Alice stakes LUCK from first ticket purchase
        vm.prank(alice);
        coordinator.buyTicket(_canvas(1));
        vm.startPrank(alice);
        luckToken.approve(address(luckStaking), Constants.LUCK_PER_TICKET);
        luckStaking.stake(Constants.LUCK_PER_TICKET);
        vm.stopPrank();

        uint256 totalRewards;

        // Run 3 drawings, each with ticket purchases
        for (uint256 drawing = 1; drawing <= 3; drawing++) {
            for (uint256 i = 0; i < 10; i++) {
                vm.prank(bob);
                coordinator.buyTicket(_canvas(uint8(drawing * 30 + i)));
            }
            _advanceDraw();
            _triggerAndResolve(drawing, type(uint256).max - drawing);

            uint256 pending = luckStaking.pendingRewards(alice);
            assertTrue(pending >= totalRewards, "rewards should grow or stay same across drawings");
            totalRewards = pending;
        }

        assertTrue(totalRewards > 0, "should have accumulated staking rewards over 3 drawings");
    }
}
