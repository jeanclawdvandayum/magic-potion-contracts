// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IDrandBeacon} from "./interfaces/IDrandBeacon.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Constants} from "./libraries/Constants.sol";
import {Errors} from "./libraries/Errors.sol";
import {Events} from "./libraries/Events.sol";

/// @title DrawingManager — Lottery drawing lifecycle + drand randomness
/// @notice Manages drawing state machine (OPEN -> CLOSED -> PENDING_RANDOMNESS -> RESOLVED),
///         ticket registration, hash tracking, and drand beacon resolution.
/// @dev Uses drand's evmnet beacon (BN254 curve). Anyone can submit the beacon
///      signature after the target round is produced - verification is on-chain.
contract DrawingManager is ReentrancyGuard {
    // ──── Enums ────
    enum DrawingState { OPEN, CLOSED, PENDING_RANDOMNESS, RESOLVED }

    // ──── Structs ────
    struct Drawing {
        DrawingState state;
        uint256 openTime;
        uint256 closeTime;
        uint256 drawTime;
        uint256 totalTickets;
        uint16 winningHash;
        uint256 winnerCount;
        uint256 targetRound;     // drand round committed to
        uint256 requestTime;     // when triggerDrawing was called
        uint256 resolvedTime;    // when randomness was delivered
    }

    // ──── State ────
    address public immutable coordinator;
    IDrandBeacon public immutable drandBeacon;
    uint256 public currentDrawingId;

    mapping(uint256 => Drawing) public drawings;
    mapping(uint256 => mapping(uint16 => uint256)) public hashTicketCount;
    mapping(uint256 => mapping(uint16 => uint256[])) public hashTicketIds;

    // ──── Constructor ────

    constructor(address _drandBeacon, address _coordinator) {
        if (_drandBeacon == address(0) || _coordinator == address(0)) {
            revert Errors.ZeroAddress();
        }
        drandBeacon = IDrandBeacon(_drandBeacon);
        coordinator = _coordinator;
    }

    // ──── Modifiers ────

    modifier onlyCoordinator() {
        if (msg.sender != coordinator) revert Errors.OnlyCoordinator();
        _;
    }

    // ──── Core Functions ────

    function startDrawing() external onlyCoordinator returns (uint256 drawingId) {
        drawingId = ++currentDrawingId;

        drawings[drawingId] = Drawing({
            state: DrawingState.OPEN,
            openTime: block.timestamp,
            closeTime: block.timestamp + Constants.DRAWING_DURATION - Constants.TICKET_CUTOFF,
            drawTime: block.timestamp + Constants.DRAWING_DURATION,
            totalTickets: 0,
            winningHash: 0,
            winnerCount: 0,
            targetRound: 0,
            requestTime: 0,
            resolvedTime: 0
        });

        emit Events.DrawingStarted(drawingId, block.timestamp);
    }

    function registerTicket(uint256 drawingId, uint256 ticketId, uint16 canvasHash) external onlyCoordinator {
        Drawing storage drawing = drawings[drawingId];
        if (drawing.state != DrawingState.OPEN) revert Errors.DrawingNotOpen();
        if (block.timestamp >= drawing.closeTime) revert Errors.TicketSalesClosed();

        hashTicketCount[drawingId][canvasHash]++;
        hashTicketIds[drawingId][canvasHash].push(ticketId);
        drawing.totalTickets++;

        emit Events.TicketRegistered(drawingId, ticketId, canvasHash);
    }

    function closeTicketSales(uint256 drawingId) external {
        Drawing storage drawing = drawings[drawingId];
        if (drawing.state != DrawingState.OPEN) revert Errors.InvalidDrawingState();
        if (block.timestamp < drawing.closeTime) revert Errors.TicketSalesClosed();

        drawing.state = DrawingState.CLOSED;
        emit Events.TicketSalesClosed(drawingId, drawing.totalTickets);
    }

    /// @notice Commit to a future drand round for randomness.
    /// @dev Called by coordinator after closing ticket sales and distributing alUSD.
    ///      Targets a drand round ~30s in the future to ensure it hasn't been produced yet.
    function triggerDrawing(uint256 drawingId) external onlyCoordinator nonReentrant {
        Drawing storage drawing = drawings[drawingId];

        // Auto-close if needed
        if (drawing.state == DrawingState.OPEN && block.timestamp >= drawing.closeTime) {
            drawing.state = DrawingState.CLOSED;
            emit Events.TicketSalesClosed(drawingId, drawing.totalTickets);
        }

        if (drawing.state != DrawingState.CLOSED) revert Errors.InvalidDrawingState();
        if (block.timestamp < drawing.drawTime) revert Errors.DrawingNotReady();

        // Compute target round and commit
        drawing.targetRound = _computeRound(block.timestamp + Constants.DRAND_DELAY);
        drawing.state = DrawingState.PENDING_RANDOMNESS;
        drawing.requestTime = block.timestamp;

        emit Events.DrawingTriggered(drawingId, drawing.targetRound);
    }

    /// @notice Submit drand beacon data to resolve a pending drawing.
    /// @dev OPEN KEEPER: anyone can call this. The BLS signature is verified on-chain.
    /// @param drawingId The drawing to resolve
    /// @param round The drand round number (must match targetRound)
    /// @param signature The BLS signature on G1 [x, y]
    function submitRandomness(
        uint256 drawingId,
        uint256 round,
        uint256[2] calldata signature
    ) external nonReentrant {
        Drawing storage drawing = drawings[drawingId];
        if (drawing.state != DrawingState.PENDING_RANDOMNESS) revert Errors.InvalidDrawingState();
        if (round != drawing.targetRound) revert Errors.InvalidDrandRound();

        // Verify BLS signature on-chain via the drand beacon contract
        drandBeacon.verifyBeaconRound(round, signature);

        // Derive randomness from the signature
        uint256 randomness = uint256(keccak256(abi.encode(
            signature[0],
            signature[1],
            block.chainid,
            address(this),
            drawingId
        )));

        uint16 winningHash = uint16(randomness & 0xFFFF);
        uint256 winnerCount = hashTicketCount[drawingId][winningHash];

        drawing.winningHash = winningHash;
        drawing.winnerCount = winnerCount;
        drawing.state = DrawingState.RESOLVED;
        drawing.resolvedTime = block.timestamp;

        emit Events.DrawingResolved(drawingId, winningHash, winnerCount);
    }

    /// @notice Retarget to a new drand round if the original times out.
    /// @dev Called by coordinator if no keeper submits within DRAND_TIMEOUT.
    function retryRound(uint256 drawingId) external onlyCoordinator nonReentrant {
        Drawing storage drawing = drawings[drawingId];
        if (drawing.state != DrawingState.PENDING_RANDOMNESS) revert Errors.InvalidDrawingState();
        if (block.timestamp < drawing.requestTime + Constants.DRAND_TIMEOUT) {
            revert Errors.DrandTimeoutNotReached();
        }

        drawing.targetRound = _computeRound(block.timestamp + Constants.DRAND_DELAY);
        drawing.requestTime = block.timestamp;

        emit Events.DrandRetry(drawingId);
    }

    // ──── Internal ────

    /// @dev Compute the drand round for a given timestamp
    function _computeRound(uint256 timestamp) internal view returns (uint256) {
        uint256 genesis = drandBeacon.genesisTimestamp();
        uint256 period = drandBeacon.period();
        uint256 delta = timestamp - genesis;
        return delta / period + (delta % period > 0 ? 1 : 0);
    }

    // ──── View Functions ────

    function getDrawing(uint256 drawingId) external view returns (Drawing memory) {
        return drawings[drawingId];
    }

    function isDrawingOpen(uint256 drawingId) external view returns (bool) {
        Drawing storage drawing = drawings[drawingId];
        return drawing.state == DrawingState.OPEN && block.timestamp < drawing.closeTime;
    }

    function getHashPopularity(uint256 drawingId, uint16 hash) external view returns (uint256) {
        return hashTicketCount[drawingId][hash];
    }

    function getWinningTickets(uint256 drawingId) external view returns (uint256[] memory) {
        Drawing storage drawing = drawings[drawingId];
        if (drawing.state != DrawingState.RESOLVED) return new uint256[](0);
        return hashTicketIds[drawingId][drawing.winningHash];
    }
}
