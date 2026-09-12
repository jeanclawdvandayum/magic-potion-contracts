// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {LuckyPotion} from "../../src/LuckyPotion.sol";
import {TicketNFT} from "../../src/TicketNFT.sol";
import {LuckToken} from "../../src/LuckToken.sol";
import {LuckStaking} from "../../src/LuckStaking.sol";
import {DrawingManager} from "../../src/DrawingManager.sol";
import {PrizeVault} from "../../src/PrizeVault.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockAlchemistV3, MockMYTVault} from "../mocks/MockAlchemistV3.sol";
import {MockDrandBeacon} from "../mocks/MockDrandBeacon.sol";
import {HandlerV2} from "./HandlerV2.sol";

/// @title InvariantsV2 — multi-actor chaos invariants (EX-05/EX-06 paths)
/// @dev v1 keeps its own suite; this one exercises donations, sweeps,
///      force-closes, fee flips, canvas collisions and randomized drand.
contract InvariantsV2Test is Test {
    LuckyPotion public coordinator;
    TicketNFT public ticketNFT;
    LuckToken public luckToken;
    LuckStaking public luckStaking;
    DrawingManager public drawingManager;
    PrizeVault public prizeVault;
    MockERC20 public usdc;
    MockERC20 public alUSD;
    MockAlchemistV3 public alchemist;
    MockDrandBeacon public drandBeacon;
    HandlerV2 public handler;

    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public charlie = makeAddr("charlie");
    address public mallory = makeAddr("mallory"); // griefer
    address public treasury = makeAddr("treasury");
    MockMYTVault public mytVault;
    MockERC20 public mytShare;

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        alUSD = new MockERC20("Alchemix USD", "alUSD", 18);
        mytShare = new MockERC20("Mock MYT", "mytMOCK", 18);
        mytVault = new MockMYTVault(address(usdc), address(mytShare));
        alchemist = new MockAlchemistV3(address(alUSD), address(usdc), address(mytVault), address(0));
        drandBeacon = new MockDrandBeacon();

        uint64 nonce = vm.getNonce(address(this));
        address predicted = vm.computeCreateAddress(address(this), nonce + 5);

        drawingManager = new DrawingManager(address(drandBeacon), predicted);
        ticketNFT = new TicketNFT(predicted);
        luckToken = new LuckToken(predicted);
        luckStaking = new LuckStaking(address(luckToken), address(alUSD), predicted);
        prizeVault = new PrizeVault(address(alUSD), predicted);

        coordinator = new LuckyPotion(
            address(usdc), address(alUSD), address(alchemist), address(alchemist.mytVaultAddress()),
            address(ticketNFT), address(luckToken), address(luckStaking),
            address(drawingManager), address(prizeVault), treasury
        );

        coordinator.initialize();

        address[] memory actors = new address[](4);
        actors[0] = alice;
        actors[1] = bob;
        actors[2] = charlie;
        actors[3] = mallory;

        for (uint256 i = 0; i < 4; i++) {
            usdc.mint(actors[i], 1_000_000e6);
            vm.prank(actors[i]);
            usdc.approve(address(coordinator), type(uint256).max);
        }

        handler = new HandlerV2(
            coordinator, ticketNFT, luckToken, luckStaking, drawingManager,
            prizeVault, alUSD, drandBeacon, address(this), actors
        );

        targetContract(address(handler));
        bytes4[] memory sels = new bytes4[](16);
        sels[0] = handler.buyTicket.selector;
        sels[1] = handler.buyTicketsBatch.selector;
        sels[2] = handler.burnTicket.selector;
        sels[3] = handler.advanceTime.selector;
        sels[4] = handler.forceCloseSales.selector;
        sels[5] = handler.triggerDrawing.selector;
        sels[6] = handler.submitRandomness.selector;
        sels[7] = handler.finalizeDrawing.selector;
        sels[8] = handler.driveLifecycle.selector;
        sels[9] = handler.claimPrize.selector;
        sels[10] = handler.sweepUnclaimed.selector;
        sels[11] = handler.stakeLuck.selector;
        sels[12] = handler.unstakeLuck.selector;
        sels[13] = handler.claimStakingRewards.selector;
        sels[14] = handler.donateToStaking.selector;
        sels[15] = handler.flipFeeSplit.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: sels}));
    }

    // ──── INV-2: LUCK supply matches expected mints ────

    function invariant_luckSupplyConsistency() public view {
        assertEq(luckToken.totalSupply(), handler.ghost_luckMinted(), "INV-2: LUCK supply mismatch");
    }

    // ──── INV-3: no alUSD stranded in coordinator ────

    function invariant_noAlusdStuckInCoordinator() public view {
        assertLe(
            alUSD.balanceOf(address(coordinator)),
            handler.ghost_drawingsFinalized() + 1,
            "INV-3: alUSD stuck in coordinator"
        );
    }

    // ──── INV-4: prize vault solvency (incl. EX-06 sweeps) ────

    function invariant_prizeVaultSolvency() public view {
        uint256 vaultBalance = alUSD.balanceOf(address(prizeVault));
        uint256 currentId = drawingManager.currentDrawingId();

        uint256 totalOwed;
        for (uint256 i = 1; i <= currentId; i++) {
            PrizeVault.DrawingPrize memory info = prizeVault.getPrizeInfo(i);
            if (info.resolved && info.winnerCount > 0 && info.allocated > info.claimed) {
                totalOwed += info.allocated - info.claimed;
            }
        }
        totalOwed += prizeVault.rolledOverBalance();

        assertGe(vaultBalance, totalOwed, "INV-4: prize vault insolvent");
    }

    // ──── INV-5a: staking LUCK solvency ────

    function invariant_stakingLuckSolvency() public view {
        assertGe(
            luckToken.balanceOf(address(luckStaking)),
            luckStaking.totalStaked(),
            "INV-5a: staking LUCK insolvent"
        );
    }

    // ──── INV-5b: staking alUSD solvency (EX-05 + paidOut class) ────
    // The contract must always be able to pay every staker's pending rewards.
    // This is the invariant that would have caught the paidOut double-count.

    function invariant_stakingAlusdSolvency() public view {
        assertGe(
            alUSD.balanceOf(address(luckStaking)),
            handler.sumPendingRewards(),
            "INV-5b: staking alUSD insolvent"
        );
    }

    // ──── INV-5c: staking accounting identity ────
    // balance ≥ credited − paidOut at all times (donations only push the
    // balance ABOVE credited−paidOut, never below; a violation means the
    // distribution accounting is broken).

    function invariant_stakingAccountingIdentity() public view {
        assertGe(
            alUSD.balanceOf(address(luckStaking)),
            luckStaking.credited() - luckStaking.paidOut(),
            "INV-5c: staking accounting identity broken"
        );
    }

    // ──── INV-8: past drawings always RESOLVED ────

    function invariant_drawingStateOnlyForward() public view {
        uint256 currentId = drawingManager.currentDrawingId();
        for (uint256 i = 1; i < currentId; i++) {
            DrawingManager.Drawing memory d = drawingManager.getDrawing(i);
            assertEq(
                uint8(d.state),
                uint8(DrawingManager.DrawingState.RESOLVED),
                "INV-8: past drawing not resolved"
            );
        }
    }

    // ──── INV-9: ticket population matches ghosts ────

    function invariant_ticketPopulation() public view {
        assertEq(
            ticketNFT.totalSupply(),
            handler.ghost_totalTicketsBought() - handler.ghost_totalTicketsBurned(),
            "INV-9: live ticket count mismatch"
        );
    }

    // ──── INV-10: LUCK conservation across actors + staking + keeper ────
    // LUCK never leaves the actors∪staking∪handler set in this harness (the
    // handler acts as keeper and receives EX-07 keeper rewards), so supply
    // must be fully accounted for there.

    function invariant_luckConservation() public view {
        uint256 accounted = luckToken.balanceOf(address(luckStaking));
        accounted += luckToken.balanceOf(address(handler)); // keeper rewards
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            accounted += luckToken.balanceOf(handler.actors(i));
        }
        assertEq(accounted, luckToken.totalSupply(), "INV-10: LUCK leaked");
    }
}
