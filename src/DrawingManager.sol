// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IVRFCoordinatorV2Plus} from "./interfaces/chainlink/IVRFCoordinatorV2Plus.sol";
import {Constants} from "./libraries/Constants.sol";
import {Errors} from "./libraries/Errors.sol";
import {Events} from "./libraries/Events.sol";

/// @title DrawingManager — Lottery drawing lifecycle + Chainlink VRF V2.5
/// @notice Manages drawing state machine (OPEN → CLOSED → PENDING_VRF → RESOLVED),
///         ticket registration, hash tracking, and VRF randomness resolution.
/// @dev Uses a minimal VRF coordinator interface. The actual Chainlink VRFConsumerBaseV2Plus
///      is replaced with a simpler pattern: coordinator calls rawFulfillRandomWords().
contract DrawingManager {
    // ──── Enums ────
    enum DrawingState { OPEN, CLOSED, PENDING_VRF, RESOLVED }

    // ──── Structs ────
    struct Drawing {
        DrawingState state;
        uint256 openTime;
        uint256 closeTime;    // openTime + DRAWING_DURATION - TICKET_CUTOFF
        uint256 drawTime;     // openTime + DRAWING_DURATION
        uint256 totalTickets;
        uint16 winningHash;
        uint256 winnerCount;
        uint256 vrfRequestId;
        uint256 vrfRequestTime;
    }

    // ──── State ────
    address public coordinator;
    IVRFCoordinatorV2Plus public immutable vrfCoordinator;
    uint256 public currentDrawingId;

    mapping(uint256 => Drawing) public drawings;
    mapping(uint256 => mapping(uint16 => uint256)) public hashTicketCount;
    mapping(uint256 => mapping(uint16 => uint256[])) public hashTicketIds;
    mapping(uint256 => uint256) public vrfRequestToDrawing;

    // ──── VRF Config ────
    uint256 public s_subscriptionId;
    bytes32 public s_keyHash;
    uint32 public s_callbackGasLimit;
    uint16 public s_requestConfirmations;

    // ──── Constructor ────

    constructor(
        address _vrfCoordinator,
        address _coordinator,
        uint256 subscriptionId,
        bytes32 keyHash,
        uint32 callbackGasLimit,
        uint16 requestConfirmations
    ) {
        if (_vrfCoordinator == address(0) || _coordinator == address(0)) {
            revert Errors.ZeroAddress();
        }
        vrfCoordinator = IVRFCoordinatorV2Plus(_vrfCoordinator);
        coordinator = _coordinator;
        s_subscriptionId = subscriptionId;
        s_keyHash = keyHash;
        s_callbackGasLimit = callbackGasLimit;
        s_requestConfirmations = requestConfirmations;
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
            vrfRequestId: 0,
            vrfRequestTime: 0
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

    function triggerDrawing(uint256 drawingId) external onlyCoordinator {
        Drawing storage drawing = drawings[drawingId];

        // Auto-close if needed
        if (drawing.state == DrawingState.OPEN && block.timestamp >= drawing.closeTime) {
            drawing.state = DrawingState.CLOSED;
            emit Events.TicketSalesClosed(drawingId, drawing.totalTickets);
        }

        if (drawing.state != DrawingState.CLOSED) revert Errors.InvalidDrawingState();
        if (block.timestamp < drawing.drawTime) revert Errors.DrawingNotReady();

        uint256 requestId = vrfCoordinator.requestRandomWords(
            IVRFCoordinatorV2Plus.RandomWordsRequest({
                keyHash: s_keyHash,
                subId: s_subscriptionId,
                requestConfirmations: s_requestConfirmations,
                callbackGasLimit: s_callbackGasLimit,
                numWords: 1,
                extraArgs: ""
            })
        );

        drawing.state = DrawingState.PENDING_VRF;
        drawing.vrfRequestId = requestId;
        drawing.vrfRequestTime = block.timestamp;
        vrfRequestToDrawing[requestId] = drawingId;

        emit Events.DrawingTriggered(drawingId, requestId);
    }

    function retryVRF(uint256 drawingId) external onlyCoordinator {
        Drawing storage drawing = drawings[drawingId];
        if (drawing.state != DrawingState.PENDING_VRF) revert Errors.InvalidDrawingState();
        if (block.timestamp < drawing.vrfRequestTime + Constants.VRF_TIMEOUT) {
            revert Errors.VRFTimeoutNotReached();
        }

        uint256 requestId = vrfCoordinator.requestRandomWords(
            IVRFCoordinatorV2Plus.RandomWordsRequest({
                keyHash: s_keyHash,
                subId: s_subscriptionId,
                requestConfirmations: s_requestConfirmations,
                callbackGasLimit: s_callbackGasLimit,
                numWords: 1,
                extraArgs: ""
            })
        );

        drawing.vrfRequestId = requestId;
        drawing.vrfRequestTime = block.timestamp;
        vrfRequestToDrawing[requestId] = drawingId;

        emit Events.VRFRetry(drawingId);
    }

    // ──── VRF Callback ────

    /// @notice Called by VRF coordinator to deliver randomness
    /// @dev Only callable by the VRF coordinator contract
    function rawFulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) external {
        if (msg.sender != address(vrfCoordinator)) revert Errors.InvalidVRFRequest();

        uint256 drawingId = vrfRequestToDrawing[requestId];
        if (drawingId == 0) revert Errors.InvalidVRFRequest();

        Drawing storage drawing = drawings[drawingId];
        if (drawing.state != DrawingState.PENDING_VRF) return;

        uint16 winningHash = uint16(randomWords[0] & 0xFFFF);
        uint256 winnerCount = hashTicketCount[drawingId][winningHash];

        drawing.winningHash = winningHash;
        drawing.winnerCount = winnerCount;
        drawing.state = DrawingState.RESOLVED;

        emit Events.DrawingResolved(drawingId, winningHash, winnerCount);
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
