// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Errors} from "./libraries/Errors.sol";
import {Events} from "./libraries/Events.sol";

/// @title LuckStaking — MasterChef-style single-asset staking for LUCK → alUSD
/// @notice Stake LUCK tokens to earn a share of alUSD rewards distributed each drawing.
/// @dev Classic MasterChef accumulator pattern. Rewards added by coordinator via addRewards().
///      When totalStaked == 0, rewards are orphaned (tracked but not distributed).
contract LuckStaking is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ──── State ────
    IERC20 public immutable luckToken;
    IERC20 public immutable rewardToken; // alUSD
    address public coordinator;

    uint256 public totalStaked;
    uint256 public accRewardPerShare;
    uint256 public orphanedRewards;

    uint256 private constant PRECISION = 1e18;

    struct UserInfo {
        uint256 stakedAmount;
        uint256 rewardDebt;
    }

    mapping(address => UserInfo) public userInfo;

    // ──── Constructor ────

    /// @param _luckToken LUCK token address
    /// @param _rewardToken alUSD token address
    /// @param _coordinator LuckyPotion coordinator address
    constructor(address _luckToken, address _rewardToken, address _coordinator) {
        if (_luckToken == address(0) || _rewardToken == address(0) || _coordinator == address(0)) {
            revert Errors.ZeroAddress();
        }
        luckToken = IERC20(_luckToken);
        rewardToken = IERC20(_rewardToken);
        coordinator = _coordinator;
    }

    // ──── Modifiers ────

    modifier onlyCoordinator() {
        if (msg.sender != coordinator) revert Errors.OnlyCoordinator();
        _;
    }

    // ──── Core Functions ────

    /// @notice Add alUSD rewards to the pool. Called by coordinator after each drawing.
    /// @param amount alUSD amount to distribute (18 decimals)
    function addRewards(uint256 amount) external onlyCoordinator {
        if (amount == 0) revert Errors.ZeroAmount();

        if (totalStaked == 0) {
            orphanedRewards += amount;
        } else {
            accRewardPerShare += (amount * PRECISION) / totalStaked;
        }

        // Transfer alUSD from coordinator
        rewardToken.safeTransferFrom(msg.sender, address(this), amount);

        emit Events.RewardsAdded(amount, accRewardPerShare);
    }

    /// @notice Stake LUCK tokens. Auto-claims any pending rewards.
    /// @param amount LUCK amount to stake
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
        totalStaked += amount;

        emit Events.Staked(msg.sender, amount);
    }

    /// @notice Unstake LUCK tokens. Auto-claims any pending rewards.
    /// @param amount LUCK amount to unstake
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
        rewardToken.safeTransfer(msg.sender, pending);

        emit Events.RewardsClaimed(msg.sender, pending);
    }

    // ──── View Functions ────

    /// @notice Get pending alUSD rewards for a user
    /// @param account User address
    /// @return pending Claimable alUSD amount
    function pendingRewards(address account) external view returns (uint256 pending) {
        return _pendingRewards(userInfo[account]);
    }

    // ──── Internal ────

    function _pendingRewards(UserInfo storage user) internal view returns (uint256) {
        return (user.stakedAmount * accRewardPerShare) / PRECISION - user.rewardDebt;
    }
}
