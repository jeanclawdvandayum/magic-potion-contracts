// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Constants — Protocol-wide immutable values
/// @notice All Magic Potion protocol constants in one place
library Constants {
    // ──── Ticket Economics ────
    /// @notice Price of one lottery ticket in USDC (6 decimals)
    uint256 internal constant TICKET_PRICE = 5_000_000; // $5 USDC

    /// @notice LUCK tokens minted per ticket purchase (18 decimals)
    uint256 internal constant LUCK_PER_TICKET = 1e18; // 1 LUCK

    /// @notice LUCK tokens awarded for burning a losing ticket (18 decimals)
    uint256 internal constant BURN_LUCK_REWARD = 0.1e18; // 0.1 LUCK

    // ──── Drawing Timing ────
    /// @notice Duration of each drawing period
    uint256 internal constant DRAWING_DURATION = 14 days;

    /// @notice Ticket sales close this long before drawing
    uint256 internal constant TICKET_CUTOFF = 2 hours;

    /// @notice Timeout before VRF can be retried
    uint256 internal constant VRF_TIMEOUT = 24 hours;

    // ──── Lottery Odds ────
    /// @notice Number of possible hash outcomes (2^16)
    uint256 internal constant HASH_SPACE = 65_536;

    // ──── Revenue Distribution (basis points, total = 10000) ────
    /// @notice Operations allocation (2%)
    uint256 internal constant OPS_BPS = 200;

    /// @notice LUCK staker allocation (15%)
    uint256 internal constant STAKING_BPS = 1500;

    /// @notice Prize vault allocation (83%)
    uint256 internal constant PRIZE_BPS = 8300;

    /// @notice Basis points denominator
    uint256 internal constant BPS_DENOMINATOR = 10_000;

    // ──── Canvas ────
    /// @notice Exact byte length of canvas data (64×64 pixels × 2 bits/pixel ÷ 8 bits/byte)
    uint256 internal constant CANVAS_DATA_LENGTH = 1024;

    // ──── Batch Limits ────
    /// @notice Maximum tickets purchasable in a single transaction
    uint256 internal constant MAX_BATCH_SIZE = 100;
}
