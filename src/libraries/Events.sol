// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Events — Protocol-wide event definitions
/// @notice All Magic Potion events in one place
library Events {
    // ──── Ticket Events ────
    event TicketPurchased(
        address indexed buyer,
        uint256 indexed ticketId,
        uint256 indexed drawingId,
        uint16 canvasHash
    );

    event BatchTicketsPurchased(
        address indexed buyer,
        uint256[] ticketIds,
        uint256 indexed drawingId
    );

    event TicketBurned(
        address indexed burner,
        uint256 indexed ticketId,
        uint256 indexed drawingId,
        uint256 luckReward
    );

    // ──── Drawing Events ────
    event DrawingStarted(uint256 indexed drawingId, uint256 openTime);

    event TicketRegistered(
        uint256 indexed drawingId,
        uint256 indexed ticketId,
        uint16 canvasHash
    );

    event TicketSalesClosed(uint256 indexed drawingId, uint256 totalTickets);

    event DrawingTriggered(uint256 indexed drawingId, uint256 vrfRequestId);

    event DrawingResolved(
        uint256 indexed drawingId,
        uint16 winningHash,
        uint256 winnerCount
    );

    event DrawingFinalized(
        uint256 indexed drawingId,
        uint16 winningHash,
        bool hasWinner,
        uint256 winnerCount
    );

    event VRFRetry(uint256 indexed drawingId);

    // ──── Prize Events ────
    event PrizeClaimed(
        address indexed winner,
        uint256 indexed ticketId,
        uint256 indexed drawingId,
        uint256 amount
    );

    event PrizeDeposited(uint256 indexed drawingId, uint256 amount);

    event PrizeRolledOver(uint256 indexed drawingId, uint256 amount);

    event RolloverApplied(uint256 indexed newDrawingId, uint256 amount);

    event PrizeResolved(
        uint256 indexed drawingId,
        uint16 winningHash,
        uint256 winnerCount,
        uint256 totalPrize
    );

    // ──── Staking Events ────
    event Staked(address indexed user, uint256 amount);
    event Unstaked(address indexed user, uint256 amount);
    event RewardsClaimed(address indexed user, uint256 amount);
    event RewardsAdded(uint256 amount, uint256 newAccRewardPerShare);

    // ──── Distribution Events ────
    event AlUSDDistributed(
        uint256 indexed drawingId,
        uint256 totalMinted,
        uint256 ops,
        uint256 staking,
        uint256 prize
    );

    // ──── Admin Events ────
    event Initialized(uint256 firstDrawingId);
    event PauseToggled(bool paused);
    event OpsMultisigUpdated(address newOps);
    event MinterUpdated(address newMinter);

    // ──── NFT Events ────
    event TicketMinted(
        uint256 indexed tokenId,
        address indexed to,
        uint256 indexed drawingId,
        uint16 canvasHash
    );
}
