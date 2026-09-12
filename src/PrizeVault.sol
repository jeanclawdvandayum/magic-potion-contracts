// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Errors} from "./libraries/Errors.sol";
import {Events} from "./libraries/Events.sol";

/// @title PrizeVault — Holds and distributes alUSD prizes per drawing
/// @notice Manages per-drawing prize allocations, winner resolution, and prize claims.
///         Claims are tracked per-ticketId so a holder with multiple winning tickets
///         can claim each one independently.
///         Unclaimed prizes from no-winner drawings roll over to the next drawing.
contract PrizeVault is ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable rewardToken; // alUSD
    address public immutable coordinator;

    struct DrawingPrize {
        uint256 allocated;
        uint256 claimed;
        uint256 winnerCount;
        bool resolved;
        uint16 winningHash;
        uint64 resolvedTime; // FIX EX-06: anchors the claim deadline
    }

    /// @dev FIX EX-06: winning tickets have this long to claim before anyone
    ///      can sweep the remainder into the rollover for future drawings.
    uint256 public constant CLAIM_DEADLINE = 30 days;

    mapping(uint256 => DrawingPrize) public drawings;

    /// @dev Tracks claims per-ticketId. Each winning ticket claims independently.
    mapping(uint256 => bool) public ticketClaimed;

    uint256 public rolledOverBalance;

    constructor(address _rewardToken, address _coordinator) {
        if (_rewardToken == address(0) || _coordinator == address(0)) {
            revert Errors.ZeroAddress();
        }
        rewardToken = IERC20(_rewardToken);
        coordinator = _coordinator;
    }

    modifier onlyCoordinator() {
        if (msg.sender != coordinator) revert Errors.OnlyCoordinator();
        _;
    }

    /// @notice Deposit alUSD into a drawing's prize pool
    function deposit(uint256 drawingId, uint256 amount) external onlyCoordinator {
        if (amount == 0) revert Errors.ZeroAmount();
        drawings[drawingId].allocated += amount;
        rewardToken.safeTransferFrom(msg.sender, address(this), amount);
        emit Events.PrizeDeposited(drawingId, amount);
    }

    /// @notice Resolve a drawing with its winning hash and winner count
    function resolveDrawing(uint256 drawingId, uint16 winningHash, uint256 winnerCount) external onlyCoordinator {
        DrawingPrize storage prize = drawings[drawingId];
        if (prize.resolved) revert Errors.DrawingAlreadyTriggered();

        prize.resolved = true;
        prize.winningHash = winningHash;
        prize.winnerCount = winnerCount;
        prize.resolvedTime = uint64(block.timestamp);

        if (winnerCount == 0) {
            rolledOverBalance += prize.allocated;
            emit Events.PrizeRolledOver(drawingId, prize.allocated);
        }

        emit Events.PrizeResolved(drawingId, winningHash, winnerCount, prize.allocated);
    }

    /// @notice Sweep unclaimed prize remainder into the rollover pool.
    /// @dev FIX EX-06: permissionless after CLAIM_DEADLINE. Without this,
    ///      unclaimed winning prizes were stranded in the vault forever.
    function sweepUnclaimed(uint256 drawingId) external nonReentrant {
        DrawingPrize storage prize = drawings[drawingId];
        if (!prize.resolved) revert Errors.DrawingNotResolved();
        if (block.timestamp < prize.resolvedTime + CLAIM_DEADLINE) {
            revert Errors.ClaimWindowStillOpen();
        }

        uint256 remaining = prize.allocated - prize.claimed;
        if (remaining == 0) return;

        // Close the claim window atomically with the sweep.
        prize.claimed = prize.allocated;
        rolledOverBalance += remaining;

        emit Events.PrizeSwept(drawingId, remaining);
    }

    /// @notice Apply rollover balance to a new drawing
    function applyRollover(uint256 newDrawingId) external onlyCoordinator {
        uint256 rollover = rolledOverBalance;
        if (rollover == 0) return;

        rolledOverBalance = 0;
        drawings[newDrawingId].allocated += rollover;

        emit Events.RolloverApplied(newDrawingId, rollover);
    }

    /// @notice Claim prize for a specific winning ticket.
    /// @dev Tracked per-ticketId. A holder with 3 winning tickets calls this 3 times.
    /// @param drawingId The drawing ID
    /// @param ticketId The specific winning ticket
    /// @param winner The ticket holder (verified by coordinator)
    function claimPrize(uint256 drawingId, uint256 ticketId, address winner) external onlyCoordinator nonReentrant {
        DrawingPrize storage prize = drawings[drawingId];
        if (!prize.resolved) revert Errors.DrawingNotResolved();
        if (prize.winnerCount == 0) revert Errors.DrawingHasNoWinner();
        if (ticketClaimed[ticketId]) revert Errors.TicketAlreadyClaimed();
        if (prize.claimed >= prize.allocated) revert Errors.ClaimWindowClosed();

        uint256 perWinner = prize.allocated / prize.winnerCount;

        ticketClaimed[ticketId] = true;
        prize.claimed += perWinner;

        rewardToken.safeTransfer(winner, perWinner);

        emit Events.PrizeClaimed(winner, ticketId, drawingId, perWinner);
    }

    function getPrizeInfo(uint256 drawingId) external view returns (DrawingPrize memory) {
        return drawings[drawingId];
    }

    function getPerWinnerAmount(uint256 drawingId) external view returns (uint256) {
        DrawingPrize storage prize = drawings[drawingId];
        if (prize.winnerCount == 0) return 0;
        return prize.allocated / prize.winnerCount;
    }

    /// @notice Check if a specific ticket has been claimed
    function isTicketClaimed(uint256 ticketId) external view returns (bool) {
        return ticketClaimed[ticketId];
    }
}
