// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IAlchemistV3, IVaultV2} from "./interfaces/IAlchemistV3.sol";
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
/// @notice Main entry point. Handles ticket purchases (USDC -> MYT -> V3 deposit -> NFT + LUCK),
///         drawing triggers (mint alUSD -> distribute), prize claims, ticket burns,
///         and autonomous operation via keeper incentives.
/// @dev V3 integration: USDC is wrapped into MYT vault shares, deposited into a pooled
///      V3 position (NFT-based), and alUSD is minted against the position at trigger time.
contract LuckyPotion is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ──── Immutable Protocol References ────
    IERC20 public immutable usdc;
    IERC20 public immutable alUSD;
    IAlchemistV3 public immutable alchemist;
    IVaultV2 public immutable mytVault;

    // ──── Sub-Contracts ────
    TicketNFT public immutable ticketNFT;
    LuckToken public immutable luckToken;
    LuckStaking public immutable luckStaking;
    DrawingManager public immutable drawingManager;
    PrizeVault public immutable prizeVault;

    // ──── V3 Position State ────
    /// @dev V3 uses NFT-based positions. Magic Potion holds ONE pooled position.
    ///      Created on first deposit (recipientId=0), reused for all subsequent deposits.
    ///      Set during initialize() or first buyTicket().
    uint256 public positionTokenId;

    // ──── State ────
    bool public initialized;
    bool public paused;
    address public treasury;

    // ──── Keeper Reward System ────
    uint256 public keeperBaseReward = 1e18;
    uint256 public keeperRatePerStep = 0.1e18;
    uint256 public keeperStepDuration = 300;
    /// @dev FIX EX-07: ceiling for stale-drawing keeper payouts so an abandoned
    ///      drawing cannot mint unbounded LUCK to whoever eventually triggers it.
    uint256 public keeperRewardCap = 5e18;

    // ──── Configurable Fee Split ────
    uint256 public prizeBps = 8300;
    uint256 public stakingBps = 1200;
    uint256 public treasuryBps = 500;
    uint256 public constant MAX_TREASURY_BPS = 1000;

    mapping(uint256 => bool) public ticketBurned;

    // ──── Constructor ────

    constructor(
        address _usdc,
        address _alUSD,
        address _alchemist,
        address _mytVault,
        address _ticketNFT,
        address _luckToken,
        address _luckStaking,
        address _drawingManager,
        address _prizeVault,
        address _treasury
    ) Ownable(msg.sender) {
        if (
            _usdc == address(0) || _alUSD == address(0) || _alchemist == address(0) ||
            _mytVault == address(0) || _ticketNFT == address(0) || _luckToken == address(0) ||
            _luckStaking == address(0) || _drawingManager == address(0) ||
            _prizeVault == address(0) || _treasury == address(0)
        ) revert Errors.ZeroAddress();

        usdc = IERC20(_usdc);
        alUSD = IERC20(_alUSD);
        alchemist = IAlchemistV3(_alchemist);
        mytVault = IVaultV2(_mytVault);
        ticketNFT = TicketNFT(_ticketNFT);
        luckToken = LuckToken(_luckToken);
        luckStaking = LuckStaking(_luckStaking);
        drawingManager = DrawingManager(_drawingManager);
        prizeVault = PrizeVault(_prizeVault);
        treasury = _treasury;
    }

    // ──── Initialization ────

    function initialize() external onlyOwner {
        if (initialized) revert Errors.AlreadyInitialized();
        initialized = true;
        luckStaking.newEpoch();
        uint256 drawingId = drawingManager.startDrawing();
        emit Events.Initialized(drawingId);
    }

    // ──── Ticket Purchase ────

    /// @notice Buy a single lottery ticket.
    /// @dev Flow: USDC -> wrap into MYT shares -> deposit shares into V3 position.
    ///      On first call, creates the V3 position (positionTokenId).
    function buyTicket(bytes calldata canvasData) external nonReentrant returns (uint256 ticketId) {
        _requireActive();
        uint256 drawingId = drawingManager.currentDrawingId();
        if (!drawingManager.isDrawingOpen(drawingId)) revert Errors.TicketSalesClosed();

        // Deposit USDC into V3 (wraps through MYT vault first)
        _depositToV3(Constants.TICKET_PRICE);

        // Compute canvas hash and mint NFT
        uint16 canvasHash = CanvasHash.computeCanvasHash(canvasData);
        ticketId = ticketNFT.mint(msg.sender, drawingId, canvasHash, canvasData);

        // Mint 1 LUCK per ticket
        luckToken.mint(msg.sender, Constants.LUCK_PER_TICKET);

        // Register hash with DrawingManager
        drawingManager.registerTicket(drawingId, ticketId, canvasHash);

        emit Events.TicketPurchased(msg.sender, ticketId, drawingId, canvasHash);
    }

    /// @notice Buy multiple lottery tickets in one transaction
    function buyTickets(bytes[] calldata canvasDataArray) external nonReentrant returns (uint256[] memory ticketIds) {
        _requireActive();
        uint256 count = canvasDataArray.length;
        if (count == 0) revert Errors.ZeroAmount();
        if (count > Constants.MAX_BATCH_SIZE) revert Errors.BatchTooLarge();

        uint256 drawingId = drawingManager.currentDrawingId();
        if (!drawingManager.isDrawingOpen(drawingId)) revert Errors.TicketSalesClosed();

        uint256 totalCost = Constants.TICKET_PRICE * count;

        // Deposit all USDC into V3 in one call
        _depositToV3(totalCost);

        // Mint LUCK for all tickets
        luckToken.mint(msg.sender, Constants.LUCK_PER_TICKET * count);

        ticketIds = new uint256[](count);
        for (uint256 i = 0; i < count;) {
            ticketIds[i] = _mintAndRegister(drawingId, canvasDataArray[i]);
            unchecked { ++i; }
        }

        emit Events.BatchTicketsPurchased(msg.sender, ticketIds, drawingId);
    }

    /// @dev Mints one ticket and registers its hash. Kept as a separate
    ///      function so the IR optimizer does not inline the array-heavy
    ///      body into buyTickets (stack-too-deep).
    function _mintAndRegister(uint256 drawingId, bytes calldata canvasData) internal returns (uint256 tid) {
        uint16 canvasHash = CanvasHash.computeCanvasHash(canvasData);
        tid = ticketNFT.mint(msg.sender, drawingId, canvasHash, canvasData);
        drawingManager.registerTicket(drawingId, tid, canvasHash);
        emit Events.TicketPurchased(msg.sender, tid, drawingId, canvasHash);
    }

    // ──── Drawing Lifecycle ────

    /// @notice Trigger the current drawing. Permissionless after drawTime.
    /// @dev Mints available alUSD from the V3 position, distributes it
    ///      (83% prize, 12% LUCK staking, 5% treasury),
    ///      advances LUCK epoch, then commits to a drand round.
    ///      FIX EX-01: tolerates a third-party closeTicketSales (state CLOSED)
    ///      so a griefer cannot brick the weekly drawing.
    ///      FIX EX-03: a reverting V3 mint (debt ceiling, dust, pause) skips
    ///      this week's distribution instead of bricking the lifecycle.
    function triggerDrawing() external nonReentrant {
        _requireActive();

        uint256 drawingId = drawingManager.currentDrawingId();
        DrawingManager.Drawing memory drawing = drawingManager.getDrawing(drawingId);
        bool isOpen = drawing.state == DrawingManager.DrawingState.OPEN;
        if (!isOpen && drawing.state != DrawingManager.DrawingState.CLOSED) {
            revert Errors.DrawingAlreadyTriggered();
        }
        if (block.timestamp < drawing.drawTime) revert Errors.DrawingNotReady();

        if (isOpen) {
            drawingManager.closeTicketSales(drawingId);
        }

        // Mint all available alUSD from V3 position
        if (positionTokenId != 0) {
            uint256 mintable = alchemist.getMaxBorrowable(positionTokenId);
            if (mintable > 0) {
                try alchemist.mint(positionTokenId, mintable, address(this)) {
                    _distributeAlUSD(drawingId, mintable);
                } catch {
                    // V3 refused (debt ceiling / minimum mint / pause).
                    // Borrowing power stays in the position; the drawing lives on.
                    emit Events.AlUsDMintSkipped(drawingId, mintable);
                }
            }
        }

        luckStaking.newEpoch();
        _payKeeper(msg.sender, drawing.drawTime);
        drawingManager.triggerDrawing(drawingId);
    }

    /// @notice Submit drand beacon data to resolve the current drawing.
    /// @dev Called directly on DrawingManager.submitRandomness() by frontend/keeper.
    ///      Keeper LUCK rewards are paid on finalizeDrawing instead.

    /// @notice Finalize the current drawing after randomness resolves. Permissionless.
    function finalizeDrawing() external nonReentrant {
        _requireActive();

        uint256 drawingId = drawingManager.currentDrawingId();
        DrawingManager.Drawing memory drawing = drawingManager.getDrawing(drawingId);
        if (drawing.state != DrawingManager.DrawingState.RESOLVED) revert Errors.DrawingNotResolved();

        prizeVault.resolveDrawing(drawingId, drawing.winningHash, drawing.winnerCount);

        uint256 nextDrawingId = drawingManager.startDrawing();
        prizeVault.applyRollover(nextDrawingId);

        _payKeeper(msg.sender, drawing.resolvedTime);

        emit Events.DrawingFinalized(drawingId, drawing.winningHash, drawing.winnerCount > 0, drawing.winnerCount);
    }

    // ──── Prize Claims ────

    function claimPrize(uint256 ticketId) external nonReentrant {
        if (ticketNFT.ownerOf(ticketId) != msg.sender) revert Errors.NotTicketOwner();
        if (prizeVault.isTicketClaimed(ticketId)) revert Errors.TicketAlreadyClaimed();

        TicketNFT.TicketData memory ticket = ticketNFT.getTicket(ticketId);
        DrawingManager.Drawing memory drawing = drawingManager.getDrawing(ticket.drawingId);
        if (drawing.state != DrawingManager.DrawingState.RESOLVED) revert Errors.DrawingNotResolved();
        if (ticket.canvasHash != drawing.winningHash) revert Errors.TicketNotWinner();

        prizeVault.claimPrize(ticket.drawingId, ticketId, msg.sender);

        emit Events.PrizeClaimed(msg.sender, ticketId, ticket.drawingId, prizeVault.getPerWinnerAmount(ticket.drawingId));
    }

    // ──── Ticket Burns ────

    function burnTicket(uint256 ticketId) external nonReentrant {
        if (ticketNFT.ownerOf(ticketId) != msg.sender) revert Errors.NotTicketOwner();
        if (ticketBurned[ticketId]) revert Errors.TicketAlreadyBurned();

        TicketNFT.TicketData memory ticket = ticketNFT.getTicket(ticketId);
        DrawingManager.Drawing memory drawing = drawingManager.getDrawing(ticket.drawingId);

        if (drawing.state != DrawingManager.DrawingState.RESOLVED) revert Errors.CannotBurnActiveTicket();
        if (ticket.canvasHash == drawing.winningHash) revert Errors.CannotBurnWinningTicket();

        ticketBurned[ticketId] = true;
        ticketNFT.burn(ticketId);
        luckToken.mint(msg.sender, Constants.BURN_LUCK_REWARD);

        emit Events.TicketBurned(msg.sender, ticketId, ticket.drawingId, Constants.BURN_LUCK_REWARD);
    }

    // ──── Admin ────

    function setPaused(bool _paused) external onlyOwner {
        paused = _paused;
        emit Events.PauseToggled(_paused);
    }

    function setTreasury(address _treasury) external onlyOwner {
        if (_treasury == address(0)) revert Errors.ZeroAddress();
        treasury = _treasury;
        emit Events.TreasuryUpdated(_treasury);
    }

    function setKeeperParams(uint256 _baseReward, uint256 _ratePerStep, uint256 _stepDuration) external onlyOwner {
        if (_stepDuration == 0) revert Errors.ZeroAmount();
        keeperBaseReward = _baseReward;
        keeperRatePerStep = _ratePerStep;
        keeperStepDuration = _stepDuration;
        emit Events.KeeperParamsUpdated(_baseReward, _ratePerStep, _stepDuration);
    }

    function setKeeperRewardCap(uint256 _cap) external onlyOwner {
        keeperRewardCap = _cap;
        emit Events.KeeperRewardCapUpdated(_cap);
    }

    function setFeeSplit(uint256 _stakingBps, uint256 _treasuryBps) external onlyOwner {
        if (_treasuryBps > MAX_TREASURY_BPS) revert Errors.TreasuryCapExceeded();
        if (_stakingBps + _treasuryBps > Constants.BPS_DENOMINATOR) revert Errors.InvalidFeeSplit();
        stakingBps = _stakingBps;
        treasuryBps = _treasuryBps;
        prizeBps = Constants.BPS_DENOMINATOR - _stakingBps - _treasuryBps;
        emit Events.FeeSplitUpdated(prizeBps, stakingBps, treasuryBps);
    }

    function rescueToken(address token, uint256 amount, address to) external onlyOwner {
        if (token == address(usdc) || token == address(alUSD)) {
            revert Errors.CannotRescueProtocolToken();
        }
        IERC20(token).safeTransfer(to, amount);
    }

    /// @notice Retarget to a new drand round if the original times out.
    /// @dev FIX EX-02: owner-only. Public retry let anyone churn targetRounds,
    ///      enabling unbounded griefing (and hash-shopping when no neutral
    ///      keeper exists).
    function retryRound() external onlyOwner {
        _requireActive();
        uint256 drawingId = drawingManager.currentDrawingId();
        drawingManager.retryRound(drawingId);
    }

    // ──── View Functions ────

    function getCurrentDrawing() external view returns (DrawingManager.Drawing memory) {
        return drawingManager.getDrawing(drawingManager.currentDrawingId());
    }

    function getHashPopularity(uint256 drawingId, uint16 hash) external view returns (uint256) {
        return drawingManager.getHashPopularity(drawingId, hash);
    }

    function getTicketInfo(uint256 ticketId) external view returns (TicketNFT.TicketData memory) {
        return ticketNFT.getTicket(ticketId);
    }

    function isWinner(uint256 ticketId) external view returns (bool) {
        TicketNFT.TicketData memory ticket = ticketNFT.getTicket(ticketId);
        DrawingManager.Drawing memory drawing = drawingManager.getDrawing(ticket.drawingId);
        if (drawing.state != DrawingManager.DrawingState.RESOLVED) return false;
        return ticket.canvasHash == drawing.winningHash;
    }

    /// @notice Get protocol stats. Uses V3 CDP queries with tokenId.
    function protocolStats() external view returns (
        uint256 currentDrawingId,
        uint256 totalTicketsSold,
        uint256 alchemistTotalValue,
        uint256 alchemistDebt,
        uint256 alchemistBorrowable
    ) {
        currentDrawingId = drawingManager.currentDrawingId();
        DrawingManager.Drawing memory drawing = drawingManager.getDrawing(currentDrawingId);
        totalTicketsSold = drawing.totalTickets;

        if (positionTokenId != 0) {
            alchemistTotalValue = alchemist.totalValue(positionTokenId);
            (, alchemistDebt,) = alchemist.getCDP(positionTokenId);
            alchemistBorrowable = alchemist.getMaxBorrowable(positionTokenId);
        }
    }

    // ──── Internal: V3 Deposit Flow ────

    function _requireActive() internal view {
        if (!initialized) revert Errors.NotInitialized();
        if (paused) revert Errors.ProtocolPaused();
    }

    /// @dev Wraps USDC into MYT shares then deposits into the V3 position.
    ///      Mirrors the AlchemistRouter.depositUnderlying() flow:
    ///        1. Take USDC from caller
    ///        2. Approve USDC -> MYT vault
    ///        3. Deposit USDC into MYT vault, receive shares
    ///        4. Approve MYT shares -> Alchemist
    ///        5. Deposit shares into V3 position (create on first call)
    function _depositToV3(uint256 usdcAmount) internal {
        // Step 1: Transfer USDC from buyer
        usdc.safeTransferFrom(msg.sender, address(this), usdcAmount);

        // Step 2: Approve USDC to MYT vault
        usdc.forceApprove(address(mytVault), usdcAmount);

        // Step 3: Wrap USDC into MYT shares
        uint256 shares = mytVault.deposit(usdcAmount, address(this));

        // Clear USDC approval
        usdc.forceApprove(address(mytVault), 0);

        // Step 4: Approve MYT shares to Alchemist
        IERC20(address(mytVault)).forceApprove(address(alchemist), shares);

        // Step 5: Deposit shares into V3 position
        // V3 PositionNFT starts at tokenId 1, so 0 is a safe "uninitialized" sentinel.
        // Passing recipientId=0 creates a new position (auto-incrementing).
        if (positionTokenId == 0) {
            // First deposit: create new position
            (positionTokenId, ) = alchemist.deposit(shares, address(this), 0);
            assert(positionTokenId != 0); // fail fast if V3 ever returns 0
        } else {
            // Subsequent deposits: add to existing position (return value intentionally ignored)
            alchemist.deposit(shares, address(this), positionTokenId);
        }

        // Clear MYT approval
        IERC20(address(mytVault)).forceApprove(address(alchemist), 0);

        emit Events.V3Deposited(usdcAmount, shares);
    }

    // ──── Internal: Distribution ────

    function _distributeAlUSD(uint256 drawingId, uint256 totalMinted) internal {
        uint256 stakingAmount = (totalMinted * stakingBps) / Constants.BPS_DENOMINATOR;
        uint256 treasuryAmount = (totalMinted * treasuryBps) / Constants.BPS_DENOMINATOR;
        uint256 prizeAmount = totalMinted - stakingAmount - treasuryAmount;

        if (stakingAmount > 0) {
            alUSD.forceApprove(address(luckStaking), stakingAmount);
            luckStaking.addRewards(stakingAmount);
        }

        if (treasuryAmount > 0) {
            alUSD.safeTransfer(treasury, treasuryAmount);
        }

        if (prizeAmount > 0) {
            alUSD.forceApprove(address(prizeVault), prizeAmount);
            prizeVault.deposit(drawingId, prizeAmount);
        }

        emit Events.AlUSDDistributed(drawingId, totalMinted, treasuryAmount, stakingAmount, prizeAmount);
    }

    function _payKeeper(address keeper, uint256 eligibleTime) internal {
        uint256 elapsed = block.timestamp > eligibleTime
            ? block.timestamp - eligibleTime : 0;
        uint256 steps = elapsed / keeperStepDuration;
        uint256 reward = keeperBaseReward + (steps * keeperRatePerStep);
        if (reward > keeperRewardCap) reward = keeperRewardCap;
        luckToken.mint(keeper, reward);
        emit Events.KeeperPaid(keeper, reward);
    }
}
