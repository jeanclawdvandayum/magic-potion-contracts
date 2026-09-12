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
import {MockDrandBeacon} from "../mocks/MockDrandBeacon.sol";

/// @title HandlerV2 — multi-actor chaos handler for invariant suite v2
/// @dev Differences vs v1: adversarial actor, shared-canvas collision pool,
///      direct donations (EX-05), sweeps (EX-06), force-close grief (EX-01),
///      fee-split flips, randomized drand signatures, lifecycle driver.
contract HandlerV2 is Test {
    LuckyPotion public coordinator;
    TicketNFT public ticketNFT;
    LuckToken public luckToken;
    LuckStaking public luckStaking;
    DrawingManager public drawingManager;
    PrizeVault public prizeVault;
    MockERC20 public alUSD;
    MockDrandBeacon public drandBeacon;
    address public deployer;

    address[] public actors;
    uint256[] public allTicketIds;

    // ─── Ghosts ───
    uint256 public ghost_totalTicketsBought;
    uint256 public ghost_totalTicketsBurned;
    uint256 public ghost_luckMinted;
    uint256 public ghost_drawingsFinalized;
    uint256 public ghost_canvasNonce = 1;

    constructor(
        LuckyPotion _coordinator,
        TicketNFT _ticketNFT,
        LuckToken _luckToken,
        LuckStaking _luckStaking,
        DrawingManager _drawingManager,
        PrizeVault _prizeVault,
        MockERC20 _alUSD,
        MockDrandBeacon _drandBeacon,
        address _deployer,
        address[] memory _actors
    ) {
        coordinator = _coordinator;
        ticketNFT = _ticketNFT;
        luckToken = _luckToken;
        luckStaking = _luckStaking;
        drawingManager = _drawingManager;
        prizeVault = _prizeVault;
        alUSD = _alUSD;
        drandBeacon = _drandBeacon;
        deployer = _deployer;
        actors = _actors;
    }

    // ──── Ticket actions ────

    function buyTicket(uint256 actorSeed, uint256 canvasSeed) external {
        address actor = actors[actorSeed % actors.length];
        bytes memory canvas = _makeCanvas(canvasSeed);

        vm.prank(actor);
        try coordinator.buyTicket(canvas) returns (uint256 ticketId) {
            allTicketIds.push(ticketId);
            ghost_totalTicketsBought++;
            ghost_luckMinted += Constants.LUCK_PER_TICKET;
        } catch {}
    }

    function buyTicketsBatch(uint256 actorSeed, uint8 count, uint256 canvasSeed) external {
        address actor = actors[actorSeed % actors.length];
        count = uint8(bound(count, 1, 5));
        bytes[] memory canvases = new bytes[](count);
        for (uint256 i; i < count; i++) {
            // 1-in-3 tickets in a batch deliberately collide on a shared canvas
            canvases[i] = (i % 3 == 0) ? _makeCanvas(canvasSeed + i) : _uniqueCanvas();
        }

        vm.prank(actor);
        try coordinator.buyTickets(canvases) returns (uint256[] memory ids) {
            for (uint256 i; i < ids.length; i++) {
                allTicketIds.push(ids[i]);
                ghost_totalTicketsBought++;
                ghost_luckMinted += Constants.LUCK_PER_TICKET;
            }
        } catch {}
    }

    function burnTicket(uint256 ticketSeed) external {
        if (allTicketIds.length == 0) return;
        uint256 ticketId = allTicketIds[ticketSeed % allTicketIds.length];
        try ticketNFT.ownerOf(ticketId) returns (address owner) {
            vm.prank(owner);
            try coordinator.burnTicket(ticketId) {
                ghost_totalTicketsBurned++;
                ghost_luckMinted += Constants.BURN_LUCK_REWARD;
            } catch {}
        } catch {}
    }

    // ──── Drawing lifecycle ────

    function advanceTime(uint256 seconds_) external {
        seconds_ = bound(seconds_, 1, 21 days);
        vm.warp(block.timestamp + seconds_);
    }

    /// @dev EX-01 grief: anyone force-closes sales in the cutoff window.
    function forceCloseSales(uint256 actorSeed) external {
        address actor = actors[actorSeed % actors.length];
        uint256 id = drawingManager.currentDrawingId();
        vm.prank(actor);
        try drawingManager.closeTicketSales(id) {} catch {}
    }

    function triggerDrawing() external {
        uint256 luckBefore = luckToken.totalSupply();
        try coordinator.triggerDrawing() {
            ghost_luckMinted += luckToken.totalSupply() - luckBefore;
        } catch {}
    }

    /// @dev Randomized drand signature → unpredictable winning hash
    ///      (no-winner, single-winner and multi-winner outcomes all reachable).
    function submitRandomness(uint256 seedA, uint256 seedB) external {
        uint256 drawingId = drawingManager.currentDrawingId();
        DrawingManager.Drawing memory d = drawingManager.getDrawing(drawingId);
        if (d.state != DrawingManager.DrawingState.PENDING_RANDOMNESS) return;

        uint256[2] memory sig = [uint256(keccak256(abi.encode(seedA))), uint256(keccak256(abi.encode(seedB)))];
        drandBeacon.setSignature(d.targetRound, sig);
        try drawingManager.submitRandomness(drawingId, d.targetRound, sig) {} catch {}
    }

    function finalizeDrawing() external {
        uint256 luckBefore = luckToken.totalSupply();
        try coordinator.finalizeDrawing() {
            ghost_drawingsFinalized++;
            ghost_luckMinted += luckToken.totalSupply() - luckBefore;
        } catch {}
    }

    /// @dev Deterministic progression so the drawing machine is always
    ///      exercised regardless of how the fuzzer sequences raw actions.
    function driveLifecycle(uint256 seed) external {
        uint256 drawingId = drawingManager.currentDrawingId();
        DrawingManager.Drawing memory d = drawingManager.getDrawing(drawingId);

        if (d.state == DrawingManager.DrawingState.OPEN) {
            if (block.timestamp >= d.drawTime) {
                this.triggerDrawing();
            } else if (block.timestamp >= d.closeTime && seed % 2 == 0) {
                this.forceCloseSales(seed);
            } else {
                return;
            }
            drawingId = drawingManager.currentDrawingId();
            d = drawingManager.getDrawing(drawingId);
        }
        if (d.state == DrawingManager.DrawingState.PENDING_RANDOMNESS) {
            this.submitRandomness(seed, seed + 1);
            d = drawingManager.getDrawing(drawingId);
        }
        if (d.state == DrawingManager.DrawingState.RESOLVED) {
            this.finalizeDrawing();
        }
    }

    // ──── Claims & sweeps ────

    function claimPrize(uint256 ticketSeed) external {
        if (allTicketIds.length == 0) return;
        uint256 ticketId = allTicketIds[ticketSeed % allTicketIds.length];
        try ticketNFT.ownerOf(ticketId) returns (address owner) {
            vm.prank(owner);
            try coordinator.claimPrize(ticketId) {} catch {}
        } catch {}
    }

    /// @dev EX-06: sweep stale unclaimed prizes into the rollover.
    function sweepUnclaimed(uint256 drawingSeed) external {
        uint256 currentId = drawingManager.currentDrawingId();
        if (currentId == 0) return;
        uint256 drawingId = (drawingSeed % currentId) + 1;
        address actor = actors[drawingSeed % actors.length];
        vm.prank(actor);
        try prizeVault.sweepUnclaimed(drawingId) {} catch {}
    }

    // ──── Staking ────

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
        (uint256 stakedAmount,,) = luckStaking.userInfo(actor);
        if (stakedAmount == 0) return;
        amount = bound(amount, 1, stakedAmount);

        vm.prank(actor);
        try luckStaking.unstake(amount) {} catch {}
    }

    function claimStakingRewards(uint256 actorSeed) external {
        address actor = actors[actorSeed % actors.length];
        vm.prank(actor);
        try luckStaking.claimRewards() {} catch {}
    }

    /// @dev EX-05: direct alUSD donation straight into LuckStaking.
    function donateToStaking(uint256 amount) external {
        amount = bound(amount, 1, 1000e18);
        alUSD.mint(address(this), amount);
        alUSD.transfer(address(luckStaking), amount);
    }

    // ──── Owner-config chaos ────

    function flipFeeSplit(uint256 stakingSeed) external {
        uint256 stakingBps = uint16(bound(stakingSeed, 0, 2000)); // ≤20%
        uint256 treasuryBps = uint16(bound(stakingSeed >> 16, 0, 2000));
        vm.prank(deployer);
        try coordinator.setFeeSplit(stakingBps, treasuryBps) {} catch {}
    }

    // ──── Internal ───

    /// @dev 1-in-4 canvases deliberately drawn from a tiny shared pool so
    ///      multi-winner exact-split math gets hammered.
    function _makeCanvas(uint256 seed) internal view returns (bytes memory) {
        if (seed % 4 == 0) seed = seed % 16; // collision pool
        return _canvasFromSeed(seed);
    }

    function _uniqueCanvas() internal returns (bytes memory) {
        ghost_canvasNonce++;
        return _canvasFromSeed(ghost_canvasNonce);
    }

    function _canvasFromSeed(uint256 seed) internal pure returns (bytes memory) {
        bytes32 h = keccak256(abi.encode(seed));
        bytes memory c = new bytes(Constants.CANVAS_DATA_LENGTH);
        for (uint256 i = 0; i < Constants.CANVAS_DATA_LENGTH; i++) {
            c[i] = h[i % 32];
        }
        return c;
    }

    // ──── Views ────

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function getTicketCount() external view returns (uint256) {
        return allTicketIds.length;
    }

    /// @dev Σ pending staking rewards across all actors — used by solvency.
    function sumPendingRewards() external view returns (uint256 total) {
        for (uint256 i = 0; i < actors.length; i++) {
            total += luckStaking.pendingRewards(actors[i]);
        }
    }
}
