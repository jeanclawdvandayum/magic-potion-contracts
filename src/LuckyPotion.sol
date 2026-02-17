// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IAlchemistV3} from "./interfaces/IAlchemistV3.sol";
import {Constants} from "./libraries/Constants.sol";
import {Errors} from "./libraries/Errors.sol";
import {Events} from "./libraries/Events.sol";
import {CanvasHash} from "./libraries/CanvasHash.sol";
import {TicketNFT} from "./TicketNFT.sol";
import {LuckToken} from "./LuckToken.sol";
import {LuckStaking} from "./LuckStaking.sol";
import {DrawingManager} from "./DrawingManager.sol";
import {PrizeVault} from "./PrizeVault.sol";

/// @title LuckyPotion — Self-Repaying Lottery Coordinator
/// @notice The main entry point for the Magic Potion protocol. Handles ticket purchases
///         (USDC → Alchemix deposit → NFT + LUCK), drawing triggers (mint alUSD → distribute),
///         prize claims, ticket burns, and admin functions.
/// @dev All sub-contracts (TicketNFT, DrawingManager, PrizeVault, LuckStaking, LuckToken)
///      accept this contract as their coordinator/minter for access control.
contract LuckyPotion is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ──── Immutable Protocol References ────
    IERC20 public immutable usdc;
    IERC20 public immutable alUSD;
    IAlchemistV3 public immutable alchemist;
    address public immutable yieldToken; // Alchemist yield token for deposits

    // ──── Sub-Contracts ────
    TicketNFT public immutable ticketNFT;
    LuckToken public immutable luckToken;
    LuckStaking public immutable luckStaking;
    DrawingManager public immutable drawingManager;
    PrizeVault public immutable prizeVault;

    // ──── State ────
    bool public initialized;
    bool public paused;
    address public opsMultisig;

    // Track which ticket was claimed/burned to avoid double actions
    mapping(uint256 => bool) public ticketClaimed;
    mapping(uint256 => bool) public ticketBurned;

    // ──── Constructor ────

    constructor(
        address _usdc,
        address _alUSD,
        address _alchemist,
        address _yieldToken,
        address _ticketNFT,
        address _luckToken,
        address _luckStaking,
        address _drawingManager,
        address _prizeVault,
        address _opsMultisig
    ) Ownable(msg.sender) {
        if (
            _usdc == address(0) || _alUSD == address(0) || _alchemist == address(0) ||
            _yieldToken == address(0) || _ticketNFT == address(0) || _luckToken == address(0) ||
            _luckStaking == address(0) || _drawingManager == address(0) ||
            _prizeVault == address(0) || _opsMultisig == address(0)
        ) revert Errors.ZeroAddress();

        usdc = IERC20(_usdc);
        alUSD = IERC20(_alUSD);
        alchemist = IAlchemistV3(_alchemist);
        yieldToken = _yieldToken;
        ticketNFT = TicketNFT(_ticketNFT);
        luckToken = LuckToken(_luckToken);
        luckStaking = LuckStaking(_luckStaking);
        drawingManager = DrawingManager(_drawingManager);
        prizeVault = PrizeVault(_prizeVault);
        opsMultisig = _opsMultisig;
    }

    // ──── Initialization ────

    /// @notice Initialize the protocol — starts the first drawing
    function initialize() external onlyOwner {
        if (initialized) revert Errors.AlreadyInitialized();
        initialized = true;

        uint256 drawingId = drawingManager.startDrawing();
        emit Events.Initialized(drawingId);
    }

    // ──── Ticket Purchase ────

    /// @notice Buy a single lottery ticket
    /// @param canvasData 1024-byte pixel art canvas data
    function buyTicket(bytes calldata canvasData) external nonReentrant returns (uint256 ticketId) {
        _requireActive();
        uint256 drawingId = drawingManager.currentDrawingId();
        if (!drawingManager.isDrawingOpen(drawingId)) revert Errors.TicketSalesClosed();

        // Transfer USDC from buyer
        usdc.safeTransferFrom(msg.sender, address(this), Constants.TICKET_PRICE);

        // Deposit into Alchemix
        usdc.approve(address(alchemist), Constants.TICKET_PRICE);
        alchemist.deposit(yieldToken, Constants.TICKET_PRICE, address(this));

        // Compute canvas hash
        uint16 canvasHash = CanvasHash.computeCanvasHash(canvasData);

        // Mint NFT
        ticketId = ticketNFT.mint(msg.sender, drawingId, canvasHash, canvasData);

        // Mint LUCK reward
        luckToken.mint(msg.sender, Constants.LUCK_PER_TICKET);

        // Register hash with DrawingManager
        drawingManager.registerTicket(drawingId, ticketId, canvasHash);

        emit Events.TicketPurchased(msg.sender, ticketId, drawingId, canvasHash);
    }

    /// @notice Buy multiple lottery tickets in one transaction
    /// @param canvasDataArray Array of 1024-byte canvas data
    function buyTickets(bytes[] calldata canvasDataArray) external nonReentrant returns (uint256[] memory ticketIds) {
        _requireActive();
        uint256 count = canvasDataArray.length;
        if (count == 0) revert Errors.ZeroAmount();
        if (count > Constants.MAX_BATCH_SIZE) revert Errors.BatchTooLarge();

        uint256 drawingId = drawingManager.currentDrawingId();
        if (!drawingManager.isDrawingOpen(drawingId)) revert Errors.TicketSalesClosed();

        uint256 totalCost = Constants.TICKET_PRICE * count;

        // Transfer total USDC
        usdc.safeTransferFrom(msg.sender, address(this), totalCost);

        // Deposit all into Alchemix
        usdc.approve(address(alchemist), totalCost);
        alchemist.deposit(yieldToken, totalCost, address(this));

        // Mint LUCK for all tickets at once
        luckToken.mint(msg.sender, Constants.LUCK_PER_TICKET * count);

        ticketIds = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            uint16 canvasHash = CanvasHash.computeCanvasHash(canvasDataArray[i]);
            uint256 ticketId = ticketNFT.mint(msg.sender, drawingId, canvasHash, canvasDataArray[i]);
            drawingManager.registerTicket(drawingId, ticketId, canvasHash);
            ticketIds[i] = ticketId;
            emit Events.TicketPurchased(msg.sender, ticketId, drawingId, canvasHash);
        }

        emit Events.BatchTicketsPurchased(msg.sender, ticketIds, drawingId);
    }

    // ──── Drawing Lifecycle ────

    /// @notice Trigger the current drawing — permissionless after draw time
    /// @dev Mints max alUSD → distributes (2% ops, 15% staking, 83% prize) → requests VRF
    function triggerDrawing() external nonReentrant {
        _requireActive();

        uint256 drawingId = drawingManager.currentDrawingId();
        DrawingManager.Drawing memory drawing = drawingManager.getDrawing(drawingId);
        if (drawing.state != DrawingManager.DrawingState.OPEN) revert Errors.DrawingAlreadyTriggered();
        if (block.timestamp < drawing.drawTime) revert Errors.DrawingNotReady();

        // Close ticket sales first
        drawingManager.closeTicketSales(drawingId);

        // Mint max alUSD from Alchemix
        uint256 mintable = alchemist.getMintAllowance(address(this));
        if (mintable > 0) {
            alchemist.mint(mintable, address(this));
            _distributeAlUSD(drawingId, mintable);
        }

        // Trigger VRF
        drawingManager.triggerDrawing(drawingId);
    }

    /// @notice Finalize the current drawing after VRF has resolved
    /// @dev Resolves the prize vault and starts the next drawing
    function finalizeDrawing() external nonReentrant {
        _requireActive();

        uint256 drawingId = drawingManager.currentDrawingId();
        DrawingManager.Drawing memory drawing = drawingManager.getDrawing(drawingId);
        if (drawing.state != DrawingManager.DrawingState.RESOLVED) revert Errors.DrawingNotResolved();

        // Resolve the prize vault
        prizeVault.resolveDrawing(drawingId, drawing.winningHash, drawing.winnerCount);

        // Start next drawing
        uint256 nextDrawingId = drawingManager.startDrawing();

        // Apply any rollover to the new drawing
        prizeVault.applyRollover(nextDrawingId);

        emit Events.DrawingFinalized(drawingId, drawing.winningHash, drawing.winnerCount > 0, drawing.winnerCount);
    }

    // ──── Prize Claims ────

    /// @notice Claim prize for a winning ticket
    /// @param ticketId The winning ticket's NFT token ID
    function claimPrize(uint256 ticketId) external nonReentrant {
        if (ticketNFT.ownerOf(ticketId) != msg.sender) revert Errors.NotTicketOwner();
        if (ticketClaimed[ticketId]) revert Errors.TicketAlreadyClaimed();

        TicketNFT.TicketData memory ticket = ticketNFT.getTicket(ticketId);
        DrawingManager.Drawing memory drawing = drawingManager.getDrawing(ticket.drawingId);
        if (drawing.state != DrawingManager.DrawingState.RESOLVED) revert Errors.DrawingNotResolved();
        if (ticket.canvasHash != drawing.winningHash) revert Errors.TicketNotWinner();

        ticketClaimed[ticketId] = true;
        prizeVault.claimPrize(ticket.drawingId, msg.sender);

        emit Events.PrizeClaimed(msg.sender, ticketId, ticket.drawingId, prizeVault.getPerWinnerAmount(ticket.drawingId));
    }

    // ──── Ticket Burns ────

    /// @notice Burn a losing ticket to receive 0.1 LUCK
    /// @param ticketId The ticket to burn
    function burnTicket(uint256 ticketId) external nonReentrant {
        if (ticketNFT.ownerOf(ticketId) != msg.sender) revert Errors.NotTicketOwner();
        if (ticketBurned[ticketId]) revert Errors.TicketAlreadyBurned();

        TicketNFT.TicketData memory ticket = ticketNFT.getTicket(ticketId);
        DrawingManager.Drawing memory drawing = drawingManager.getDrawing(ticket.drawingId);

        // Can only burn after drawing is resolved
        if (drawing.state != DrawingManager.DrawingState.RESOLVED) revert Errors.CannotBurnActiveTicket();

        // Cannot burn a winning ticket
        if (ticket.canvasHash == drawing.winningHash) revert Errors.CannotBurnWinningTicket();

        ticketBurned[ticketId] = true;
        ticketNFT.burn(ticketId);
        luckToken.mint(msg.sender, Constants.BURN_LUCK_REWARD);

        emit Events.TicketBurned(msg.sender, ticketId, ticket.drawingId, Constants.BURN_LUCK_REWARD);
    }

    // ──── Admin ────

    /// @notice Toggle protocol pause
    function setPaused(bool _paused) external onlyOwner {
        paused = _paused;
        emit Events.PauseToggled(_paused);
    }

    /// @notice Update the ops multisig address
    function setOpsMultisig(address _opsMultisig) external onlyOwner {
        if (_opsMultisig == address(0)) revert Errors.ZeroAddress();
        opsMultisig = _opsMultisig;
        emit Events.OpsMultisigUpdated(_opsMultisig);
    }

    /// @notice Rescue tokens accidentally sent to this contract
    /// @dev Cannot rescue USDC or alUSD (protocol tokens)
    function rescueToken(address token, uint256 amount, address to) external onlyOwner {
        if (token == address(usdc) || token == address(alUSD)) {
            revert Errors.CannotRescueProtocolToken();
        }
        IERC20(token).safeTransfer(to, amount);
    }

    /// @notice Retry VRF if the previous request timed out
    function retryVRF() external {
        _requireActive();
        uint256 drawingId = drawingManager.currentDrawingId();
        drawingManager.retryVRF(drawingId);
    }

    // ──── View Functions ────

    /// @notice Get the current drawing info
    function getCurrentDrawing() external view returns (DrawingManager.Drawing memory) {
        return drawingManager.getDrawing(drawingManager.currentDrawingId());
    }

    /// @notice Get hash popularity for a given drawing
    function getHashPopularity(uint256 drawingId, uint16 hash) external view returns (uint256) {
        return drawingManager.getHashPopularity(drawingId, hash);
    }

    /// @notice Get ticket info
    function getTicketInfo(uint256 ticketId) external view returns (TicketNFT.TicketData memory) {
        return ticketNFT.getTicket(ticketId);
    }

    /// @notice Check if a ticket is a winner
    function isWinner(uint256 ticketId) external view returns (bool) {
        TicketNFT.TicketData memory ticket = ticketNFT.getTicket(ticketId);
        DrawingManager.Drawing memory drawing = drawingManager.getDrawing(ticket.drawingId);
        if (drawing.state != DrawingManager.DrawingState.RESOLVED) return false;
        return ticket.canvasHash == drawing.winningHash;
    }

    /// @notice Get protocol stats
    function protocolStats() external view returns (
        uint256 currentDrawingId,
        uint256 totalTicketsSold,
        uint256 alchemistTotalValue,
        int256 alchemistDebt
    ) {
        currentDrawingId = drawingManager.currentDrawingId();
        DrawingManager.Drawing memory drawing = drawingManager.getDrawing(currentDrawingId);
        totalTicketsSold = drawing.totalTickets;
        alchemistTotalValue = alchemist.totalValue(address(this));
        alchemistDebt = alchemist.debt(address(this));
    }

    // ──── Internal ────

    function _requireActive() internal view {
        if (!initialized) revert Errors.NotInitialized();
        if (paused) revert Errors.ProtocolPaused();
    }

    /// @dev Distribute minted alUSD according to BPS splits
    function _distributeAlUSD(uint256 drawingId, uint256 totalMinted) internal {
        uint256 opsAmount = (totalMinted * Constants.OPS_BPS) / Constants.BPS_DENOMINATOR;
        uint256 stakingAmount = (totalMinted * Constants.STAKING_BPS) / Constants.BPS_DENOMINATOR;
        uint256 prizeAmount = totalMinted - opsAmount - stakingAmount; // remainder to prize

        // Send ops share
        if (opsAmount > 0) {
            alUSD.safeTransfer(opsMultisig, opsAmount);
        }

        // Fund staking rewards
        if (stakingAmount > 0) {
            alUSD.approve(address(luckStaking), stakingAmount);
            luckStaking.addRewards(stakingAmount);
        }

        // Fund prize vault
        if (prizeAmount > 0) {
            alUSD.approve(address(prizeVault), prizeAmount);
            prizeVault.deposit(drawingId, prizeAmount);
        }

        emit Events.AlUSDDistributed(drawingId, totalMinted, opsAmount, stakingAmount, prizeAmount);
    }
}
