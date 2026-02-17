// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Errors — Protocol-wide custom errors
/// @notice All Magic Potion revert reasons in one place
library Errors {
    // ──── Ticket Purchase ────
    error NotInitialized();
    error ProtocolPaused();
    error DrawingNotOpen();
    error TicketSalesClosed();
    error InvalidCanvasData();
    error InsufficientUSDCAllowance();
    error BatchTooLarge();

    // ──── Drawing ────
    error DrawingNotReady();
    error DrawingAlreadyTriggered();
    error VRFRequestFailed();
    error DrawingNotResolved();
    error InvalidDrawingState();

    // ──── Claims ────
    error NotTicketOwner();
    error TicketAlreadyClaimed();
    error TicketNotWinner();
    error DrawingHasNoWinner();

    // ──── Burns ────
    error TicketAlreadyBurned();
    error CannotBurnWinningTicket();
    error CannotBurnActiveTicket();

    // ──── Staking ────
    error ZeroAmount();
    error InsufficientStake();
    error NoPendingRewards();

    // ──── Access Control ────
    error OnlyCoordinator();
    error OnlyMinter();

    // ──── Admin ────
    error AlreadyInitialized();
    error ZeroAddress();
    error CannotRescueProtocolToken();

    // ──── VRF ────
    error VRFTimeoutNotReached();
    error InvalidVRFRequest();
}
