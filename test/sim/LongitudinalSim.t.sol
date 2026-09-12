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
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockAlchemistV3, MockMYTVault} from "../mocks/MockAlchemistV3.sol";
import {MockDrandBeacon} from "../mocks/MockDrandBeacon.sol";

/// @title LongitudinalSim — 26 weeks, 12 behavioral archetypes, full settlement
/// @dev Deterministic multi-user simulation across ~6 months of weekly
///      drawings. Exercises every mechanism concurrently: batch buys, canvas
///      collisions (multi-winner splits), last-second buys, grief closes,
///      late triggers, staking lumps, donations, burns, lazy claims, sweeps.
///      Settlement then forces every claim + sweep and asserts exact token
///      accounting across the entire history.
contract LongitudinalSimTest is Test {
    LuckyPotion coordinator;
    TicketNFT ticketNFT;
    LuckToken luckToken;
    LuckStaking luckStaking;
    DrawingManager drawingManager;
    PrizeVault prizeVault;
    MockERC20 usdc;
    MockERC20 alUSD;
    MockAlchemistV3 alchemist;
    MockDrandBeacon drandBeacon;
    MockMYTVault mytVault;
    MockERC20 mytShare;

    address treasury = makeAddr("treasury");

    uint256 constant USERS = 12;
    uint256 constant WEEKS = 26;
    mapping(uint256 => address) public user;
    string[USERS] NAMES = [
        "regular0", "regular1", "regular2", "whale", "neverbloom",
        "lumpstaker", "steadystaker0", "steadystaker1", "donor",
        "burner", "collider", "sniper"
    ];

    // per-user ticket ledger
    mapping(uint256 => uint256[]) public tickets; // live tickets
    uint256 public totalBought;
    uint256 public totalBurned;
    uint256 public totalClaimedTickets;

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

        for (uint256 i = 0; i < USERS; i++) {
            user[i] = makeAddr(NAMES[i]);
            usdc.mint(user[i], 1_000_000e6);
            vm.prank(user[i]);
            usdc.approve(address(coordinator), type(uint256).max);
            vm.prank(user[i]);
            luckToken.approve(address(luckStaking), type(uint256).max);
        }
        // donor needs alUSD to donate (steadystakers earn LUCK via buys)
        alUSD.mint(user[8], 10_000e18);
    }

    // ──── deterministic PRNG ────
    function _rand(uint256 week, uint256 i, uint256 salt) internal pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked("magicpotion", week, i, salt)));
    }

    function _canvas(uint256 seed) internal pure returns (bytes memory) {
        // 1024-byte canvas (64×64, 2 bits/pixel), uniform fill from seed —
        // hash = keccak(canvas) & 0xFFFF, uniform over the uint16 space
        bytes memory canvas = new bytes(1024);
        bytes1 fill = bytes1(uint8(uint256(keccak256(abi.encode(seed)))));
        for (uint256 i = 0; i < 1024; i++) canvas[i] = fill;
        return canvas;
    }

    function _buy(uint256 i, uint256 week, uint256 salt) internal returns (uint256 id) {
        uint256 seed = _rand(week, i, salt);
        vm.prank(user[i]);
        id = coordinator.buyTicket(_canvas(seed));
        tickets[i].push(id);
        totalBought++;
    }

    function _burnLosers(uint256 i, uint256 drawingId) internal {
        uint256[] storage ids = tickets[i];
        uint256 winningHash = drawingManager.getDrawing(drawingId).winningHash;
        for (uint256 k = ids.length; k > 0; k--) {
            uint256 id = ids[k - 1];
            if (ticketNFT.getTicket(id).drawingId != drawingId) continue;
            if (ticketNFT.getTicket(id).canvasHash != winningHash) {
                vm.prank(user[i]);
                coordinator.burnTicket(id);
                ids[k - 1] = ids[ids.length - 1];
                ids.pop();
                totalBurned++;
            }
        }
    }

    function _claimAll(uint256 i) internal {
        uint256[] storage ids = tickets[i];
        for (uint256 k = 0; k < ids.length; k++) {
            vm.prank(user[i]);
            try coordinator.claimPrize(ids[k]) {
                totalClaimedTickets++;
            } catch {}
        }
    }

    // ──── one week of the protocol ────
    function _runWeek(uint256 week) internal {
        uint256 currentId = drawingManager.currentDrawingId();
        DrawingManager.Drawing memory d = drawingManager.getDrawing(currentId);

        // ── buys across the open window
        for (uint256 i = 0; i < 3; i++) {
            // regulars: 1-2 tickets, sometimes skip
            if (_rand(week, i, 1) % 5 != 0) {
                _buy(i, week, 100 + i);
                if (_rand(week, i, 2) % 3 == 0) _buy(i, week, 200 + i);
            }
        }
        // whale: batch every other week
        if (week % 2 == 0) {
            uint256 count = 5 + _rand(week, 3, 3) % 20;
            bytes[] memory canvases = new bytes[](count);
            for (uint256 k = 0; k < count; k++) {
                canvases[k] = _canvas(_rand(week, k + 1000, 4));
            }
            vm.prank(user[3]);
            uint256[] memory ids = coordinator.buyTickets(canvases);
            for (uint256 k = 0; k < count; k++) {
                tickets[3].push(ids[k]);
                totalBought++;
            }
        }
        // neverbloom: buys 2/wk, NEVER claims (sweep food)
        _buy(4, week, 5);
        _buy(4, week, 6);

        // donor: 1 ticket + direct alUSD donation to staking every 3rd week
        _buy(8, week, 7);
        if (week % 3 == 0) {
            vm.prank(user[8]);
            alUSD.transfer(address(luckStaking), 5e18);
        }

        // collider: deliberately reuses regular0's canvas (multi-winner split)
        if (_rand(week, 0, 1) % 5 != 0) {
            uint256 dup = _rand(week, 0, 100);
            vm.prank(user[10]);
            uint256 id = coordinator.buyTicket(_canvas(dup));
            tickets[10].push(id);
            totalBought++;
        }

        // steadystakers: 1 ticket/wk each, stake ALL earned LUCK at week 2,
        // claim weekly from week 4
        _buy(6, week, 12);
        _buy(7, week, 13);
        if (week == 2) {
            uint256 b6 = luckToken.balanceOf(user[6]);
            uint256 b7 = luckToken.balanceOf(user[7]);
            if (b6 > 0) { vm.prank(user[6]); luckStaking.stake(b6); }
            if (b7 > 0) { vm.prank(user[7]); luckStaking.stake(b7); }
        }
        if (week >= 4 && week % 1 == 0) {
            vm.prank(user[6]);
            try luckStaking.claimRewards() {} catch {}
            vm.prank(user[7]);
            try luckStaking.claimRewards() {} catch {}
        }

        // sniper: last-second buy right before closeTime
        d = drawingManager.getDrawing(currentId);
        vm.warp(d.closeTime - 1);
        _buy(11, week, 8);

        // lumpstaker: stake everything earned so far, one second before close
        if (week >= 3) {
            uint256 luckBal = luckToken.balanceOf(user[5]);
            if (luckBal > 0) {
                vm.prank(user[5]);
                luckStaking.stake(luckBal);
            }
        }

        // grief close on some weeks (EX-01 path)
        if (week % 7 == 3) {
            try drawingManager.closeTicketSales(currentId) {} catch {}
        }

        // ── trigger → randomness → finalize (late by ~2 days on some weeks)
        d = drawingManager.getDrawing(currentId);
        if (week % 5 == 0) vm.warp(d.drawTime + 2 days);
        else vm.warp(d.drawTime + 1);

        coordinator.triggerDrawing();

        uint256[2] memory sig = [uint256(1) << 250 | _rand(week, 9, 9), _rand(week, 9, 10)];
        // mock beacon: set sig then submit
        DrawingManager.Drawing memory dw = drawingManager.getDrawing(currentId);
        uint256 targetRound = dw.targetRound;
        drandBeacon.setSignature(targetRound, sig);
        drawingManager.submitRandomness(currentId, targetRound, sig);

        coordinator.finalizeDrawing();

        // lumpstaker unstakes right after finalize (free-ride pattern, EX-04)
        if (week >= 3) {
            (uint256 staked5,,) = luckStaking.userInfo(user[5]);
            if (staked5 > 0) {
                vm.prank(user[5]);
                luckStaking.unstake(staked5);
            }
        }

        // burner: burns all losing tickets from the just-resolved drawing
        _burnLosers(9, currentId);

        // lazy claims: regulars claim with 60% probability each week
        if (_rand(week, 1, 11) % 5 < 3) _claimAll(0);
        if (_rand(week, 2, 11) % 5 < 3) _claimAll(1);
        if (week % 4 == 0) _claimAll(3);

        // opportunistic sweeps of long-dead drawings
        if (week % 6 == 0 && currentId > 5) {
            uint256 high = currentId - 5;
            uint256 low = currentId > 10 ? currentId - 10 : 1;
            for (uint256 did = high; did >= low; did--) {
                try prizeVault.sweepUnclaimed(did) {} catch {}
            }
        }
    }

    function test_longitudinal_26weeks_fullSettlement() public {
        for (uint256 week = 1; week <= WEEKS; week++) {
            _runWeek(week);
        }

        uint256 lastId = drawingManager.currentDrawingId();

        // ── settlement: everyone claims everything claimable
        for (uint256 i = 0; i < USERS; i++) _claimAll(i);

        // warp past every claim window, sweep every drawing
        vm.warp(block.timestamp + 35 days);
        for (uint256 did = 1; did < lastId; did++) {
            try prizeVault.sweepUnclaimed(did) {} catch {}
        }

        // steadystakers + lumpstaker exit fully
        vm.prank(user[6]);
        try luckStaking.claimRewards() {} catch {}
        vm.prank(user[7]);
        try luckStaking.claimRewards() {} catch {}
        (uint256 s6,,) = luckStaking.userInfo(user[6]);
        (uint256 s7,,) = luckStaking.userInfo(user[7]);
        if (s6 > 0) { vm.prank(user[6]); luckStaking.unstake(s6); }
        if (s7 > 0) { vm.prank(user[7]); luckStaking.unstake(s7); }

        // ════ SETTLEMENT ASSERTIONS ════

        // (1) per-drawing sanity: never over-claimed, allocations only on
        //     resolved drawings
        for (uint256 did = 1; did < lastId; did++) {
            PrizeVault.DrawingPrize memory p = prizeVault.getPrizeInfo(did);
            assertLe(p.claimed, p.allocated, "over-claimed drawing");
            if (p.allocated > 0) {
                assertTrue(p.resolved, "allocated but unresolved");
            }
        }

        // (2) vault solvency: balance covers rollover + last drawing's live claims
        uint256 vaultBal = alUSD.balanceOf(address(prizeVault));
        uint256 owed;
        for (uint256 did = 1; did <= lastId; did++) {
            PrizeVault.DrawingPrize memory p = prizeVault.getPrizeInfo(did);
            if (p.resolved && p.allocated > p.claimed) owed += p.allocated - p.claimed;
        }
        assertGe(vaultBal, owed + prizeVault.rolledOverBalance(), "vault insolvent at settlement");

        // (3) staking solvency + accounting identity (EX-05 machinery, incl. donations)
        uint256 pendingSum;
        for (uint256 i = 0; i < USERS; i++) {
            pendingSum += luckStaking.pendingRewards(user[i]);
        }
        assertGe(alUSD.balanceOf(address(luckStaking)), pendingSum, "staking insolvent");
        assertGe(
            alUSD.balanceOf(address(luckStaking)),
            luckStaking.credited() - luckStaking.paidOut(),
            "staking identity broken"
        );

        // (4) LUCK conservation: every token lives at a user, staking, or keeper
        uint256 luckAccounted = luckToken.balanceOf(address(luckStaking)) + luckToken.balanceOf(address(this));
        for (uint256 i = 0; i < USERS; i++) luckAccounted += luckToken.balanceOf(user[i]);
        assertEq(luckAccounted, luckToken.totalSupply(), "LUCK leaked over 26 weeks");

        // (5) ticket population
        assertEq(ticketNFT.totalSupply(), totalBought - totalBurned, "ticket ledger broken");

        // (6) protocol drew ~26 drawings and state machine stayed monotonic
        assertGe(lastId, WEEKS - 2, "drawings stalled");
        for (uint256 did = 1; did < lastId; did++) {
            assertEq(
                uint8(drawingManager.getDrawing(did).state),
                uint8(DrawingManager.DrawingState.RESOLVED),
                "past drawing unresolved"
            );
        }

        // (7) treasury got paid across the whole run
        assertGt(alUSD.balanceOf(treasury), 0, "treasury starved");
    }

    // allow receiving keeper LUCK? (trigger caller is this contract)
    receive() external payable {}
}
