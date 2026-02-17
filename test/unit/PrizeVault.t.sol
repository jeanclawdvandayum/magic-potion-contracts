// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {PrizeVault} from "../../src/PrizeVault.sol";
import {Errors} from "../../src/libraries/Errors.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

contract PrizeVaultTest is Test {
    PrizeVault vault;
    MockERC20 alUSD;
    address coordinator = address(0xC00D);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    function setUp() public {
        alUSD = new MockERC20("Alchemix USD", "alUSD", 18);
        vault = new PrizeVault(address(alUSD), coordinator);

        // Fund coordinator with alUSD
        alUSD.mint(coordinator, 100_000e18);
        vm.prank(coordinator);
        alUSD.approve(address(vault), type(uint256).max);
    }

    // ──── Deposit ────

    function test_deposit_onlyCoordinator() public {
        vm.prank(coordinator);
        vault.deposit(1, 1000e18);

        (uint256 allocated,,,,) = vault.drawings(1);
        assertEq(allocated, 1000e18);
        assertEq(alUSD.balanceOf(address(vault)), 1000e18);
    }

    function test_deposit_nonCoordinator_reverts() public {
        alUSD.mint(alice, 1000e18);
        vm.prank(alice);
        vm.expectRevert(Errors.OnlyCoordinator.selector);
        vault.deposit(1, 1000e18);
    }

    function test_deposit_increasesAllocation() public {
        vm.startPrank(coordinator);
        vault.deposit(1, 500e18);
        vault.deposit(1, 300e18);
        vm.stopPrank();

        (uint256 allocated,,,,) = vault.drawings(1);
        assertEq(allocated, 800e18);
    }

    function test_deposit_zeroAmount_reverts() public {
        vm.prank(coordinator);
        vm.expectRevert(Errors.ZeroAmount.selector);
        vault.deposit(1, 0);
    }

    // ──── Resolve ────

    function test_resolveDrawing_noWinner_rollsOver() public {
        vm.startPrank(coordinator);
        vault.deposit(1, 1000e18);
        vault.resolveDrawing(1, 0x1234, 0); // 0 winners
        vm.stopPrank();

        assertEq(vault.rolledOverBalance(), 1000e18);
    }

    function test_resolveDrawing_withWinner() public {
        vm.startPrank(coordinator);
        vault.deposit(1, 1000e18);
        vault.resolveDrawing(1, 0x1234, 3);
        vm.stopPrank();

        (,, uint256 winnerCount, bool resolved,) = vault.drawings(1);
        assertEq(winnerCount, 3);
        assertTrue(resolved);
        assertEq(vault.rolledOverBalance(), 0);
    }

    function test_doubleResolve_reverts() public {
        vm.startPrank(coordinator);
        vault.deposit(1, 1000e18);
        vault.resolveDrawing(1, 0x1234, 1);
        vm.expectRevert(Errors.DrawingAlreadyTriggered.selector);
        vault.resolveDrawing(1, 0x5678, 2);
        vm.stopPrank();
    }

    // ──── Rollover ────

    function test_applyRollover_addsToNewDrawing() public {
        vm.startPrank(coordinator);
        vault.deposit(1, 1000e18);
        vault.resolveDrawing(1, 0x1234, 0); // no winner → rollover

        vault.applyRollover(2);
        vm.stopPrank();

        (uint256 allocated,,,,) = vault.drawings(2);
        assertEq(allocated, 1000e18);
        assertEq(vault.rolledOverBalance(), 0);
    }

    // ──── Claim ────

    function test_claimPrize_splitsEvenly() public {
        vm.startPrank(coordinator);
        vault.deposit(1, 900e18);
        vault.resolveDrawing(1, 0x1234, 3); // 3 winners

        vault.claimPrize(1, alice);
        vault.claimPrize(1, bob);
        vault.claimPrize(1, address(0xCA201));
        vm.stopPrank();

        // Each gets 900/3 = 300
        assertEq(alUSD.balanceOf(alice), 300e18);
        assertEq(alUSD.balanceOf(bob), 300e18);
        assertEq(alUSD.balanceOf(address(0xCA201)), 300e18);
    }

    function test_claimPrize_dustStaysInVault() public {
        vm.startPrank(coordinator);
        vault.deposit(1, 100e18 + 1); // 3 winners, 100...001 / 3 truncates → dust of 2 wei
        vault.resolveDrawing(1, 0x1234, 3);

        vault.claimPrize(1, alice);
        vault.claimPrize(1, bob);
        vault.claimPrize(1, address(0xCA201));
        vm.stopPrank();

        // Dust stays in vault (can't distribute evenly)
        uint256 total = 100e18 + 1;
        uint256 perWinner = total / 3;
        uint256 dust = total - (perWinner * 3);
        assertEq(alUSD.balanceOf(address(vault)), dust);
        assertTrue(dust < 3); // Dust bounded by winnerCount - 1
    }

    function test_claimPrize_doubleClaim_reverts() public {
        vm.startPrank(coordinator);
        vault.deposit(1, 1000e18);
        vault.resolveDrawing(1, 0x1234, 1);
        vault.claimPrize(1, alice);

        vm.expectRevert(Errors.TicketAlreadyClaimed.selector);
        vault.claimPrize(1, alice);
        vm.stopPrank();
    }

    function test_claimPrize_notResolved_reverts() public {
        vm.startPrank(coordinator);
        vault.deposit(1, 1000e18);

        vm.expectRevert(Errors.DrawingNotResolved.selector);
        vault.claimPrize(1, alice);
        vm.stopPrank();
    }

    function test_claimPrize_noWinner_reverts() public {
        vm.startPrank(coordinator);
        vault.deposit(1, 1000e18);
        vault.resolveDrawing(1, 0x1234, 0);

        vm.expectRevert(Errors.DrawingHasNoWinner.selector);
        vault.claimPrize(1, alice);
        vm.stopPrank();
    }
}
