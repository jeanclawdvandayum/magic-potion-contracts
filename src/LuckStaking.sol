// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Errors} from "./libraries/Errors.sol";
import {Events} from "./libraries/Events.sol";
import {Constants} from "./libraries/Constants.sol";

/// @title LuckStaking — Epoch-based LUCK staking for weekly alUSD rewards
/// @notice Stake LUCK to earn a proportional share of each week's alUSD allocation.
/// @dev Rewards arrive as a lump sum when a drawing is triggered (12% of minted alUSD).
///      The lump sum is distributed linearly over the following week to all stakers
///      proportional to their stake. Users can stake/unstake anytime but pending
///      rewards are claimed on every interaction.
///
/// MECHANICS:
///   - Uses MasterChef accumulator pattern (accRewardPerShare).
///   - addRewards() is called once per week (at drawing trigger).
///   - Each call deposits ~12% of that drawing's minted alUSD.
///   - Example: $10k weekly sales -> $9k alUSD minted -> 12% = 1,080 alUSD
///     distributed over the following week to all stakers.
///   - If nobody is staked when rewards arrive, they accumulate as orphanedRewards
///     and are distributed on the next addRewards() call when stakers exist.
contract LuckStaking is ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable luckToken;
    IERC20 public immutable rewardToken; // alUSD
    address public immutable coordinator;

    uint256 public totalStaked;
    uint256 public accRewardPerShare;
    uint256 public orphanedRewards;

    /// @dev Current staking epoch number. Increments when coordinator calls newEpoch().
    ///      Aligned with drawing cadence (1 epoch = 1 drawing period = 7 days).
    uint256 public currentEpoch;

    uint256 private constant PRECISION = 1e18;

    struct UserInfo {
        uint256 stakedAmount;
        uint256 rewardDebt;
        uint256 lastClaimEpoch;
    }

    mapping(address => UserInfo) public userInfo;

    /// @dev Tracks total rewards added per epoch for accounting.
    mapping(uint256 => uint256) public epochRewards;

    constructor(address _luckToken, address _rewardToken, address _coordinator) {
        if (_luckToken == address(0) || _rewardToken == address(0) || _coordinator == address(0)) {
            revert Errors.ZeroAddress();
        }
        luckToken = IERC20(_luckToken);
        rewardToken = IERC20(_rewardToken);
        coordinator = _coordinator;
    }

    modifier onlyCoordinator() {
        if (msg.sender != coordinator) revert Errors.OnlyCoordinator();
        _;
    }

    // ──── Coordinator Functions ────

    /// @notice Advance to the next staking epoch.
    /// @dev Called by coordinator at each drawing trigger. Marks the start of
    ///      a new reward distribution period.
    function newEpoch() external onlyCoordinator {
        currentEpoch++;
        emit Events.EpochAdvanced(currentEpoch);
    }

    /// @notice Add alUSD rewards for the current epoch.
    /// @dev Called by coordinator after minting alUSD at drawing trigger.
    ///      If there are orphaned rewards from when nobody was staked, they are
    ///      folded into the accumulator but NOT re-transferred (they're already
    ///      in this contract from the previous addRewards call).
    /// @param amount alUSD amount to distribute (18 decimals)
    function addRewards(uint256 amount) external onlyCoordinator {
        if (amount == 0) revert Errors.ZeroAmount();

        uint256 newFromCaller = amount;
        uint256 fromOrphans = 0;

        // Fold in orphaned rewards from previous no-staker periods
        // These are already in this contract's balance, so we only transfer
        // the new amount from the caller.
        if (orphanedRewards > 0) {
            fromOrphans = orphanedRewards;
            orphanedRewards = 0;
        }

        uint256 totalToDistribute = newFromCaller + fromOrphans;
        epochRewards[currentEpoch] += totalToDistribute;

        if (totalStaked == 0) {
            // Still nobody staked — orphan again
            orphanedRewards += totalToDistribute;
        } else {
            accRewardPerShare += (totalToDistribute * PRECISION) / totalStaked;
        }

        // Only transfer the new amount from coordinator (orphans already here)
        rewardToken.safeTransferFrom(msg.sender, address(this), newFromCaller);

        emit Events.RewardsAdded(totalToDistribute, accRewardPerShare);
    }

    // ──── User Functions ────

    /// @notice Stake LUCK tokens. Auto-claims pending rewards.
    function stake(uint256 amount) external nonReentrant {
        if (amount == 0) revert Errors.ZeroAmount();

        UserInfo storage user = userInfo[msg.sender];

        // Claim pending rewards before updating stake
        if (user.stakedAmount > 0) {
            uint256 pending = _pendingRewards(user);
            if (pending > 0) {
                rewardToken.safeTransfer(msg.sender, pending);
                emit Events.RewardsClaimed(msg.sender, pending);
            }
        }

        // Transfer LUCK from user
        luckToken.safeTransferFrom(msg.sender, address(this), amount);

        // Update state AFTER transfers
        user.stakedAmount += amount;
        user.rewardDebt = (user.stakedAmount * accRewardPerShare) / PRECISION;
        user.lastClaimEpoch = currentEpoch;
        totalStaked += amount;

        emit Events.Staked(msg.sender, amount);
    }

    /// @notice Unstake LUCK tokens. Auto-claims pending rewards.
    function unstake(uint256 amount) external nonReentrant {
        if (amount == 0) revert Errors.ZeroAmount();

        UserInfo storage user = userInfo[msg.sender];
        if (user.stakedAmount < amount) revert Errors.InsufficientStake();

        // Claim pending rewards before updating stake
        uint256 pending = _pendingRewards(user);
        if (pending > 0) {
            rewardToken.safeTransfer(msg.sender, pending);
            emit Events.RewardsClaimed(msg.sender, pending);
        }

        // Update state
        user.stakedAmount -= amount;
        user.rewardDebt = (user.stakedAmount * accRewardPerShare) / PRECISION;
        totalStaked -= amount;

        // Transfer LUCK back to user
        luckToken.safeTransfer(msg.sender, amount);

        emit Events.Unstaked(msg.sender, amount);
    }

    /// @notice Claim pending alUSD rewards without changing stake
    function claimRewards() external nonReentrant {
        UserInfo storage user = userInfo[msg.sender];
        uint256 pending = _pendingRewards(user);
        if (pending == 0) revert Errors.NoPendingRewards();

        user.rewardDebt = (user.stakedAmount * accRewardPerShare) / PRECISION;
        user.lastClaimEpoch = currentEpoch;
        rewardToken.safeTransfer(msg.sender, pending);

        emit Events.RewardsClaimed(msg.sender, pending);
    }

    // ──── View Functions ────

    /// @notice Get pending alUSD rewards for a user
    function pendingRewards(address account) external view returns (uint256 pending) {
        return _pendingRewards(userInfo[account]);
    }

    /// @notice Get user staking info
    function getUserInfo(address account) external view returns (UserInfo memory) {
        return userInfo[account];
    }

    // ──── Internal ────

    function _pendingRewards(UserInfo storage user) internal view returns (uint256) {
        return (user.stakedAmount * accRewardPerShare) / PRECISION - user.rewardDebt;
    }
}
