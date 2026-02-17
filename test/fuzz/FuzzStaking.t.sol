// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {LuckToken} from "../../src/LuckToken.sol";
import {LuckStaking} from "../../src/LuckStaking.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @title FuzzStaking — Property-based fuzz tests for LuckStaking
contract FuzzStakingTest is Test {
    LuckToken public luckToken;
    LuckStaking public staking;
    MockERC20 public alUSD;

    address public coordinator = address(this);
    address public alice = makeAddr("alice");

    function setUp() public {
        alUSD = new MockERC20("alUSD", "alUSD", 18);
        luckToken = new LuckToken(coordinator);
        staking = new LuckStaking(address(luckToken), address(alUSD), coordinator);
    }

    /// @notice After stake + unstake of same amount, user should have original balance
    function testFuzz_staking_noFundsLocked(uint256 stakeAmount, uint256 rewardAmount) public {
        stakeAmount = bound(stakeAmount, 1, 1_000_000e18);
        rewardAmount = bound(rewardAmount, 0, 1_000_000e18);

        // Give alice LUCK and stake
        luckToken.mint(alice, stakeAmount);
        vm.startPrank(alice);
        luckToken.approve(address(staking), stakeAmount);
        staking.stake(stakeAmount);
        vm.stopPrank();

        // Add rewards
        if (rewardAmount > 0) {
            alUSD.mint(address(this), rewardAmount);
            alUSD.approve(address(staking), rewardAmount);
            staking.addRewards(rewardAmount);
        }

        // Unstake everything
        vm.prank(alice);
        staking.unstake(stakeAmount);

        // Alice should have all her LUCK back
        assertEq(luckToken.balanceOf(alice), stakeAmount, "LUCK should be fully returned");
        assertEq(staking.totalStaked(), 0, "total staked should be 0");
    }

    /// @notice Reward debt should accurately track owed rewards
    function testFuzz_staking_rewardDebtAccurate(uint256 stakeAmount, uint256 rewardAmount) public {
        stakeAmount = bound(stakeAmount, 1e18, 1_000_000e18); // min 1 LUCK to avoid dust
        rewardAmount = bound(rewardAmount, 1e18, 1_000_000e18);

        // Stake
        luckToken.mint(alice, stakeAmount);
        vm.startPrank(alice);
        luckToken.approve(address(staking), stakeAmount);
        staking.stake(stakeAmount);
        vm.stopPrank();

        // Add rewards
        alUSD.mint(address(this), rewardAmount);
        alUSD.approve(address(staking), rewardAmount);
        staking.addRewards(rewardAmount);

        // Pending should equal reward (sole staker)
        uint256 pending = staking.pendingRewards(alice);
        // MasterChef accRewardPerShare has precision loss from division by totalStaked
        // Tolerance scales with reward/stake ratio magnitude
        uint256 tolerance = (rewardAmount / stakeAmount) + 1e6;
        assertApproxEqAbs(pending, rewardAmount, tolerance, "pending should match reward for sole staker");

        // Claim and verify
        vm.prank(alice);
        staking.claimRewards();
        assertApproxEqAbs(alUSD.balanceOf(alice), rewardAmount, tolerance, "alice should have received rewards");
    }

    /// @notice Multiple stakers should split rewards proportionally
    function testFuzz_staking_proportionalRewards(uint256 aliceStake, uint256 bobStake, uint256 reward) public {
        aliceStake = bound(aliceStake, 1e18, 1_000_000e18);
        bobStake = bound(bobStake, 1e18, 1_000_000e18);
        reward = bound(reward, 1e18, 1_000_000e18);

        address bob = makeAddr("bob");

        // Stake
        luckToken.mint(alice, aliceStake);
        luckToken.mint(bob, bobStake);

        vm.startPrank(alice);
        luckToken.approve(address(staking), aliceStake);
        staking.stake(aliceStake);
        vm.stopPrank();

        vm.startPrank(bob);
        luckToken.approve(address(staking), bobStake);
        staking.stake(bobStake);
        vm.stopPrank();

        // Add rewards
        alUSD.mint(address(this), reward);
        alUSD.approve(address(staking), reward);
        staking.addRewards(reward);

        // Check proportional distribution
        uint256 alicePending = staking.pendingRewards(alice);
        uint256 bobPending = staking.pendingRewards(bob);

        uint256 totalStaked = aliceStake + bobStake;
        uint256 expectedAlice = (reward * aliceStake) / totalStaked;
        uint256 expectedBob = (reward * bobStake) / totalStaked;

        // MasterChef precision loss scales with reward magnitude and stake ratio
        uint256 tolerance = (reward / totalStaked) + 1e6;
        assertApproxEqAbs(alicePending, expectedAlice, tolerance, "alice reward share");
        assertApproxEqAbs(bobPending, expectedBob, tolerance, "bob reward share");
    }
}
