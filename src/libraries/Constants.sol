// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title Constants — Protocol-wide immutable values
/// @notice All Magic Potion protocol constants in one place
library Constants {
    // ──── Ticket Economics ────
    /// @notice Price of one lottery ticket in USDC (6 decimals)
    uint256 internal constant TICKET_PRICE = 5_000_000; // $5 USDC

    /// @notice LUCK tokens minted per ticket purchase (18 decimals)
    uint256 internal constant LUCK_PER_TICKET = 1e18; // 1 LUCK

    /// @notice Additional LUCK tokens awarded for burning a losing ticket (18 decimals)
    /// @dev Burned tickets yield 0.1 LUCK on top of whatever the holder already got at purchase.
    uint256 internal constant BURN_LUCK_REWARD = 0.1e18; // 0.1 LUCK

    // ──── Drawing Timing ────
    /// @notice Duration of each drawing period (7 days = weekly)
    uint256 internal constant DRAWING_DURATION = 7 days;

    /// @notice Ticket sales close this long before drawing
    uint256 internal constant TICKET_CUTOFF = 1 hours;

    /// @notice Timeout before drand round can be retried
    uint256 internal constant DRAND_TIMEOUT = 10 minutes;

    /// @notice How far in the future to target a drand round (must be > 1 period)
    uint256 internal constant DRAND_DELAY = 30;

    // ──── Lottery Odds ────
    /// @notice Number of possible hash outcomes (2^16)
    uint256 internal constant HASH_SPACE = 65_536;

    // ──── Revenue Distribution (basis points, total = 10000) ────
    /// @notice Prize vault allocation (83%)
    uint256 internal constant PRIZE_BPS = 8300;

    /// @notice LUCK staker allocation (12%)
    /// @dev Distributed to LUCK stakers over the week following each drawing.
    uint256 internal constant STAKING_BPS = 1200;

    /// @notice Treasury allocation (5%)
    /// @dev Funds protocol operations, keeper faucet, and cron jobs.
    uint256 internal constant OPS_BPS = 500;

    /// @notice Basis points denominator
    uint256 internal constant BPS_DENOMINATOR = 10_000;

    // ──── LUCK Staking Epochs ────
    /// @notice Duration of a LUCK staking epoch (matches drawing cadence)
    uint256 internal constant EPOCH_DURATION = 7 days;

    // ──── Canvas ────
    /// @notice Exact byte length of canvas data (64x64 pixels x 2 bits/pixel / 8 bits/byte)
    uint256 internal constant CANVAS_DATA_LENGTH = 1024;

    // ──── Batch Limits ────
    /// @notice Maximum tickets purchasable in a single transaction
    uint256 internal constant MAX_BATCH_SIZE = 100;
}
