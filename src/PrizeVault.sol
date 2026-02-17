// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Errors} from "./libraries/Errors.sol";
import {Events} from "./libraries/Events.sol";

/// @title PrizeVault — Holds and distributes alUSD prizes per drawing
/// @notice Manages per-drawing prize allocations, winner resolution, and prize claims.
///         Unclaimed prizes from no-winner drawings roll over to the next drawing.
contract PrizeVault is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ──── State ────
    IERC20 public immutable rewardToken; // alUSD
    address public coordinator;

    struct DrawingPrize {
        uint256 allocated;
        uint256 claimed;
        uint256 winnerCount;
        bool resolved;
        uint16 winningHash;
    }

    mapping(uint256 => DrawingPrize) public drawings;
    mapping(uint256 => mapping(address => bool)) public hasClaimed;

    uint256 public rolledOverBalance;

    // ──── Constructor ────

    /// @param _rewardToken alUSD token address
    /// @param _coordinator LuckyPotion coordinator address
    constructor(address _rewardToken, address _coordinator) {
        if (_rewardToken == address(0) || _coordinator == address(0)) {
            revert Errors.ZeroAddress();
        }
        rewardToken = IERC20(_rewardToken);
        coordinator = _coordinator;
    }

    // ──── Modifiers ────

    modifier onlyCoordinator() {
        if (msg.sender != coordinator) revert Errors.OnlyCoordinator();
        _;
    }

    // ──── Core Functions ────

    /// @notice Deposit alUSD into a drawing's prize pool
    /// @param drawingId The drawing to fund
    /// @param amount alUSD amount
    function deposit(uint256 drawingId, uint256 amount) external onlyCoordinator {
        if (amount == 0) revert Errors.ZeroAmount();
        drawings[drawingId].allocated += amount;
        rewardToken.safeTransferFrom(msg.sender, address(this), amount);
        emit Events.PrizeDeposited(drawingId, amount);
    }

    /// @notice Resolve a drawing with its winning hash and winner count
    /// @param drawingId The drawing to resolve
    /// @param winningHash The VRF-derived winning hash
    /// @param winnerCount Number of tickets matching the winning hash
    function resolveDrawing(uint256 drawingId, uint16 winningHash, uint256 winnerCount) external onlyCoordinator {
        DrawingPrize storage prize = drawings[drawingId];
        if (prize.resolved) revert Errors.DrawingAlreadyTriggered();

        prize.resolved = true;
        prize.winningHash = winningHash;
        prize.winnerCount = winnerCount;

        if (winnerCount == 0) {
            // No winner — roll over the entire allocation
            rolledOverBalance += prize.allocated;
            emit Events.PrizeRolledOver(drawingId, prize.allocated);
        }

        emit Events.PrizeResolved(drawingId, winningHash, winnerCount, prize.allocated);
    }

    /// @notice Apply rollover balance to a new drawing
    /// @param newDrawingId The drawing to receive the rollover
    function applyRollover(uint256 newDrawingId) external onlyCoordinator {
        uint256 rollover = rolledOverBalance;
        if (rollover == 0) return;

        rolledOverBalance = 0;
        drawings[newDrawingId].allocated += rollover;

        emit Events.RolloverApplied(newDrawingId, rollover);
    }

    /// @notice Claim prize for a winning ticket
    /// @param drawingId The drawing ID
    /// @param winner The winner's address
    function claimPrize(uint256 drawingId, address winner) external onlyCoordinator nonReentrant {
        DrawingPrize storage prize = drawings[drawingId];
        if (!prize.resolved) revert Errors.DrawingNotResolved();
        if (prize.winnerCount == 0) revert Errors.DrawingHasNoWinner();
        if (hasClaimed[drawingId][winner]) revert Errors.TicketAlreadyClaimed();

        uint256 perWinner = prize.allocated / prize.winnerCount;

        hasClaimed[drawingId][winner] = true;
        prize.claimed += perWinner;

        rewardToken.safeTransfer(winner, perWinner);

        emit Events.PrizeClaimed(winner, 0, drawingId, perWinner); // ticketId filled by coordinator
    }

    // ──── View Functions ────

    /// @notice Get prize info for a drawing
    function getPrizeInfo(uint256 drawingId) external view returns (DrawingPrize memory) {
        return drawings[drawingId];
    }

    /// @notice Get per-winner prize amount
    function getPerWinnerAmount(uint256 drawingId) external view returns (uint256) {
        DrawingPrize storage prize = drawings[drawingId];
        if (prize.winnerCount == 0) return 0;
        return prize.allocated / prize.winnerCount;
    }
}
