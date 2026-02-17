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
import {Handler} from "./Handler.sol";

/// @title Invariants — Stateful invariant tests for critical protocol properties
contract InvariantsTest is Test {
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
    Handler public handler;

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

        coordinator.initialize();

        // Fund actors
        address[] memory actors = new address[](3);
        actors[0] = alice;
        actors[1] = bob;
        actors[2] = charlie;

        for (uint256 i = 0; i < 3; i++) {
            usdc.mint(actors[i], 1_000_000e6);
            vm.prank(actors[i]);
            usdc.approve(address(coordinator), type(uint256).max);
        }

        handler = new Handler(
            coordinator, ticketNFT, luckToken, luckStaking, drawingManager,
            prizeVault, usdc, alUSD, vrfCoordinator, actors
        );

        // Target only the handler
        targetContract(address(handler));
    }

    // ──── INV-2: LUCK supply matches expected mints ────

    function invariant_luckSupplyConsistency() public view {
        uint256 totalSupply = luckToken.totalSupply();
        uint256 expectedMinted = handler.ghost_totalLuckMinted();
        assertEq(totalSupply, expectedMinted, "INV-2: LUCK supply mismatch");
    }

    // ──── INV-3: No alUSD stuck in coordinator ────
    // After distributions, coordinator should not hold significant alUSD
    // (small dust from rounding is acceptable)

    function invariant_noAlUSDStuckInCoordinator() public view {
        uint256 coordBalance = alUSD.balanceOf(address(coordinator));
        // Allow up to 1 wei per drawing triggered (rounding dust)
        uint256 maxDust = handler.ghost_totalDrawingsTriggered() + 1;
        assertLe(coordBalance, maxDust, "INV-3: alUSD stuck in coordinator");
    }

    // ──── INV-4: Prize vault solvency ────
    // PrizeVault's alUSD balance >= claimable prizes + rollover
    // Only count drawings WITH winners (no-winner drawings roll over, so their
    // allocation is already accounted for in rollover or the next drawing).

    function invariant_prizeVaultSolvency() public view {
        uint256 vaultBalance = alUSD.balanceOf(address(prizeVault));
        uint256 currentDrawing = drawingManager.currentDrawingId();

        uint256 totalOwed;
        for (uint256 i = 1; i <= currentDrawing; i++) {
            PrizeVault.DrawingPrize memory info = prizeVault.getPrizeInfo(i);
            // Only count drawings that have winners (no-winner allocations rolled over)
            if (info.resolved && info.winnerCount > 0 && info.allocated > info.claimed) {
                totalOwed += info.allocated - info.claimed;
            }
        }
        // Add rollover (unclaimed, waiting to be applied to next drawing)
        totalOwed += prizeVault.rolledOverBalance();

        assertGe(vaultBalance, totalOwed, "INV-4: prize vault insolvent");
    }

    // ──── INV-5: Staking solvency ────
    // LuckStaking's LUCK balance >= total staked

    function invariant_stakingSolvency() public view {
        uint256 stakingLuckBalance = luckToken.balanceOf(address(luckStaking));
        uint256 totalStaked = luckStaking.totalStaked();
        assertGe(stakingLuckBalance, totalStaked, "INV-5: staking LUCK insolvent");
    }

    // ──── INV-8: Drawing state only moves forward ────

    function invariant_drawingStateOnlyForward() public view {
        uint256 currentId = drawingManager.currentDrawingId();
        for (uint256 i = 1; i <= currentId; i++) {
            DrawingManager.Drawing memory d = drawingManager.getDrawing(i);
            // Past drawings should be RESOLVED, current can be any state
            if (i < currentId) {
                assertEq(
                    uint8(d.state),
                    uint8(DrawingManager.DrawingState.RESOLVED),
                    "INV-8: past drawing not resolved"
                );
            }
        }
    }

    // ──── INV-9: Ticket count consistency ────

    function invariant_ticketCountConsistency() public view {
        uint256 currentId = drawingManager.currentDrawingId();
        uint256 totalFromDrawings;
        for (uint256 i = 1; i <= currentId; i++) {
            DrawingManager.Drawing memory d = drawingManager.getDrawing(i);
            totalFromDrawings += d.totalTickets;
        }
        assertEq(totalFromDrawings, handler.ghost_totalTicketsBought(), "INV-9: ticket count mismatch");
    }

    // ──── INV-15: LUCK supply only increases ────
    // LUCK has no burn mechanism (only minting from buys + burns)

    function invariant_luckSupplyOnlyIncreases() public view {
        // LUCK total supply should always equal ghost_totalLuckMinted
        // which only increases
        assertEq(
            luckToken.totalSupply(),
            handler.ghost_totalLuckMinted(),
            "INV-15: LUCK supply decreased"
        );
    }
}
