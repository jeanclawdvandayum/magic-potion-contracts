// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {LuckyPotion} from "../../src/LuckyPotion.sol";
import {TicketNFT} from "../../src/TicketNFT.sol";
import {LuckToken} from "../../src/LuckToken.sol";
import {LuckStaking} from "../../src/LuckStaking.sol";
import {DrawingManager} from "../../src/DrawingManager.sol";
import {PrizeVault} from "../../src/PrizeVault.sol";
import {Constants} from "../../src/libraries/Constants.sol";
import {Errors} from "../../src/libraries/Errors.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockAlchemistV3} from "../mocks/MockAlchemistV3.sol";
import {MockVRFCoordinator} from "../mocks/MockVRFCoordinator.sol";

contract LuckyPotionTest is Test {
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

    address public deployer = address(this);
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public opsMultisig = makeAddr("opsMultisig");
    address public yieldToken = makeAddr("yieldToken");

    bytes public validCanvas;

    function setUp() public {
        // Deploy mock tokens
        usdc = new MockERC20("USD Coin", "USDC", 6);
        alUSD = new MockERC20("Alchemix USD", "alUSD", 18);

        // Deploy mock Alchemist
        alchemist = new MockAlchemistV3(address(alUSD), address(usdc));

        // Deploy VRF coordinator
        vrfCoordinator = new MockVRFCoordinator();

        // We need to deploy coordinator first to pass as address to sub-contracts
        // But sub-contracts need coordinator address... Use CREATE2 or just deploy in right order.
        // Strategy: deploy with a temporary address, then create coordinator, but that doesn't work
        // since sub-contracts have immutable coordinator.
        // Solution: predict the coordinator address or deploy sub-contracts after.
        
        // Actually, since coordinator accepts addresses in constructor, we can:
        // 1. Compute coordinator address via CREATE
        // 2. Deploy sub-contracts with that address
        // 3. Deploy coordinator

        // Compute coordinator address: deployer nonce is currently at some point,
        // we need to figure out how many deploys happen first.
        // Simpler: deploy coordinator address last. Sub-contracts need it.
        // Let's count: after setup tokens/alchemist/vrfCoordinator, we deploy
        // sub-contracts. We need the coordinator address BEFORE deploying them.

        // Use vm.computeCreateAddress to predict.
        // Current nonce for this contract:
        uint64 currentNonce = vm.getNonce(address(this));
        // We'll deploy: drawingManager, ticketNFT, luckToken, luckStaking, prizeVault, then coordinator
        // That's 5 deploys before coordinator, so coordinator nonce = currentNonce + 5
        address predictedCoordinator = vm.computeCreateAddress(address(this), currentNonce + 5);

        // Deploy sub-contracts with predicted coordinator address
        drawingManager = new DrawingManager(
            address(vrfCoordinator),
            predictedCoordinator,
            1, // subscriptionId
            bytes32(uint256(1)), // keyHash
            500_000, // callbackGasLimit
            3 // requestConfirmations
        );

        ticketNFT = new TicketNFT(predictedCoordinator);
        luckToken = new LuckToken(predictedCoordinator);
        luckStaking = new LuckStaking(address(luckToken), address(alUSD), predictedCoordinator);
        prizeVault = new PrizeVault(address(alUSD), predictedCoordinator);

        // Deploy coordinator — address should match prediction
        coordinator = new LuckyPotion(
            address(usdc),
            address(alUSD),
            address(alchemist),
            yieldToken,
            address(ticketNFT),
            address(luckToken),
            address(luckStaking),
            address(drawingManager),
            address(prizeVault),
            opsMultisig
        );
        assertEq(address(coordinator), predictedCoordinator, "coordinator address mismatch");

        // Prepare valid canvas (1024 bytes)
        validCanvas = new bytes(Constants.CANVAS_DATA_LENGTH);
        for (uint256 i = 0; i < Constants.CANVAS_DATA_LENGTH; i++) {
            validCanvas[i] = bytes1(uint8(i % 256));
        }

        // Fund alice and bob with USDC
        usdc.mint(alice, 1000e6); // 1000 USDC
        usdc.mint(bob, 1000e6);

        // Approve coordinator to spend USDC
        vm.prank(alice);
        usdc.approve(address(coordinator), type(uint256).max);
        vm.prank(bob);
        usdc.approve(address(coordinator), type(uint256).max);
    }

    // ──── Helpers ────

    function _initializeProtocol() internal {
        coordinator.initialize();
    }

    function _buyTicketAsAlice() internal returns (uint256 ticketId) {
        vm.prank(alice);
        ticketId = coordinator.buyTicket(validCanvas);
    }

    function _makeUniqueCanvas(uint8 seed) internal pure returns (bytes memory) {
        bytes memory canvas = new bytes(Constants.CANVAS_DATA_LENGTH);
        for (uint256 i = 0; i < Constants.CANVAS_DATA_LENGTH; i++) {
            canvas[i] = bytes1(uint8((i + seed) % 256));
        }
        return canvas;
    }

    function _advanceToDrawTime() internal {
        vm.warp(block.timestamp + Constants.DRAWING_DURATION + 1);
    }

    function _fulfillVRF(uint256 drawingId) internal {
        DrawingManager.Drawing memory d = drawingManager.getDrawing(drawingId);
        uint256[] memory randomWords = new uint256[](1);
        randomWords[0] = uint256(keccak256(abi.encodePacked("random", drawingId)));
        vrfCoordinator.fulfillRandomWordsWithOverride(d.vrfRequestId, randomWords);
    }

    // ══════════════════════════════════════════════
    //               INITIALIZATION
    // ══════════════════════════════════════════════

    function test_initialize() public {
        _initializeProtocol();
        assertTrue(coordinator.initialized());
        assertEq(drawingManager.currentDrawingId(), 1);
    }

    function test_initialize_twiceReverts() public {
        _initializeProtocol();
        vm.expectRevert(Errors.AlreadyInitialized.selector);
        coordinator.initialize();
    }

    function test_initialize_notOwnerReverts() public {
        vm.prank(alice);
        vm.expectRevert();
        coordinator.initialize();
    }

    // ══════════════════════════════════════════════
    //               TICKET PURCHASE
    // ══════════════════════════════════════════════

    function test_buyTicket_fullFlow() public {
        _initializeProtocol();

        uint256 aliceBefore = usdc.balanceOf(alice);
        uint256 ticketId = _buyTicketAsAlice();

        // USDC deducted
        assertEq(usdc.balanceOf(alice), aliceBefore - Constants.TICKET_PRICE);

        // NFT minted to alice
        assertEq(ticketNFT.ownerOf(ticketId), alice);

        // LUCK minted
        assertEq(luckToken.balanceOf(alice), Constants.LUCK_PER_TICKET);

        // Drawing ticket count
        DrawingManager.Drawing memory d = drawingManager.getDrawing(1);
        assertEq(d.totalTickets, 1);

        // Alchemist deposit
        assertEq(alchemist.deposited(address(coordinator)), Constants.TICKET_PRICE);
    }

    function test_buyTicket_whenPaused_reverts() public {
        _initializeProtocol();
        coordinator.setPaused(true);

        vm.prank(alice);
        vm.expectRevert(Errors.ProtocolPaused.selector);
        coordinator.buyTicket(validCanvas);
    }

    function test_buyTicket_whenNotInitialized_reverts() public {
        vm.prank(alice);
        vm.expectRevert(Errors.NotInitialized.selector);
        coordinator.buyTicket(validCanvas);
    }

    function test_buyTicket_whenDrawingClosed_reverts() public {
        _initializeProtocol();

        // Advance past close time (drawTime - cutoff is when sales close)
        vm.warp(block.timestamp + Constants.DRAWING_DURATION - Constants.TICKET_CUTOFF + 1);

        vm.prank(alice);
        vm.expectRevert(Errors.TicketSalesClosed.selector);
        coordinator.buyTicket(validCanvas);
    }

    function test_buyTickets_batch() public {
        _initializeProtocol();

        bytes[] memory canvases = new bytes[](5);
        for (uint256 i = 0; i < 5; i++) {
            canvases[i] = _makeUniqueCanvas(uint8(i));
        }

        vm.prank(alice);
        uint256[] memory ticketIds = coordinator.buyTickets(canvases);

        assertEq(ticketIds.length, 5);
        assertEq(usdc.balanceOf(alice), 1000e6 - (Constants.TICKET_PRICE * 5));
        assertEq(luckToken.balanceOf(alice), Constants.LUCK_PER_TICKET * 5);
        assertEq(alchemist.deposited(address(coordinator)), Constants.TICKET_PRICE * 5);

        DrawingManager.Drawing memory d = drawingManager.getDrawing(1);
        assertEq(d.totalTickets, 5);
    }

    function test_buyTickets_tooMany_reverts() public {
        _initializeProtocol();

        bytes[] memory canvases = new bytes[](101);
        for (uint256 i = 0; i < 101; i++) {
            canvases[i] = _makeUniqueCanvas(uint8(i));
        }

        vm.prank(alice);
        vm.expectRevert(Errors.BatchTooLarge.selector);
        coordinator.buyTickets(canvases);
    }

    function test_buyTickets_empty_reverts() public {
        _initializeProtocol();
        bytes[] memory empty = new bytes[](0);
        vm.prank(alice);
        vm.expectRevert(Errors.ZeroAmount.selector);
        coordinator.buyTickets(empty);
    }

    // ══════════════════════════════════════════════
    //               DRAWING TRIGGER
    // ══════════════════════════════════════════════

    function test_triggerDrawing_distributesCorrectly() public {
        _initializeProtocol();

        // Buy some tickets to generate deposits
        for (uint256 i = 0; i < 10; i++) {
            vm.prank(alice);
            coordinator.buyTicket(_makeUniqueCanvas(uint8(i)));
        }

        uint256 totalDeposited = Constants.TICKET_PRICE * 10; // 50 USDC (6 dec)
        uint256 expectedMintable = (totalDeposited * 1e12 * 9000) / 10000; // 90% LTV, scaled to 18 dec

        _advanceToDrawTime();

        uint256 opsBefore = alUSD.balanceOf(opsMultisig);

        coordinator.triggerDrawing();

        // Verify distribution
        uint256 opsReceived = alUSD.balanceOf(opsMultisig) - opsBefore;
        uint256 expectedOps = (expectedMintable * Constants.OPS_BPS) / Constants.BPS_DENOMINATOR;
        assertEq(opsReceived, expectedOps, "ops share incorrect");

        // Drawing should be PENDING_VRF
        DrawingManager.Drawing memory d = drawingManager.getDrawing(1);
        assertEq(uint8(d.state), uint8(DrawingManager.DrawingState.PENDING_VRF));
    }

    function test_triggerDrawing_beforeDrawTime_reverts() public {
        _initializeProtocol();
        _buyTicketAsAlice();

        vm.expectRevert(Errors.DrawingNotReady.selector);
        coordinator.triggerDrawing();
    }

    function test_triggerDrawing_noMintableAlUSD() public {
        _initializeProtocol();
        // No tickets bought — no deposits — zero mintable
        _advanceToDrawTime();

        // Should still succeed (requests VRF even with 0 alUSD)
        coordinator.triggerDrawing();

        DrawingManager.Drawing memory d = drawingManager.getDrawing(1);
        assertEq(uint8(d.state), uint8(DrawingManager.DrawingState.PENDING_VRF));
    }

    // ══════════════════════════════════════════════
    //               FINALIZE DRAWING
    // ══════════════════════════════════════════════

    function test_finalizeDrawing_startsNextDrawing() public {
        _initializeProtocol();
        _buyTicketAsAlice();
        _advanceToDrawTime();
        coordinator.triggerDrawing();

        // Fulfill VRF
        _fulfillVRF(1);

        // Finalize
        coordinator.finalizeDrawing();

        // Next drawing should be started
        assertEq(drawingManager.currentDrawingId(), 2);
    }

    function test_finalizeDrawing_notResolved_reverts() public {
        _initializeProtocol();
        _buyTicketAsAlice();
        _advanceToDrawTime();
        coordinator.triggerDrawing();

        // Don't fulfill VRF — still PENDING_VRF
        vm.expectRevert(Errors.DrawingNotResolved.selector);
        coordinator.finalizeDrawing();
    }

    // ══════════════════════════════════════════════
    //               PRIZE CLAIMS
    // ══════════════════════════════════════════════

    function test_claimPrize_validWinner() public {
        _initializeProtocol();

        // Buy ticket
        uint256 ticketId = _buyTicketAsAlice();
        TicketNFT.TicketData memory ticket = ticketNFT.getTicket(ticketId);

        // Buy more tickets to fund the drawing
        for (uint256 i = 1; i < 10; i++) {
            vm.prank(alice);
            coordinator.buyTicket(_makeUniqueCanvas(uint8(i)));
        }

        _advanceToDrawTime();
        coordinator.triggerDrawing();

        // Craft VRF result to match alice's first ticket's hash
        uint256[] memory randomWords = new uint256[](1);
        // The winning hash = randomWord % HASH_SPACE. We need it to equal ticket.canvasHash.
        randomWords[0] = uint256(ticket.canvasHash); // will produce winningHash = canvasHash

        DrawingManager.Drawing memory d = drawingManager.getDrawing(1);
        vrfCoordinator.fulfillRandomWordsWithOverride(d.vrfRequestId, randomWords);

        // Finalize
        coordinator.finalizeDrawing();

        // Claim
        uint256 aliceBefore = alUSD.balanceOf(alice);
        vm.prank(alice);
        coordinator.claimPrize(ticketId);

        assertTrue(alUSD.balanceOf(alice) > aliceBefore, "alice should have received prize");
        assertTrue(coordinator.ticketClaimed(ticketId), "ticket should be marked claimed");
    }

    function test_claimPrize_notOwner_reverts() public {
        _initializeProtocol();
        uint256 ticketId = _buyTicketAsAlice();

        vm.prank(bob);
        vm.expectRevert(Errors.NotTicketOwner.selector);
        coordinator.claimPrize(ticketId);
    }

    function test_claimPrize_notWinner_reverts() public {
        _initializeProtocol();
        uint256 ticketId = _buyTicketAsAlice();

        _advanceToDrawTime();
        coordinator.triggerDrawing();

        // Fulfill VRF with hash that won't match
        uint256[] memory randomWords = new uint256[](1);
        randomWords[0] = type(uint256).max; // very unlikely to match

        DrawingManager.Drawing memory d = drawingManager.getDrawing(1);
        vrfCoordinator.fulfillRandomWordsWithOverride(d.vrfRequestId, randomWords);
        coordinator.finalizeDrawing();

        // Check that the winning hash doesn't match our ticket
        DrawingManager.Drawing memory resolved = drawingManager.getDrawing(1);
        TicketNFT.TicketData memory ticket = ticketNFT.getTicket(ticketId);
        if (ticket.canvasHash == resolved.winningHash) {
            // Extremely unlikely but handle gracefully
            return;
        }

        vm.prank(alice);
        vm.expectRevert(Errors.TicketNotWinner.selector);
        coordinator.claimPrize(ticketId);
    }

    function test_claimPrize_doubleClaim_reverts() public {
        _initializeProtocol();
        uint256 ticketId = _buyTicketAsAlice();
        TicketNFT.TicketData memory ticket = ticketNFT.getTicket(ticketId);

        _advanceToDrawTime();
        coordinator.triggerDrawing();

        // Make alice's ticket win
        uint256[] memory randomWords = new uint256[](1);
        randomWords[0] = uint256(ticket.canvasHash);
        DrawingManager.Drawing memory d = drawingManager.getDrawing(1);
        vrfCoordinator.fulfillRandomWordsWithOverride(d.vrfRequestId, randomWords);
        coordinator.finalizeDrawing();

        // First claim
        vm.prank(alice);
        coordinator.claimPrize(ticketId);

        // Second claim
        vm.prank(alice);
        vm.expectRevert(Errors.TicketAlreadyClaimed.selector);
        coordinator.claimPrize(ticketId);
    }

    // ══════════════════════════════════════════════
    //               TICKET BURNS
    // ══════════════════════════════════════════════

    function test_burnTicket_losersOnly() public {
        _initializeProtocol();
        uint256 ticketId = _buyTicketAsAlice();

        _advanceToDrawTime();
        coordinator.triggerDrawing();

        // Fulfill with hash that won't match
        uint256[] memory randomWords = new uint256[](1);
        randomWords[0] = type(uint256).max;
        DrawingManager.Drawing memory d = drawingManager.getDrawing(1);
        vrfCoordinator.fulfillRandomWordsWithOverride(d.vrfRequestId, randomWords);
        coordinator.finalizeDrawing();

        // Verify not a winner (handle edge case)
        DrawingManager.Drawing memory resolved = drawingManager.getDrawing(1);
        TicketNFT.TicketData memory ticket = ticketNFT.getTicket(ticketId);
        if (ticket.canvasHash == resolved.winningHash) return; // skip if accidentally won

        uint256 luckBefore = luckToken.balanceOf(alice);

        vm.prank(alice);
        coordinator.burnTicket(ticketId);

        assertEq(luckToken.balanceOf(alice), luckBefore + Constants.BURN_LUCK_REWARD);
        assertTrue(coordinator.ticketBurned(ticketId));
    }

    function test_burnTicket_winner_reverts() public {
        _initializeProtocol();
        uint256 ticketId = _buyTicketAsAlice();
        TicketNFT.TicketData memory ticket = ticketNFT.getTicket(ticketId);

        _advanceToDrawTime();
        coordinator.triggerDrawing();

        // Make it win
        uint256[] memory randomWords = new uint256[](1);
        randomWords[0] = uint256(ticket.canvasHash);
        DrawingManager.Drawing memory d = drawingManager.getDrawing(1);
        vrfCoordinator.fulfillRandomWordsWithOverride(d.vrfRequestId, randomWords);
        coordinator.finalizeDrawing();

        vm.prank(alice);
        vm.expectRevert(Errors.CannotBurnWinningTicket.selector);
        coordinator.burnTicket(ticketId);
    }

    function test_burnTicket_activeDrawing_reverts() public {
        _initializeProtocol();
        uint256 ticketId = _buyTicketAsAlice();

        // Drawing still active (not resolved)
        vm.prank(alice);
        vm.expectRevert(Errors.CannotBurnActiveTicket.selector);
        coordinator.burnTicket(ticketId);
    }

    function test_burnTicket_doubleBurn_reverts() public {
        _initializeProtocol();
        uint256 ticketId = _buyTicketAsAlice();

        _advanceToDrawTime();
        coordinator.triggerDrawing();

        uint256[] memory randomWords = new uint256[](1);
        randomWords[0] = type(uint256).max;
        DrawingManager.Drawing memory d = drawingManager.getDrawing(1);
        vrfCoordinator.fulfillRandomWordsWithOverride(d.vrfRequestId, randomWords);
        coordinator.finalizeDrawing();

        TicketNFT.TicketData memory ticket = ticketNFT.getTicket(ticketId);
        DrawingManager.Drawing memory resolved = drawingManager.getDrawing(1);
        if (ticket.canvasHash == resolved.winningHash) return;

        vm.prank(alice);
        coordinator.burnTicket(ticketId);

        vm.prank(alice);
        vm.expectRevert(); // Token burned — ownerOf will revert
        coordinator.burnTicket(ticketId);
    }

    function test_burnTicket_mintsLUCK() public {
        _initializeProtocol();
        uint256 ticketId = _buyTicketAsAlice();

        _advanceToDrawTime();
        coordinator.triggerDrawing();

        uint256[] memory randomWords = new uint256[](1);
        randomWords[0] = type(uint256).max;
        DrawingManager.Drawing memory d = drawingManager.getDrawing(1);
        vrfCoordinator.fulfillRandomWordsWithOverride(d.vrfRequestId, randomWords);
        coordinator.finalizeDrawing();

        TicketNFT.TicketData memory ticket = ticketNFT.getTicket(ticketId);
        DrawingManager.Drawing memory resolved = drawingManager.getDrawing(1);
        if (ticket.canvasHash == resolved.winningHash) return;

        uint256 luckBefore = luckToken.balanceOf(alice);
        vm.prank(alice);
        coordinator.burnTicket(ticketId);
        assertEq(luckToken.balanceOf(alice) - luckBefore, Constants.BURN_LUCK_REWARD);
    }

    // ══════════════════════════════════════════════
    //               ADMIN
    // ══════════════════════════════════════════════

    function test_setPaused() public {
        coordinator.setPaused(true);
        assertTrue(coordinator.paused());
        coordinator.setPaused(false);
        assertFalse(coordinator.paused());
    }

    function test_setOpsMultisig() public {
        address newOps = makeAddr("newOps");
        coordinator.setOpsMultisig(newOps);
        assertEq(coordinator.opsMultisig(), newOps);
    }

    function test_setOpsMultisig_zeroAddress_reverts() public {
        vm.expectRevert(Errors.ZeroAddress.selector);
        coordinator.setOpsMultisig(address(0));
    }

    function test_rescueToken() public {
        MockERC20 random = new MockERC20("Random", "RND", 18);
        random.mint(address(coordinator), 100e18);

        coordinator.rescueToken(address(random), 100e18, deployer);
        assertEq(random.balanceOf(deployer), 100e18);
    }

    function test_rescueToken_protocolToken_reverts() public {
        vm.expectRevert(Errors.CannotRescueProtocolToken.selector);
        coordinator.rescueToken(address(usdc), 1, deployer);
    }

    // ══════════════════════════════════════════════
    //               VIEW FUNCTIONS
    // ══════════════════════════════════════════════

    function test_getCurrentDrawing() public {
        _initializeProtocol();
        DrawingManager.Drawing memory d = coordinator.getCurrentDrawing();
        assertEq(uint8(d.state), uint8(DrawingManager.DrawingState.OPEN));
    }

    function test_protocolStats() public {
        _initializeProtocol();
        _buyTicketAsAlice();

        (uint256 drawId, uint256 tickets, uint256 value, int256 debtVal) = coordinator.protocolStats();
        assertEq(drawId, 1);
        assertEq(tickets, 1);
        assertEq(value, Constants.TICKET_PRICE);
        assertEq(debtVal, 0); // no alUSD minted yet
    }

    function test_isWinner_beforeResolve() public {
        _initializeProtocol();
        uint256 ticketId = _buyTicketAsAlice();
        assertFalse(coordinator.isWinner(ticketId));
    }
}
