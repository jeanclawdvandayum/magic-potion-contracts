// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {LuckToken} from "../../src/LuckToken.sol";
import {LuckStaking} from "../../src/LuckStaking.sol";
import {Errors} from "../../src/libraries/Errors.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Simple mock alUSD for testing
contract MockAlUSD is ERC20 {
    constructor() ERC20("Alchemix USD", "alUSD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract LuckStakingTest is Test {
    LuckToken luck;
    MockAlUSD alUSD;
    LuckStaking staking;

    address coordinator = address(0xC00D);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address carol = address(0xCA201);

    function setUp() public {
        luck = new LuckToken(address(this));
        alUSD = new MockAlUSD();
        staking = new LuckStaking(address(luck), address(alUSD), coordinator);

        // Give users some LUCK
        luck.mint(alice, 100e18);
        luck.mint(bob, 100e18);
        luck.mint(carol, 100e18);

        // Users approve staking contract
        vm.prank(alice);
        luck.approve(address(staking), type(uint256).max);
        vm.prank(bob);
        luck.approve(address(staking), type(uint256).max);
        vm.prank(carol);
        luck.approve(address(staking), type(uint256).max);

        // Give coordinator alUSD for rewards and approve staking
        alUSD.mint(coordinator, 10000e18);
        vm.prank(coordinator);
        alUSD.approve(address(staking), type(uint256).max);
    }

    // ──── Constructor ────

    function test_constructorZeroAddress_reverts() public {
        vm.expectRevert(Errors.ZeroAddress.selector);
        new LuckStaking(address(0), address(alUSD), coordinator);

        vm.expectRevert(Errors.ZeroAddress.selector);
        new LuckStaking(address(luck), address(0), coordinator);

        vm.expectRevert(Errors.ZeroAddress.selector);
        new LuckStaking(address(luck), address(alUSD), address(0));
    }

    // ──── Staking ────

    function test_stake_transfersLUCK() public {
        uint256 balBefore = luck.balanceOf(alice);

        vm.prank(alice);
        staking.stake(10e18);

        assertEq(luck.balanceOf(alice), balBefore - 10e18);
        assertEq(luck.balanceOf(address(staking)), 10e18);
    }

    function test_stake_updatesUserInfo() public {
        vm.prank(alice);
        staking.stake(10e18);

        (uint256 stakedAmount, ) = staking.userInfo(alice);
        assertEq(stakedAmount, 10e18);
        assertEq(staking.totalStaked(), 10e18);
    }

    function test_stake_zeroAmount_reverts() public {
        vm.prank(alice);
        vm.expectRevert(Errors.ZeroAmount.selector);
        staking.stake(0);
    }

    // ──── Unstaking ────

    function test_unstake_returnsLUCK() public {
        vm.prank(alice);
        staking.stake(10e18);

        uint256 balBefore = luck.balanceOf(alice);

        vm.prank(alice);
        staking.unstake(5e18);

        assertEq(luck.balanceOf(alice), balBefore + 5e18);
    }

    function test_unstake_autoClaimsPending() public {
        vm.prank(alice);
        staking.stake(10e18);

        // Add 100 alUSD rewards
        vm.prank(coordinator);
        staking.addRewards(100e18);

        uint256 alUSD_before = alUSD.balanceOf(alice);

        vm.prank(alice);
        staking.unstake(5e18);

        // Alice should have received 100 alUSD (she's the only staker)
        assertEq(alUSD.balanceOf(alice), alUSD_before + 100e18);
    }

    function test_unstake_insufficientStake_reverts() public {
        vm.prank(alice);
        staking.stake(10e18);

        vm.prank(alice);
        vm.expectRevert(Errors.InsufficientStake.selector);
        staking.unstake(11e18);
    }

    function test_unstake_zeroAmount_reverts() public {
        vm.prank(alice);
        staking.stake(10e18);

        vm.prank(alice);
        vm.expectRevert(Errors.ZeroAmount.selector);
        staking.unstake(0);
    }

    // ──── Rewards ────

    function test_addRewards_updatesAccPerShare() public {
        vm.prank(alice);
        staking.stake(10e18);

        vm.prank(coordinator);
        staking.addRewards(100e18);

        // accRewardPerShare = 100e18 * 1e18 / 10e18 = 10e18
        assertEq(staking.accRewardPerShare(), 10e18);
    }

    function test_addRewards_zeroAmount_reverts() public {
        vm.prank(coordinator);
        vm.expectRevert(Errors.ZeroAmount.selector);
        staking.addRewards(0);
    }

    function test_addRewards_nonCoordinator_reverts() public {
        vm.prank(alice);
        vm.expectRevert(Errors.OnlyCoordinator.selector);
        staking.addRewards(100e18);
    }

    function test_addRewards_zeroStakers_orphaned() public {
        // No stakers → rewards are orphaned
        vm.prank(coordinator);
        staking.addRewards(50e18);

        assertEq(staking.orphanedRewards(), 50e18);
        assertEq(staking.accRewardPerShare(), 0);
        // alUSD is in the contract but not distributable
        assertEq(alUSD.balanceOf(address(staking)), 50e18);
    }

    function test_claimRewards_transfersCorrectAmount() public {
        vm.prank(alice);
        staking.stake(10e18);

        vm.prank(coordinator);
        staking.addRewards(100e18);

        vm.prank(alice);
        staking.claimRewards();

        assertEq(alUSD.balanceOf(alice), 100e18);
    }

    function test_claimRewards_noPending_reverts() public {
        vm.prank(alice);
        staking.stake(10e18);

        // No rewards added
        vm.prank(alice);
        vm.expectRevert(Errors.NoPendingRewards.selector);
        staking.claimRewards();
    }

    // ──── Multi-staker ────

    function test_multipleStakers_fairDistribution() public {
        // Alice stakes 10, Bob stakes 30 (1:3 ratio)
        vm.prank(alice);
        staking.stake(10e18);
        vm.prank(bob);
        staking.stake(30e18);

        // Add 100 alUSD
        vm.prank(coordinator);
        staking.addRewards(100e18);

        // Alice: 10/40 * 100 = 25
        assertEq(staking.pendingRewards(alice), 25e18);
        // Bob: 30/40 * 100 = 75
        assertEq(staking.pendingRewards(bob), 75e18);
    }

    function test_stakeAfterRewards_noFreeRewards() public {
        // Alice stakes first
        vm.prank(alice);
        staking.stake(10e18);

        // Rewards added
        vm.prank(coordinator);
        staking.addRewards(100e18);

        // Bob stakes AFTER rewards — should get 0 pending
        vm.prank(bob);
        staking.stake(10e18);

        assertEq(staking.pendingRewards(bob), 0);
        assertEq(staking.pendingRewards(alice), 100e18);
    }

    function test_multipleRewardRounds() public {
        vm.prank(alice);
        staking.stake(10e18);
        vm.prank(bob);
        staking.stake(10e18);

        // Round 1: 100 alUSD → 50 each
        vm.prank(coordinator);
        staking.addRewards(100e18);

        // Alice claims
        vm.prank(alice);
        staking.claimRewards();
        assertEq(alUSD.balanceOf(alice), 50e18);

        // Round 2: another 100 alUSD → 50 each
        vm.prank(coordinator);
        staking.addRewards(100e18);

        // Alice has 50 pending (from round 2)
        assertEq(staking.pendingRewards(alice), 50e18);
        // Bob has 100 pending (50 from round 1 + 50 from round 2)
        assertEq(staking.pendingRewards(bob), 100e18);
    }

    function test_stakeUnstakeCycle() public {
        // Alice stakes
        vm.prank(alice);
        staking.stake(10e18);

        // Rewards
        vm.prank(coordinator);
        staking.addRewards(100e18);

        // Alice fully unstakes (claims 100)
        vm.prank(alice);
        staking.unstake(10e18);
        assertEq(alUSD.balanceOf(alice), 100e18);
        assertEq(staking.totalStaked(), 0);

        // Alice restakes
        vm.prank(alice);
        staking.stake(10e18);

        // She should have 0 pending (fresh start)
        assertEq(staking.pendingRewards(alice), 0);
    }

    // ──── View ────

    function test_pendingRewards_view() public {
        vm.prank(alice);
        staking.stake(10e18);

        vm.prank(coordinator);
        staking.addRewards(50e18);

        assertEq(staking.pendingRewards(alice), 50e18);
        // Non-staker
        assertEq(staking.pendingRewards(bob), 0);
    }
}
