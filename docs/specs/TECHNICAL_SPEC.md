# Lucky Potion — Master Technical Specification

**Version:** 0.1.0  
**Date:** 2026-02-14  
**Author:** Jean (Chief Engineer)  
**Audience:** Implementation team (junior-to-mid Solidity devs)  
**Chain:** Arbitrum One (L2)  
**Solidity:** ^0.8.24  
**License:** MIT  

---

## Table of Contents

1. [System Overview](#1-system-overview)
2. [External Dependencies](#2-external-dependencies)
3. [Constants & Configuration](#3-constants--configuration)
4. [Contract: LuckToken](#4-contract-lucktoken)
5. [Contract: TicketNFT](#5-contract-ticketnft)
6. [Contract: LuckStaking](#6-contract-luckstaking)
7. [Contract: PrizeVault](#7-contract-prizevault)
8. [Contract: DrawingManager](#8-contract-drawingmanager)
9. [Contract: LuckyPotion (Coordinator)](#9-contract-luckypotion-coordinator)
10. [Canvas Hash Function](#10-canvas-hash-function)
11. [State Machine](#11-state-machine)
12. [Invariants](#12-invariants)
13. [Error Conditions](#13-error-conditions)
14. [Events](#14-events)
15. [Access Control](#15-access-control)
16. [Deployment Sequence](#16-deployment-sequence)
17. [Upgrade Strategy](#17-upgrade-strategy)
18. [Test Plan](#18-test-plan)
19. [Gas Estimates](#19-gas-estimates)
20. [Frontend Integration Notes](#20-frontend-integration-notes)

---

## 1. System Overview

```
                          ┌──────────────────────────────────┐
                          │         LuckyPotion.sol          │
                          │       (Main Coordinator)         │
                          │                                  │
                          │  buyTicket()                     │
                          │  triggerDrawing()                │
                          │  claimPrize()                    │
                          │  burnTicket()                    │
                          └──┬───────┬───────┬──────┬───────┘
                             │       │       │      │
                ┌────────────┘       │       │      └────────────┐
                ▼                    ▼       ▼                   ▼
     ┌──────────────────┐  ┌──────────┐  ┌──────────┐  ┌──────────────┐
     │   TicketNFT.sol  │  │ LuckToken│  │  Prize   │  │   Drawing    │
     │    (ERC-721)     │  │  (ERC-20)│  │ Vault.sol│  │  Manager.sol │
     │                  │  │          │  │          │  │              │
     │ mint/burn/       │  │ mint/    │  │ deposit/ │  │ lifecycle/   │
     │ tokenURI/        │  │ transfer │  │ claim/   │  │ VRF/rollover │
     │ canvasData       │  │          │  │ rollover │  │              │
     └──────────────────┘  └──────────┘  └──────────┘  └──────┬───────┘
                                                               │
                                                               ▼
                                           ┌─────────────────────────────┐
                                           │  Chainlink VRF V2.5         │
                                           │  (VRFConsumerBaseV2Plus)     │
                                           └─────────────────────────────┘

     External:
     ┌──────────────────┐  ┌──────────────┐
     │  AlchemistV3     │  │  USDC        │
     │  (deposit/mint)  │  │  (ERC-20)    │
     └──────────────────┘  └──────────────┘
     ┌──────────────────┐
     │  alUSD           │
     │  (ERC-20)        │
     └──────────────────┘
```

**Data flow:**
1. User calls `LuckyPotion.buyTicket(canvasData)` with USDC approval
2. LuckyPotion deposits USDC into AlchemistV3, mints TicketNFT + LUCK to user
3. After drawing window closes, anyone calls `LuckyPotion.triggerDrawing()`
4. LuckyPotion max-mints alUSD from Alchemix, distributes to ops/staking/prize vault
5. DrawingManager requests Chainlink VRF randomness
6. VRF callback resolves winning hash → DrawingManager stores result
7. Winners call `LuckyPotion.claimPrize(ticketId)`
8. Losers optionally call `LuckyPotion.burnTicket(ticketId)` for 0.1 LUCK

---

## 2. External Dependencies

### 2.1 AlchemistV3

```pseudocode
interface IAlchemistV3 {
    // Deposit USDC as collateral. Returns shares received.
    function deposit(
        address yieldToken,     // The yield-bearing USDC vault token
        uint256 amount,         // USDC amount (6 decimals)
        address recipient       // Position owner (LuckyPotion contract)
    ) returns (uint256 shares)

    // Mint alUSD against deposited collateral
    function mint(
        uint256 amount,         // alUSD to mint (18 decimals)
        address recipient       // Receives the alUSD
    )

    // Query max mintable alUSD for a given account
    function getMintAllowance(
        address account
    ) returns (uint256 maxMintable)

    // Query total deposited value for an account (in underlying terms)
    function totalValue(
        address account
    ) returns (uint256 value)

    // Query total debt for an account
    function debt(
        address account
    ) returns (int256 debt)
}
```

**Critical notes for implementers:**
- `deposit()` takes the UNDERLYING token (USDC), not the yield token. The Alchemist routes it internally.
- `yieldToken` is the Alchemix-registered yield vault for USDC (e.g., yvUSDC, aUSDC). This is a CONFIG parameter — see Section 3.
- `getMintAllowance()` returns how much MORE alUSD can be minted. Use this, not manual LTV math.
- `amount` for `mint()` is in 18-decimal alUSD. USDC is 6-decimal. Do NOT mix them up.
- LuckyPotion holds a SINGLE aggregated position. All ticket deposits go to one position.

### 2.2 Chainlink VRF V2.5

```pseudocode
// DrawingManager inherits VRFConsumerBaseV2Plus

interface IVRFCoordinator {
    function requestRandomWords(
        VRFV2PlusClient.RandomWordsRequest calldata req
    ) returns (uint256 requestId)
}

// Callback (override in DrawingManager):
function fulfillRandomWords(
    uint256 requestId,
    uint256[] calldata randomWords
) internal override
```

**Config needed:**
- `subscriptionId` — Chainlink VRF subscription (fund with LINK or native)
- `keyHash` — Gas lane key hash (chain-specific)
- `callbackGasLimit` — 200,000 should be sufficient
- `requestConfirmations` — 3 (standard for Arbitrum)
- `numWords` — 1 (we only need one random word)

### 2.3 Token Interfaces

```pseudocode
USDC:  ERC-20, 6 decimals, address from Arbitrum deployment
alUSD: ERC-20, 18 decimals, minted by AlchemistV3
```

---

## 3. Constants & Configuration

```pseudocode
// ──── IMMUTABLE (set at deployment, never change) ────

TICKET_PRICE          = 5_000_000              // $5 USDC (6 decimals)
LUCK_PER_TICKET       = 1_000_000_000_000_000_000  // 1 LUCK (18 decimals)
BURN_LUCK_REWARD      = 100_000_000_000_000_000    // 0.1 LUCK (18 decimals)
DRAWING_DURATION      = 14 days                // 2 weeks between drawings
TICKET_CUTOFF         = 2 hours                // Sales close 2h before drawing
HASH_SPACE            = 65_536                 // 2^16 possible outcomes

// Allocation basis points (total = 10000)
OPS_BPS               = 200                    // 2%
STAKING_BPS           = 1500                   // 15%
PRIZE_BPS             = 8300                   // 83%
BPS_DENOMINATOR       = 10_000

// ──── CONFIGURABLE (admin/governance controlled) ────

opsMultisig           : address                // Receives 2% ops fee
alchemistV3           : address                // AlchemistV3 contract
yieldToken            : address                // Yield vault for USDC in Alchemist
usdc                  : address                // USDC token
alusd                 : address                // alUSD token
vrfCoordinator        : address                // Chainlink VRF coordinator
vrfSubscriptionId     : uint256                // VRF subscription
vrfKeyHash            : bytes32                // VRF gas lane
vrfCallbackGasLimit   : uint32                 // VRF callback gas
vrfConfirmations      : uint16                 // VRF block confirmations
```

---

## 4. Contract: LuckToken

**File:** `src/LuckToken.sol`  
**Inheritance:** ERC-20 (OpenZeppelin), Ownable  
**Owner:** LuckyPotion contract (only minter)

### 4.1 State Variables

```pseudocode
// Inherited from ERC-20:
//   mapping(address => uint256) balanceOf
//   mapping(address => mapping(address => uint256)) allowance
//   uint256 totalSupply
//   string name = "Lucky Potion"
//   string symbol = "LUCK"
//   uint8 decimals = 18

address public minter    // Set to LuckyPotion address. Only this address can mint.
```

### 4.2 Functions

```pseudocode
constructor(address _minter):
    name = "Lucky Potion"
    symbol = "LUCK"
    minter = _minter

function mint(address to, uint256 amount) external:
    REQUIRE msg.sender == minter
    _mint(to, amount)

function setMinter(address newMinter) external:
    REQUIRE msg.sender == minter
    REQUIRE newMinter != address(0)
    minter = newMinter
    EMIT MinterUpdated(newMinter)
```

**Notes:**
- Standard ERC-20. No special logic beyond restricted minting.
- `transfer()`, `approve()`, `transferFrom()` all standard — LUCK is fully tradeable.
- No max supply. Supply grows linearly with ticket purchases + burn bonuses.
- `setMinter()` allows migration if LuckyPotion is upgraded.

---

## 5. Contract: TicketNFT

**File:** `src/TicketNFT.sol`  
**Inheritance:** ERC-721Enumerable (OpenZeppelin), Ownable  
**Owner:** LuckyPotion contract

### 5.1 State Variables

```pseudocode
// ──── Ticket Data ────
struct TicketData {
    uint256 drawingId       // Which drawing this ticket belongs to
    uint16  canvasHash      // 16-bit hash derived from canvas (the "lottery number")
    uint64  purchaseTime    // Block timestamp of purchase
    bool    burned          // Whether ticket has been burned for LUCK
    bytes   canvasData      // Raw canvas data (1024 bytes for 64x64, 4-color)
                            // Encoding: 2 bits per pixel, row-major, packed into bytes
                            // 64 * 64 * 2 bits = 8192 bits = 1024 bytes
}

mapping(uint256 => TicketData) public tickets       // tokenId => data
uint256 public nextTokenId                          // Auto-incrementing counter, starts at 1
address public coordinator                          // LuckyPotion contract address
```

### 5.2 Canvas Data Encoding

```pseudocode
// 64×64 canvas, 4 colors (2 bits per pixel)
// Colors: 0 = BG, 1 = Light, 2 = Mid, 3 = Dark
//
// Layout: row-major order, left-to-right, top-to-bottom
// Pixel (x, y) at bit position: (y * 64 + x) * 2
//
// Packed into bytes: 4 pixels per byte
//   byte[0] = pixels (0,0), (1,0), (2,0), (3,0)
//   byte[1] = pixels (4,0), (5,0), (6,0), (7,0)
//   ...
//   byte[1023] = pixels (60,63), (61,63), (62,63), (63,63)
//
// Total: 1024 bytes exactly

CANVAS_DATA_LENGTH = 1024  // bytes

function _validateCanvasData(bytes calldata data) internal pure returns (bool):
    return data.length == CANVAS_DATA_LENGTH
    // All byte values are implicitly valid (2 bits × 4 pixels = 8 bits = full byte range)
```

### 5.3 Functions

```pseudocode
constructor(address _coordinator):
    name = "Lucky Potion Ticket"
    symbol = "LPTIX"
    coordinator = _coordinator
    nextTokenId = 1

function mint(
    address to,
    uint256 drawingId,
    uint16 canvasHash,
    bytes calldata canvasData
) external returns (uint256 tokenId):
    REQUIRE msg.sender == coordinator
    REQUIRE canvasData.length == CANVAS_DATA_LENGTH

    tokenId = nextTokenId++

    tickets[tokenId] = TicketData({
        drawingId: drawingId,
        canvasHash: canvasHash,
        purchaseTime: uint64(block.timestamp),
        burned: false,
        canvasData: canvasData
    })

    _mint(to, tokenId)
    EMIT TicketMinted(tokenId, to, drawingId, canvasHash)
    return tokenId

function burn(uint256 tokenId) external:
    REQUIRE msg.sender == coordinator
    REQUIRE !tickets[tokenId].burned

    tickets[tokenId].burned = true
    // NOTE: Do NOT call _burn() — keep the NFT for historical record
    // The 'burned' flag prevents double-burn and marks it visually
    // Actually: _burn() removes ownership. We want that for burn-for-LUCK.
    _burn(tokenId)
    EMIT TicketBurned(tokenId, tickets[tokenId].drawingId)

function getTicket(uint256 tokenId) external view returns (TicketData memory):
    return tickets[tokenId]

function tokenURI(uint256 tokenId) public view override returns (string memory):
    // Return on-chain SVG or base64-encoded metadata
    // Include: drawingId, canvasHash, pixel art rendered as SVG, win/loss status
    // Implementation: render canvasData as SVG with 4-color palette
    // See Section 20 for SVG generation details
    REQUIRE _exists(tokenId) OR tickets[tokenId].burned
    return _generateTokenURI(tokenId)

function _generateTokenURI(uint256 tokenId) internal view returns (string memory):
    TicketData memory t = tickets[tokenId]
    // Build JSON metadata:
    // {
    //   "name": "Lucky Potion #<tokenId>",
    //   "description": "Drawing #<drawingId> | Hash: 0x<canvasHash>",
    //   "image": "data:image/svg+xml;base64,<SVG>",
    //   "attributes": [
    //     { "trait_type": "Drawing", "value": "<drawingId>" },
    //     { "trait_type": "Hash", "value": "0x<canvasHash>" },
    //     { "trait_type": "Status", "value": "won|lost|active|burned" }
    //   ]
    // }
    // SVG renders canvasData as 64×64 grid with palette colors
    // Return as data:application/json;base64,...
```

### 5.4 On-Chain SVG Rendering

```pseudocode
// Palette (configurable per season, but default is Game Boy green)
COLOR_0 = "#0f380f"   // Darkest green  (BG)
COLOR_1 = "#306230"   // Dark green     (Light)
COLOR_2 = "#8bac0f"   // Light green    (Mid)
COLOR_3 = "#9bbc0f"   // Lightest green (Dark)

function _renderSVG(bytes memory canvasData) internal pure returns (string memory):
    // Generate SVG string:
    // <svg xmlns="..." viewBox="0 0 64 64" shape-rendering="crispEdges">
    //   For each pixel (x, y):
    //     Extract 2-bit color from canvasData
    //     <rect x="<x>" y="<y>" width="1" height="1" fill="<COLOR_N>"/>
    // </svg>
    //
    // Optimization: batch consecutive same-color pixels into wider rects
    // This reduces SVG size significantly
    //
    // NOTE: This is gas-expensive. Only called in view function (tokenURI).
    // Not called during state-changing transactions.
```

---

## 6. Contract: LuckStaking

**File:** `src/LuckStaking.sol`  
**Pattern:** MasterChef-style single-asset staking  
**Inheritance:** ReentrancyGuard

### 6.1 State Variables

```pseudocode
// ──── Token References ────
IERC20 public luckToken                // LUCK token
IERC20 public rewardToken              // alUSD token
address public coordinator             // LuckyPotion (sole reward depositor)

// ──── Global Staking State ────
uint256 public totalStaked             // Total LUCK staked across all users
uint256 public accRewardPerShare       // Accumulated alUSD per staked LUCK (scaled by PRECISION)
uint256 constant PRECISION = 1e18      // Scaling factor for reward math

// ──── Per-User Staking State ────
struct UserInfo {
    uint256 stakedAmount               // LUCK tokens staked by this user
    uint256 rewardDebt                 // Reward debt for MasterChef accounting
    // pendingReward = (stakedAmount * accRewardPerShare / PRECISION) - rewardDebt
}

mapping(address => UserInfo) public userInfo
```

### 6.2 Functions

```pseudocode
constructor(address _luckToken, address _rewardToken, address _coordinator):
    luckToken = IERC20(_luckToken)
    rewardToken = IERC20(_rewardToken)
    coordinator = _coordinator

// ──── Called by LuckyPotion when distributing drawing rewards ────
function addRewards(uint256 amount) external:
    REQUIRE msg.sender == coordinator
    REQUIRE amount > 0

    // Transfer alUSD from coordinator to this contract
    rewardToken.transferFrom(msg.sender, address(this), amount)

    IF totalStaked > 0:
        accRewardPerShare += (amount * PRECISION) / totalStaked
    ELSE:
        // No stakers — rewards go to a buffer or are held until someone stakes
        // DESIGN DECISION: Hold in contract. Next staker gets accumulated rewards.
        // This is safe because accRewardPerShare stays 0, and the alUSD sits here.
        // When someone stakes, the alUSD is effectively "trapped" until more rewards come.
        //
        // ALTERNATIVE: Send to opsMultisig if no stakers. Simpler but less fair.
        //
        // CHOSEN: Hold in contract. It's the MasterChef standard behavior.
        // If someone stakes later, the NEXT addRewards() call will distribute
        // per the new totalStaked. The "orphaned" alUSD sits as surplus.
        //
        // To handle orphaned rewards cleanly:
        uint256 orphanedRewards += amount
        // Admin can sweep orphanedRewards to opsMultisig after N drawings with 0 stakers
    ENDIF

    EMIT RewardsAdded(amount, accRewardPerShare)

// ──── User stakes LUCK tokens ────
function stake(uint256 amount) external nonReentrant:
    REQUIRE amount > 0
    UserInfo storage user = userInfo[msg.sender]

    // Claim pending rewards before changing stake
    IF user.stakedAmount > 0:
        uint256 pending = (user.stakedAmount * accRewardPerShare / PRECISION) - user.rewardDebt
        IF pending > 0:
            rewardToken.transfer(msg.sender, pending)
            EMIT RewardsClaimed(msg.sender, pending)

    // Transfer LUCK from user to contract
    luckToken.transferFrom(msg.sender, address(this), amount)

    user.stakedAmount += amount
    user.rewardDebt = user.stakedAmount * accRewardPerShare / PRECISION
    totalStaked += amount

    EMIT Staked(msg.sender, amount)

// ──── User unstakes LUCK tokens ────
function unstake(uint256 amount) external nonReentrant:
    UserInfo storage user = userInfo[msg.sender]
    REQUIRE amount > 0
    REQUIRE user.stakedAmount >= amount

    // Claim pending rewards before changing stake
    uint256 pending = (user.stakedAmount * accRewardPerShare / PRECISION) - user.rewardDebt
    IF pending > 0:
        rewardToken.transfer(msg.sender, pending)
        EMIT RewardsClaimed(msg.sender, pending)

    user.stakedAmount -= amount
    user.rewardDebt = user.stakedAmount * accRewardPerShare / PRECISION
    totalStaked -= amount

    // Transfer LUCK back to user
    luckToken.transfer(msg.sender, amount)

    EMIT Unstaked(msg.sender, amount)

// ──── Claim rewards without changing stake ────
function claimRewards() external nonReentrant:
    UserInfo storage user = userInfo[msg.sender]
    REQUIRE user.stakedAmount > 0

    uint256 pending = (user.stakedAmount * accRewardPerShare / PRECISION) - user.rewardDebt
    REQUIRE pending > 0

    user.rewardDebt = user.stakedAmount * accRewardPerShare / PRECISION
    rewardToken.transfer(msg.sender, pending)

    EMIT RewardsClaimed(msg.sender, pending)

// ──── View: pending rewards for a user ────
function pendingRewards(address account) external view returns (uint256):
    UserInfo memory user = userInfo[account]
    IF user.stakedAmount == 0: return 0
    return (user.stakedAmount * accRewardPerShare / PRECISION) - user.rewardDebt
```

### 6.3 Edge Cases

- **Zero stakers when rewards arrive:** alUSD sits in contract. Not distributed until someone stakes AND new rewards arrive. Orphaned rewards tracked separately.
- **Rounding:** MasterChef pattern has known dust accumulation (≤1 wei per user per reward event). Acceptable.
- **Reentrancy:** All external token transfers happen AFTER state updates. ReentrancyGuard as defense-in-depth.

---

## 7. Contract: PrizeVault

**File:** `src/PrizeVault.sol`  
**Purpose:** Accumulates alUSD prize pool. Releases to winners.  
**Inheritance:** ReentrancyGuard

### 7.1 State Variables

```pseudocode
IERC20 public alusd                    // alUSD token
address public coordinator             // LuckyPotion (sole depositor and claim authorizer)

// ──── Per-Drawing Prize Tracking ────
struct DrawingPrize {
    uint256 allocated                  // alUSD allocated to this drawing's prize
    uint256 claimed                    // alUSD claimed by winners
    uint256 winnerCount                // Number of winning tickets (for split)
    bool    resolved                   // Whether drawing has been resolved
    uint16  winningHash                // The winning hash (set on resolution)
}

mapping(uint256 => DrawingPrize) public drawingPrizes   // drawingId => prize data
uint256 public rolledOverBalance       // alUSD carried over from drawings with no winner
```

### 7.2 Functions

```pseudocode
constructor(address _alusd, address _coordinator):
    alusd = IERC20(_alusd)
    coordinator = _coordinator

// ──── Called by LuckyPotion during triggerDrawing ────
function deposit(uint256 drawingId, uint256 amount) external:
    REQUIRE msg.sender == coordinator
    REQUIRE amount > 0

    alusd.transferFrom(msg.sender, address(this), amount)

    // Add to this drawing's allocation (includes rollover from previous)
    drawingPrizes[drawingId].allocated += amount

    EMIT PrizeDeposited(drawingId, amount)

// ──── Called by LuckyPotion when drawing resolves ────
function resolveDrawing(
    uint256 drawingId,
    uint16 winningHash,
    uint256 winnerCount
) external:
    REQUIRE msg.sender == coordinator
    REQUIRE !drawingPrizes[drawingId].resolved

    DrawingPrize storage prize = drawingPrizes[drawingId]
    prize.resolved = true
    prize.winningHash = winningHash
    prize.winnerCount = winnerCount

    IF winnerCount == 0:
        // No winner — roll over entire allocation to next drawing
        rolledOverBalance += prize.allocated
        EMIT PrizeRolledOver(drawingId, prize.allocated)
    ELSE:
        EMIT PrizeResolved(drawingId, winningHash, winnerCount, prize.allocated)

// ──── Called by LuckyPotion to add rollover to new drawing ────
function applyRollover(uint256 newDrawingId) external:
    REQUIRE msg.sender == coordinator

    IF rolledOverBalance > 0:
        drawingPrizes[newDrawingId].allocated += rolledOverBalance
        EMIT RolloverApplied(newDrawingId, rolledOverBalance)
        rolledOverBalance = 0

// ──── Called by LuckyPotion when winner claims ────
function claimPrize(
    uint256 drawingId,
    address winner
) external nonReentrant returns (uint256 amount):
    REQUIRE msg.sender == coordinator

    DrawingPrize storage prize = drawingPrizes[drawingId]
    REQUIRE prize.resolved
    REQUIRE prize.winnerCount > 0

    // Calculate per-winner share
    uint256 totalPrize = prize.allocated
    uint256 perWinner = totalPrize / prize.winnerCount

    // Track claims to prevent double-claim (managed by coordinator via ticket state)
    prize.claimed += perWinner

    // Safety check: don't over-pay due to rounding
    REQUIRE prize.claimed <= prize.allocated

    alusd.transfer(winner, perWinner)
    EMIT PrizeClaimed(drawingId, winner, perWinner)
    return perWinner

// ──── View: prize info ────
function getPrizeInfo(uint256 drawingId) external view returns (
    uint256 allocated,
    uint256 claimed,
    uint256 winnerCount,
    bool resolved,
    uint16 winningHash
):
    DrawingPrize memory p = drawingPrizes[drawingId]
    return (p.allocated, p.claimed, p.winnerCount, p.resolved, p.winningHash)

function getPerWinnerAmount(uint256 drawingId) external view returns (uint256):
    DrawingPrize memory p = drawingPrizes[drawingId]
    IF !p.resolved OR p.winnerCount == 0: return 0
    return p.allocated / p.winnerCount
```

### 7.3 Edge Cases

- **Rounding on split:** `allocated / winnerCount` may leave dust. Dust stays in vault (adds to future rollovers effectively). Max dust = `winnerCount - 1` wei.
- **No winner:** Full amount rolls over. Rollover is applied to next drawing when it's created.
- **Multiple claims per drawing:** Each winner claims once. Coordinator tracks which tickets have claimed.

---

## 8. Contract: DrawingManager

**File:** `src/DrawingManager.sol`  
**Purpose:** Manages drawing lifecycle and VRF integration.  
**Inheritance:** VRFConsumerBaseV2Plus, Ownable

### 8.1 State Variables

```pseudocode
// ──── Drawing State ────
enum DrawingState {
    OPEN,           // Tickets can be purchased
    CLOSED,         // Ticket sales ended, waiting for triggerDrawing
    PENDING_VRF,    // VRF requested, waiting for callback
    RESOLVED        // Winner determined (or no winner)
}

struct Drawing {
    uint256 id
    DrawingState state
    uint256 openTime           // When ticket sales opened
    uint256 closeTime          // When ticket sales close (openTime + DRAWING_DURATION - TICKET_CUTOFF)
    uint256 drawTime           // When drawing can be triggered (openTime + DRAWING_DURATION)
    uint256 resolvedTime       // When VRF callback was received
    uint256 totalTickets       // Total tickets sold for this drawing
    uint16  winningHash        // The winning 16-bit hash (set by VRF)
    uint256 vrfRequestId       // Chainlink VRF request ID
    bool    hasWinner          // Whether any ticket matched
    uint256 winnerCount        // How many tickets share the winning hash
}

mapping(uint256 => Drawing) public drawings             // drawingId => Drawing
uint256 public currentDrawingId                         // Active drawing
uint256 public nextDrawingId                            // Counter

// ──── Hash Tracking (per drawing) ────
// Maps drawingId => canvasHash => count of tickets with that hash
mapping(uint256 => mapping(uint16 => uint256)) public hashTicketCount

// Maps drawingId => canvasHash => array of ticketIds with that hash
mapping(uint256 => mapping(uint16 => uint256[])) public hashTicketIds

// ──── VRF Request Tracking ────
mapping(uint256 => uint256) public vrfRequestToDrawing  // vrfRequestId => drawingId

// ──── References ────
address public coordinator    // LuckyPotion contract

// ──── VRF Config ────
uint256 public vrfSubscriptionId
bytes32 public vrfKeyHash
uint32  public vrfCallbackGasLimit
uint16  public vrfConfirmations
```

### 8.2 Functions

```pseudocode
constructor(
    address _vrfCoordinator,
    address _coordinator,
    uint256 _vrfSubscriptionId,
    bytes32 _vrfKeyHash
):
    VRFConsumerBaseV2Plus(_vrfCoordinator)
    coordinator = _coordinator
    vrfSubscriptionId = _vrfSubscriptionId
    vrfKeyHash = _vrfKeyHash
    vrfCallbackGasLimit = 200_000
    vrfConfirmations = 3
    nextDrawingId = 1

// ──── Start a new drawing ────
function startDrawing() external returns (uint256 drawingId):
    REQUIRE msg.sender == coordinator

    drawingId = nextDrawingId++
    currentDrawingId = drawingId

    drawings[drawingId] = Drawing({
        id: drawingId,
        state: DrawingState.OPEN,
        openTime: block.timestamp,
        closeTime: block.timestamp + DRAWING_DURATION - TICKET_CUTOFF,
        drawTime: block.timestamp + DRAWING_DURATION,
        resolvedTime: 0,
        totalTickets: 0,
        winningHash: 0,
        vrfRequestId: 0,
        hasWinner: false,
        winnerCount: 0
    })

    EMIT DrawingStarted(drawingId, block.timestamp)
    return drawingId

// ──── Register a ticket's hash for the current drawing ────
function registerTicket(uint256 drawingId, uint256 ticketId, uint16 canvasHash) external:
    REQUIRE msg.sender == coordinator
    REQUIRE drawings[drawingId].state == DrawingState.OPEN
    REQUIRE block.timestamp <= drawings[drawingId].closeTime

    hashTicketCount[drawingId][canvasHash] += 1
    hashTicketIds[drawingId][canvasHash].push(ticketId)
    drawings[drawingId].totalTickets += 1

    EMIT TicketRegistered(drawingId, ticketId, canvasHash)

// ──── Close ticket sales (called automatically or by anyone after closeTime) ────
function closeTicketSales(uint256 drawingId) external:
    Drawing storage d = drawings[drawingId]
    REQUIRE d.state == DrawingState.OPEN
    REQUIRE block.timestamp >= d.closeTime

    d.state = DrawingState.CLOSED
    EMIT TicketSalesClosed(drawingId, d.totalTickets)

// ──── Trigger the drawing (request VRF) ────
function triggerDrawing(uint256 drawingId) external returns (uint256 requestId):
    REQUIRE msg.sender == coordinator
    Drawing storage d = drawings[drawingId]

    // Auto-close if not already closed
    IF d.state == DrawingState.OPEN:
        REQUIRE block.timestamp >= d.closeTime
        d.state = DrawingState.CLOSED

    REQUIRE d.state == DrawingState.CLOSED
    REQUIRE block.timestamp >= d.drawTime

    // Request randomness from Chainlink VRF
    requestId = vrfCoordinator.requestRandomWords(
        VRFV2PlusClient.RandomWordsRequest({
            keyHash: vrfKeyHash,
            subId: vrfSubscriptionId,
            requestConfirmations: vrfConfirmations,
            callbackGasLimit: vrfCallbackGasLimit,
            numWords: 1,
            extraArgs: ""    // Use LINK payment (not native)
        })
    )

    d.vrfRequestId = requestId
    d.state = DrawingState.PENDING_VRF
    vrfRequestToDrawing[requestId] = drawingId

    EMIT DrawingTriggered(drawingId, requestId)
    return requestId

// ──── VRF Callback ────
function fulfillRandomWords(
    uint256 requestId,
    uint256[] calldata randomWords
) internal override:
    uint256 drawingId = vrfRequestToDrawing[requestId]
    REQUIRE drawingId != 0    // Valid request

    Drawing storage d = drawings[drawingId]
    REQUIRE d.state == DrawingState.PENDING_VRF

    // Extract 16-bit winning hash from random word
    uint16 winningHash = uint16(randomWords[0] % HASH_SPACE)

    d.winningHash = winningHash
    d.resolvedTime = block.timestamp
    d.state = DrawingState.RESOLVED

    // Check if any tickets match
    uint256 matchCount = hashTicketCount[drawingId][winningHash]
    d.hasWinner = matchCount > 0
    d.winnerCount = matchCount

    EMIT DrawingResolved(drawingId, winningHash, matchCount)

// ──── View functions ────
function getDrawing(uint256 drawingId) external view returns (Drawing memory):
    return drawings[drawingId]

function isDrawingOpen(uint256 drawingId) external view returns (bool):
    Drawing memory d = drawings[drawingId]
    return d.state == DrawingState.OPEN && block.timestamp <= d.closeTime

function getHashPopularity(uint256 drawingId, uint16 canvasHash) external view returns (uint256):
    return hashTicketCount[drawingId][canvasHash]

function getWinningTickets(uint256 drawingId) external view returns (uint256[] memory):
    Drawing memory d = drawings[drawingId]
    REQUIRE d.state == DrawingState.RESOLVED
    IF !d.hasWinner: return new uint256[](0)
    return hashTicketIds[drawingId][d.winningHash]
```

### 8.3 Edge Cases

- **VRF never responds:** Need a timeout mechanism. After `VRF_TIMEOUT` (e.g. 24 hours), allow re-request or admin fallback. Add:
  ```pseudocode
  uint256 constant VRF_TIMEOUT = 24 hours
  
  function retryVRF(uint256 drawingId) external:
      Drawing storage d = drawings[drawingId]
      REQUIRE d.state == DrawingState.PENDING_VRF
      REQUIRE block.timestamp >= d.drawTime + VRF_TIMEOUT
      // Reset state to CLOSED, allow re-trigger
      d.state = DrawingState.CLOSED
      EMIT VRFRetry(drawingId)
  ```
- **Zero tickets sold:** Drawing resolves with 0 tickets, no winner. Any allocated prize rolls over. `triggerDrawing` should still work — it mints alUSD (from existing collateral) and requests VRF. The VRF resolves, finds 0 matching tickets, rolls over.
- **Late ticket registration:** `registerTicket` checks `block.timestamp <= closeTime`. Revert if too late.
- **Concurrent VRF requests:** Prevented by state machine — can only request VRF from CLOSED state, which transitions to PENDING_VRF. No second request possible.

---

## 9. Contract: LuckyPotion (Coordinator)

**File:** `src/LuckyPotion.sol`  
**Purpose:** Main entry point. Orchestrates all sub-contracts.  
**Inheritance:** ReentrancyGuard, Ownable

### 9.1 State Variables

```pseudocode
// ──── Sub-contract References ────
TicketNFT     public ticketNFT
LuckToken     public luckToken
LuckStaking   public luckStaking
PrizeVault    public prizeVault
DrawingManager public drawingManager

// ──── External References ────
IAlchemistV3  public alchemist
IERC20        public usdc
IERC20        public alusd
address       public yieldToken         // Alchemist yield vault for USDC

// ──── Admin ────
address       public opsMultisig        // Receives 2% ops fee

// ──── Ticket Claim Tracking ────
mapping(uint256 => bool) public ticketClaimed   // ticketId => has claimed prize
mapping(uint256 => bool) public ticketBurned    // ticketId => has been burned for LUCK

// ──── Protocol Stats ────
uint256 public totalUSDCDeposited       // Cumulative USDC ever deposited
uint256 public totalTicketsSold         // Cumulative tickets ever sold
uint256 public totalTicketsBurned       // Cumulative tickets burned for LUCK
uint256 public totalLUCKMinted          // Cumulative LUCK ever minted (tickets + burns)
uint256 public totalAlUSDMinted         // Cumulative alUSD minted from Alchemix
uint256 public totalPrizesPaid          // Cumulative alUSD paid to winners

// ──── State ────
bool public initialized                 // Whether first drawing has been started
bool public paused                      // Emergency pause
```

### 9.2 Functions

```pseudocode
constructor(
    address _alchemist,
    address _usdc,
    address _alusd,
    address _yieldToken,
    address _opsMultisig,
    address _vrfCoordinator,
    uint256 _vrfSubscriptionId,
    bytes32 _vrfKeyHash
):
    alchemist = IAlchemistV3(_alchemist)
    usdc = IERC20(_usdc)
    alusd = IERC20(_alusd)
    yieldToken = _yieldToken
    opsMultisig = _opsMultisig

    // Deploy sub-contracts
    luckToken = new LuckToken(address(this))
    ticketNFT = new TicketNFT(address(this))
    luckStaking = new LuckStaking(
        address(luckToken),
        address(alusd),
        address(this)
    )
    prizeVault = new PrizeVault(address(alusd), address(this))
    drawingManager = new DrawingManager(
        _vrfCoordinator,
        address(this),
        _vrfSubscriptionId,
        _vrfKeyHash
    )

// ══════════════════════════════════════════════════
//  TICKET PURCHASE
// ══════════════════════════════════════════════════

function buyTicket(bytes calldata canvasData) external nonReentrant returns (uint256 ticketId):
    REQUIRE !paused
    REQUIRE initialized
    uint256 drawingId = drawingManager.currentDrawingId()
    REQUIRE drawingManager.isDrawingOpen(drawingId)

    // 1. Transfer USDC from buyer
    usdc.transferFrom(msg.sender, address(this), TICKET_PRICE)

    // 2. Deposit USDC into Alchemix
    usdc.approve(address(alchemist), TICKET_PRICE)
    alchemist.deposit(yieldToken, TICKET_PRICE, address(this))

    // 3. Compute canvas hash
    uint16 canvasHash = computeCanvasHash(canvasData)

    // 4. Mint ticket NFT
    ticketId = ticketNFT.mint(msg.sender, drawingId, canvasHash, canvasData)

    // 5. Register ticket hash with DrawingManager
    drawingManager.registerTicket(drawingId, ticketId, canvasHash)

    // 6. Mint LUCK to buyer
    luckToken.mint(msg.sender, LUCK_PER_TICKET)

    // 7. Update stats
    totalUSDCDeposited += TICKET_PRICE
    totalTicketsSold += 1
    totalLUCKMinted += LUCK_PER_TICKET

    EMIT TicketPurchased(msg.sender, ticketId, drawingId, canvasHash)
    return ticketId

// Allow buying multiple tickets in one transaction
function buyTickets(bytes[] calldata canvasDataArray) external nonReentrant returns (uint256[] memory ticketIds):
    REQUIRE !paused
    REQUIRE initialized
    REQUIRE canvasDataArray.length > 0
    REQUIRE canvasDataArray.length <= 100    // Gas limit safety

    uint256 drawingId = drawingManager.currentDrawingId()
    REQUIRE drawingManager.isDrawingOpen(drawingId)

    uint256 totalCost = TICKET_PRICE * canvasDataArray.length

    // 1. Transfer total USDC
    usdc.transferFrom(msg.sender, address(this), totalCost)

    // 2. Deposit all USDC into Alchemix (one deposit, saves gas)
    usdc.approve(address(alchemist), totalCost)
    alchemist.deposit(yieldToken, totalCost, address(this))

    ticketIds = new uint256[](canvasDataArray.length)

    FOR i = 0 TO canvasDataArray.length - 1:
        uint16 canvasHash = computeCanvasHash(canvasDataArray[i])
        ticketIds[i] = ticketNFT.mint(msg.sender, drawingId, canvasHash, canvasDataArray[i])
        drawingManager.registerTicket(drawingId, ticketIds[i], canvasHash)

    // Mint all LUCK at once
    uint256 totalLuck = LUCK_PER_TICKET * canvasDataArray.length
    luckToken.mint(msg.sender, totalLuck)

    // Update stats
    totalUSDCDeposited += totalCost
    totalTicketsSold += canvasDataArray.length
    totalLUCKMinted += totalLuck

    EMIT BatchTicketsPurchased(msg.sender, ticketIds, drawingId)
    return ticketIds

// ══════════════════════════════════════════════════
//  DRAWING TRIGGER
// ══════════════════════════════════════════════════

function triggerDrawing() external nonReentrant:
    REQUIRE !paused
    uint256 drawingId = drawingManager.currentDrawingId()
    Drawing memory d = drawingManager.getDrawing(drawingId)
    REQUIRE block.timestamp >= d.drawTime
    REQUIRE d.state == DrawingState.CLOSED OR d.state == DrawingState.OPEN

    // 1. Max-mint alUSD from Alchemix
    uint256 mintable = alchemist.getMintAllowance(address(this))

    IF mintable > 0:
        alchemist.mint(mintable, address(this))
        totalAlUSDMinted += mintable

        // 2. Distribute alUSD
        uint256 opsAmount     = (mintable * OPS_BPS) / BPS_DENOMINATOR
        uint256 stakingAmount = (mintable * STAKING_BPS) / BPS_DENOMINATOR
        uint256 prizeAmount   = mintable - opsAmount - stakingAmount
        // NOTE: prizeAmount uses subtraction to avoid rounding loss

        // Transfer ops fee
        alusd.transfer(opsMultisig, opsAmount)

        // Deposit staking rewards
        alusd.approve(address(luckStaking), stakingAmount)
        luckStaking.addRewards(stakingAmount)

        // Deposit prize allocation
        alusd.approve(address(prizeVault), prizeAmount)
        prizeVault.deposit(drawingId, prizeAmount)

        EMIT AlUSDDistributed(drawingId, mintable, opsAmount, stakingAmount, prizeAmount)

    // 3. Apply any rollover from previous drawings
    prizeVault.applyRollover(drawingId)

    // 4. Request VRF randomness
    drawingManager.triggerDrawing(drawingId)

    EMIT DrawingTriggered(drawingId)

// ──── Called by DrawingManager after VRF resolves ────
// NOTE: This is called INTERNALLY by VRF callback flow.
// DrawingManager.fulfillRandomWords() stores the result.
// We need a separate function to finalize:

function finalizeDrawing(uint256 drawingId) external:
    REQUIRE !paused
    Drawing memory d = drawingManager.getDrawing(drawingId)
    REQUIRE d.state == DrawingState.RESOLVED

    // Notify PrizeVault of result
    prizeVault.resolveDrawing(drawingId, d.winningHash, d.winnerCount)

    // Start next drawing
    drawingManager.startDrawing()

    EMIT DrawingFinalized(drawingId, d.winningHash, d.hasWinner, d.winnerCount)

// ══════════════════════════════════════════════════
//  PRIZE CLAIMING
// ══════════════════════════════════════════════════

function claimPrize(uint256 ticketId) external nonReentrant:
    REQUIRE !paused
    REQUIRE !ticketClaimed[ticketId]

    // Verify caller owns the ticket
    REQUIRE ticketNFT.ownerOf(ticketId) == msg.sender

    // Get ticket data
    TicketNFT.TicketData memory t = ticketNFT.getTicket(ticketId)

    // Verify drawing is resolved
    Drawing memory d = drawingManager.getDrawing(t.drawingId)
    REQUIRE d.state == DrawingState.RESOLVED
    REQUIRE d.hasWinner

    // Verify ticket has winning hash
    REQUIRE t.canvasHash == d.winningHash

    // Mark as claimed
    ticketClaimed[ticketId] = true

    // Claim from prize vault
    uint256 amount = prizeVault.claimPrize(t.drawingId, msg.sender)
    totalPrizesPaid += amount

    EMIT PrizeClaimed(msg.sender, ticketId, t.drawingId, amount)

// ══════════════════════════════════════════════════
//  TICKET BURNING
// ══════════════════════════════════════════════════

function burnTicket(uint256 ticketId) external nonReentrant:
    REQUIRE !paused
    REQUIRE !ticketBurned[ticketId]
    REQUIRE !ticketClaimed[ticketId]

    // Verify caller owns the ticket
    REQUIRE ticketNFT.ownerOf(ticketId) == msg.sender

    // Get ticket data
    TicketNFT.TicketData memory t = ticketNFT.getTicket(ticketId)

    // Verify drawing is resolved (can't burn active tickets)
    Drawing memory d = drawingManager.getDrawing(t.drawingId)
    REQUIRE d.state == DrawingState.RESOLVED

    // Cannot burn winning tickets (must claim prize instead)
    REQUIRE t.canvasHash != d.winningHash

    // Mark as burned
    ticketBurned[ticketId] = true

    // Burn the NFT
    ticketNFT.burn(ticketId)

    // Mint LUCK bonus
    luckToken.mint(msg.sender, BURN_LUCK_REWARD)
    totalTicketsBurned += 1
    totalLUCKMinted += BURN_LUCK_REWARD

    EMIT TicketBurned(msg.sender, ticketId, t.drawingId, BURN_LUCK_REWARD)

// ══════════════════════════════════════════════════
//  ADMIN FUNCTIONS
// ══════════════════════════════════════════════════

function initialize() external onlyOwner:
    REQUIRE !initialized
    initialized = true
    drawingManager.startDrawing()
    EMIT Initialized(drawingManager.currentDrawingId())

function setPaused(bool _paused) external onlyOwner:
    paused = _paused
    EMIT PauseToggled(_paused)

function setOpsMultisig(address newOps) external onlyOwner:
    REQUIRE newOps != address(0)
    opsMultisig = newOps
    EMIT OpsMultisigUpdated(newOps)

// ──── Emergency: rescue tokens accidentally sent to contract ────
// CANNOT rescue USDC (it's in Alchemix), alUSD (it's in vault/staking), or LUCK
function rescueToken(address token, uint256 amount) external onlyOwner:
    REQUIRE token != address(usdc)
    REQUIRE token != address(alusd)
    REQUIRE token != address(luckToken)
    IERC20(token).transfer(opsMultisig, amount)

// ══════════════════════════════════════════════════
//  VIEW FUNCTIONS
// ══════════════════════════════════════════════════

function getCurrentDrawing() external view returns (Drawing memory):
    return drawingManager.getDrawing(drawingManager.currentDrawingId())

function getHashPopularity(uint16 canvasHash) external view returns (uint256):
    return drawingManager.getHashPopularity(drawingManager.currentDrawingId(), canvasHash)

function getTicketInfo(uint256 ticketId) external view returns (
    TicketNFT.TicketData memory ticket,
    bool claimed,
    bool burned,
    bool isWinner
):
    ticket = ticketNFT.getTicket(ticketId)
    claimed = ticketClaimed[ticketId]
    burned = ticketBurned[ticketId]

    Drawing memory d = drawingManager.getDrawing(ticket.drawingId)
    isWinner = (d.state == DrawingState.RESOLVED) && (ticket.canvasHash == d.winningHash)

function protocolStats() external view returns (
    uint256 _totalUSDCDeposited,
    uint256 _totalTicketsSold,
    uint256 _totalTicketsBurned,
    uint256 _totalLUCKMinted,
    uint256 _totalAlUSDMinted,
    uint256 _totalPrizesPaid,
    uint256 _currentPrizePool,
    uint256 _totalLUCKStaked,
    uint256 _currentDrawingId,
    uint256 _currentDrawingTickets
):
    _totalUSDCDeposited = totalUSDCDeposited
    _totalTicketsSold = totalTicketsSold
    _totalTicketsBurned = totalTicketsBurned
    _totalLUCKMinted = totalLUCKMinted
    _totalAlUSDMinted = totalAlUSDMinted
    _totalPrizesPaid = totalPrizesPaid
    _currentPrizePool = alusd.balanceOf(address(prizeVault))
    _totalLUCKStaked = luckStaking.totalStaked()
    _currentDrawingId = drawingManager.currentDrawingId()
    Drawing memory d = drawingManager.getDrawing(_currentDrawingId)
    _currentDrawingTickets = d.totalTickets
```

---

## 10. Canvas Hash Function

**Critical component.** This deterministically maps a 64×64, 4-color pixel art to a 16-bit value.

### 10.1 Implementation

```pseudocode
function computeCanvasHash(bytes calldata canvasData) public pure returns (uint16):
    REQUIRE canvasData.length == 1024

    // Step 1: keccak256 the full canvas data
    bytes32 fullHash = keccak256(canvasData)

    // Step 2: Extract lower 16 bits
    uint16 result = uint16(uint256(fullHash) & 0xFFFF)

    return result
```

### 10.2 Properties

- **Deterministic:** Same canvas → same hash, always. Pure function.
- **Uniform distribution:** keccak256 is cryptographically uniform. Truncating to 16 bits preserves uniformity.
- **Collision-resistant within 16-bit space:** NOT collision-resistant in the traditional sense (2^16 buckets for 2^8192 inputs means massive collisions). This is BY DESIGN — collisions are expected and handled by the prize-splitting mechanic.
- **Gas cost:** ~40 gas for keccak256 of 1024 bytes + negligible for truncation. Very cheap.
- **Verifiable:** Anyone can recompute on-chain or off-chain. No oracle needed.

### 10.3 Frontend Mirror

```javascript
// Frontend must produce identical hashes
function computeCanvasHash(canvasData: Uint8Array): number {
    // canvasData must be exactly 1024 bytes
    // Use ethers.js or viem keccak256, then mask to 16 bits
    const fullHash = keccak256(canvasData)
    return Number(BigInt(fullHash) & BigInt(0xFFFF))
}
```

**Testing requirement:** Generate 1000 random canvases. Compute hash in Solidity AND JavaScript. Assert every pair matches. Zero tolerance for mismatches.

---

## 11. State Machine

### 11.1 Drawing Lifecycle

```
                 initialize()
                      │
                      ▼
    ┌──────────── OPEN ◄────────────────────────┐
    │            (tickets on sale)                │
    │                 │                           │
    │    closeTime reached                        │
    │                 │                           │
    │                 ▼                           │
    │           CLOSED                            │
    │            (sales ended)                    │
    │                 │                           │
    │    drawTime reached                         │
    │    + triggerDrawing()                       │
    │                 │                           │
    │                 ▼                           │
    │          PENDING_VRF                        │
    │            (awaiting randomness)            │
    │                 │                           │
    │    fulfillRandomWords()                     │
    │                 │                           │
    │                 ▼                           │
    │           RESOLVED                          │
    │         (winner known)                      │
    │                 │                           │
    │    finalizeDrawing()                        │
    │                 │                           │
    └─────────────────┘  (starts next drawing)
```

### 11.2 Ticket Lifecycle

```
    buyTicket()
        │
        ▼
    ACTIVE ──────────────────────┐
    (in play for current drawing) │
        │                         │
    drawing resolves              │
        │                         │
        ├── canvasHash == winningHash ──► WINNER ──► claimPrize() ──► CLAIMED
        │                                                              
        └── canvasHash != winningHash ──► LOSER ──► burnTicket() ──► BURNED (+ 0.1 LUCK)
                                            │
                                            └──► (keep as collectible, do nothing)
```

### 11.3 Timing Diagram (single drawing)

```
Day 0              Day 12           Day 14        Day 14+
│                  │                │             │
│◄── OPEN ────────►│◄── CLOSED ───►│◄─ VRF ─►│◄── RESOLVED
│                  │                │             │
│  tickets on      │ 2h cutoff     │ trigger     │ claim/burn
│  sale            │ no more       │ drawing     │ next drawing
│                  │ tickets       │ + VRF req   │ starts
```

---

## 12. Invariants

**These MUST hold at all times. Test every one.**

### 12.1 Financial Invariants

```pseudocode
// INV-1: Total USDC in Alchemix >= cumulative deposits
// (Alchemix never returns principal, it stays as collateral)
alchemist.totalValue(address(luckyPotion)) >= 0
// NOTE: Value may fluctuate with yield token price. Should be approximately totalUSDCDeposited.

// INV-2: Total LUCK supply = tickets minted * LUCK_PER_TICKET + tickets burned * BURN_LUCK_REWARD
luckToken.totalSupply() == (totalTicketsSold * LUCK_PER_TICKET) + (totalTicketsBurned * BURN_LUCK_REWARD)

// INV-3: alUSD distribution is exhaustive (no alUSD stuck in coordinator)
// After triggerDrawing(), LuckyPotion should hold 0 alUSD
// All minted alUSD goes to: opsMultisig OR luckStaking OR prizeVault
alusd.balanceOf(address(luckyPotion)) == 0  // (after distribution, before next drawing)

// INV-4: Prize vault balance >= sum of unclaimed prizes
// For all resolved drawings with winners:
//   sum(allocated - claimed) <= alusd.balanceOf(prizeVault)
// Plus rolledOverBalance

// INV-5: Staking rewards are fully backed
// luckStaking contract holds enough alUSD to pay all pending rewards
// alusd.balanceOf(luckStaking) >= sum(pendingRewards(user)) for all stakers

// INV-6: No double claims
// For each ticketId: ticketClaimed[id] can only transition false → true, never back
// For each ticketId: ticketBurned[id] can only transition false → true, never back
// A ticket cannot be both claimed AND burned

// INV-7: Ops allocation never exceeds 2%
// Per drawing: opsAmount <= (mintable * 200) / 10000
```

### 12.2 Drawing Invariants

```pseudocode
// INV-8: Drawing state only moves forward
// OPEN → CLOSED → PENDING_VRF → RESOLVED (never backwards)

// INV-9: Ticket count consistency
// drawings[id].totalTickets == sum(hashTicketCount[id][h]) for all h

// INV-10: Hash ticket count matches array length
// For all drawingId, hash: hashTicketCount[id][h] == hashTicketIds[id][h].length

// INV-11: Winner count matches hash count
// If drawing is RESOLVED: winnerCount == hashTicketCount[drawingId][winningHash]

// INV-12: No tickets registered after close
// All tickets in hashTicketIds[drawingId] have purchaseTime <= drawings[drawingId].closeTime

// INV-13: Exactly one active drawing at a time
// currentDrawingId always points to the most recent OPEN or CLOSED drawing
// Previous drawings must all be RESOLVED
```

### 12.3 Token Invariants

```pseudocode
// INV-14: TicketNFT.ownerOf(id) is valid for all non-burned tickets
// Burned tickets revert on ownerOf() (standard ERC-721 burn behavior)

// INV-15: LuckToken total supply only increases (no burning mechanism for LUCK itself)
// LUCK supply is monotonically increasing

// INV-16: Canvas data integrity
// For all tickets: computeCanvasHash(ticket.canvasData) == ticket.canvasHash
// (Hash stored at mint time must match recomputation)
```

---

## 13. Error Conditions

```pseudocode
// ──── Ticket Purchase Errors ────
error NotInitialized()                          // initialize() not called yet
error ProtocolPaused()                          // Emergency pause active
error DrawingNotOpen()                          // Current drawing not in OPEN state
error TicketSalesClosed()                       // Past closeTime
error InvalidCanvasData()                       // canvasData.length != 1024
error InsufficientUSDCAllowance()               // User didn't approve enough USDC
error BatchTooLarge()                           // >100 tickets in one tx

// ──── Drawing Errors ────
error DrawingNotReady()                         // Too early to trigger drawing
error DrawingAlreadyTriggered()                 // VRF already requested
error VRFRequestFailed()                        // Chainlink VRF call reverted
error DrawingNotResolved()                      // Trying to finalize before VRF callback

// ──── Claim Errors ────
error NotTicketOwner()                          // msg.sender != ownerOf(ticketId)
error TicketAlreadyClaimed()                    // Double claim attempt
error TicketNotWinner()                         // canvasHash != winningHash
error DrawingHasNoWinner()                      // No matching tickets

// ──── Burn Errors ────
error TicketAlreadyBurned()                     // Double burn attempt
error CannotBurnWinningTicket()                 // Must claim, not burn
error CannotBurnActiveTicket()                  // Drawing not yet resolved

// ──── Staking Errors ────
error ZeroAmount()                              // Trying to stake/unstake 0
error InsufficientStake()                       // Unstaking more than staked
error NoPendingRewards()                        // Nothing to claim

// ──── Admin Errors ────
error AlreadyInitialized()                      // initialize() called twice
error ZeroAddress()                             // Setting critical address to 0x0
error CannotRescueProtocolToken()               // Trying to rescue USDC/alUSD/LUCK
```

---

## 14. Events

```pseudocode
// ──── Ticket Events ────
event TicketPurchased(address indexed buyer, uint256 indexed ticketId, uint256 indexed drawingId, uint16 canvasHash)
event BatchTicketsPurchased(address indexed buyer, uint256[] ticketIds, uint256 indexed drawingId)
event TicketBurned(address indexed burner, uint256 indexed ticketId, uint256 indexed drawingId, uint256 luckReward)

// ──── Drawing Events ────
event DrawingStarted(uint256 indexed drawingId, uint256 openTime)
event TicketSalesClosed(uint256 indexed drawingId, uint256 totalTickets)
event DrawingTriggered(uint256 indexed drawingId, uint256 vrfRequestId)
event DrawingResolved(uint256 indexed drawingId, uint16 winningHash, uint256 winnerCount)
event DrawingFinalized(uint256 indexed drawingId, uint16 winningHash, bool hasWinner, uint256 winnerCount)

// ──── Prize Events ────
event PrizeClaimed(address indexed winner, uint256 indexed ticketId, uint256 indexed drawingId, uint256 amount)
event PrizeDeposited(uint256 indexed drawingId, uint256 amount)
event PrizeRolledOver(uint256 indexed drawingId, uint256 amount)
event RolloverApplied(uint256 indexed newDrawingId, uint256 amount)
event PrizeResolved(uint256 indexed drawingId, uint16 winningHash, uint256 winnerCount, uint256 totalPrize)

// ──── Staking Events ────
event Staked(address indexed user, uint256 amount)
event Unstaked(address indexed user, uint256 amount)
event RewardsClaimed(address indexed user, uint256 amount)
event RewardsAdded(uint256 amount, uint256 newAccRewardPerShare)

// ──── Distribution Events ────
event AlUSDDistributed(uint256 indexed drawingId, uint256 totalMinted, uint256 ops, uint256 staking, uint256 prize)

// ──── Admin Events ────
event Initialized(uint256 firstDrawingId)
event PauseToggled(bool paused)
event OpsMultisigUpdated(address newOps)
event MinterUpdated(address newMinter)

// ──── NFT Events ────
event TicketMinted(uint256 indexed tokenId, address indexed to, uint256 indexed drawingId, uint16 canvasHash)
// Plus standard ERC-721 Transfer events
```

---

## 15. Access Control

```
┌─────────────────────────────────────────────────────────────────┐
│                        ACCESS MATRIX                            │
├──────────────────────┬──────────────────────────────────────────┤
│ Function             │ Who can call                             │
├──────────────────────┼──────────────────────────────────────────┤
│ buyTicket()          │ Anyone (public)                          │
│ buyTickets()         │ Anyone (public)                          │
│ triggerDrawing()     │ Anyone (permissionless after drawTime)   │
│ finalizeDrawing()    │ Anyone (permissionless after VRF)        │
│ claimPrize()         │ Ticket owner only                        │
│ burnTicket()         │ Ticket owner only                        │
│ stake()              │ Anyone with LUCK balance                 │
│ unstake()            │ Anyone with staked LUCK                  │
│ claimRewards()       │ Anyone with pending rewards              │
├──────────────────────┼──────────────────────────────────────────┤
│ initialize()         │ Owner (deployer) — one-time only         │
│ setPaused()          │ Owner                                    │
│ setOpsMultisig()     │ Owner                                    │
│ rescueToken()        │ Owner                                    │
├──────────────────────┼──────────────────────────────────────────┤
│ LuckToken.mint()     │ LuckyPotion only (minter role)           │
│ TicketNFT.mint()     │ LuckyPotion only (coordinator)           │
│ TicketNFT.burn()     │ LuckyPotion only (coordinator)           │
│ PrizeVault.*()       │ LuckyPotion only (coordinator)           │
│ DrawingManager.*()   │ LuckyPotion only (coordinator)           │
│ LuckStaking.add..()  │ LuckyPotion only (coordinator)           │
├──────────────────────┼──────────────────────────────────────────┤
│ VRF callback         │ Chainlink VRF Coordinator only           │
└──────────────────────┴──────────────────────────────────────────┘
```

**Critical: The opsMultisig CANNOT:**
- Drain prize vault
- Pause/unpause (unless also the owner)
- Mint LUCK
- Modify drawings

**Owner powers are LIMITED to:**
- Initialize (one-time)
- Emergency pause
- Update opsMultisig address
- Rescue non-protocol tokens

**Owner CANNOT:**
- Drain prize vault
- Mint arbitrary LUCK
- Change drawing outcomes
- Modify ticket data

---

## 16. Deployment Sequence

```pseudocode
// Step 1: Deploy LuckyPotion with all config
// (Sub-contracts are deployed in constructor)
luckyPotion = new LuckyPotion(
    alchemistV3,        // Alchemix V3 address on Arbitrum
    usdc,               // USDC address on Arbitrum
    alusd,              // alUSD address on Arbitrum
    yieldToken,         // Yield vault token address
    opsMultisig,        // Ops multisig address
    vrfCoordinator,     // Chainlink VRF coordinator on Arbitrum
    vrfSubscriptionId,  // Pre-funded VRF subscription
    vrfKeyHash          // Gas lane key hash
)

// Step 2: Fund Chainlink VRF subscription
// Add luckyPotion.drawingManager() as consumer to VRF subscription
// Ensure subscription has sufficient LINK balance

// Step 3: Approve Alchemix
// LuckyPotion needs to be a valid depositor in AlchemistV3
// Check if AlchemistV3 has any whitelist/approval requirements

// Step 4: Verify all sub-contract addresses
ASSERT luckyPotion.ticketNFT() != address(0)
ASSERT luckyPotion.luckToken() != address(0)
ASSERT luckyPotion.luckStaking() != address(0)
ASSERT luckyPotion.prizeVault() != address(0)
ASSERT luckyPotion.drawingManager() != address(0)

// Step 5: Verify cross-references
ASSERT LuckToken(luckyPotion.luckToken()).minter() == address(luckyPotion)
ASSERT TicketNFT(luckyPotion.ticketNFT()).coordinator() == address(luckyPotion)
ASSERT PrizeVault(luckyPotion.prizeVault()).coordinator() == address(luckyPotion)
ASSERT DrawingManager(luckyPotion.drawingManager()).coordinator() == address(luckyPotion)
ASSERT LuckStaking(luckyPotion.luckStaking()).coordinator() == address(luckyPotion)

// Step 6: Initialize (starts first drawing)
luckyPotion.initialize()

// Step 7: Verify first drawing is OPEN
Drawing memory d = luckyPotion.getCurrentDrawing()
ASSERT d.state == DrawingState.OPEN
ASSERT d.id == 1

// Step 8: Smoke test
// Buy a test ticket with $5 USDC
// Verify: NFT minted, LUCK received, USDC in Alchemix, hash registered
```

---

## 17. Upgrade Strategy

**V1 is NOT upgradeable.** Rationale: Prize vault must be trustless. Upgradeability = admin can change prize logic = trust assumption.

**If upgrades needed:**

1. Deploy new LuckyPotion v2
2. New contracts handle new drawings
3. Old PrizeVault continues to service existing claims
4. `LuckToken.setMinter(newLuckyPotion)` migrates LUCK minting
5. Alchemix position stays with old contract (yield still flows)
6. New contract uses a new Alchemix position

**Future consideration:** Could use a proxy pattern for non-critical components (DrawingManager, TicketNFT metadata) while keeping PrizeVault immutable.

---

## 18. Test Plan

### 18.1 Unit Tests

```pseudocode
// ──── LuckToken Tests ────
test_mint_onlyMinter()
    // Non-minter cannot mint
test_mint_updatesBalance()
    // Minting increases balance and totalSupply
test_transfer_standard()
    // Standard ERC-20 transfer works
test_setMinter_onlyCurrentMinter()
    // Only current minter can change minter

// ──── TicketNFT Tests ────
test_mint_onlyCoordinator()
    // Non-coordinator cannot mint
test_mint_storesCanvasData()
    // Canvas data is retrievable after mint
test_mint_incrementsTokenId()
    // Token IDs are sequential starting from 1
test_burn_onlyCoordinator()
    // Non-coordinator cannot burn
test_burn_removesOwnership()
    // ownerOf() reverts after burn
test_tokenURI_returnsValidJSON()
    // tokenURI returns valid base64 JSON with SVG image
test_transfer_works()
    // Standard ERC-721 transfer between addresses
test_invalidCanvasData_reverts()
    // Canvas data != 1024 bytes reverts

// ──── LuckStaking Tests ────
test_stake_transfersLUCK()
    // LUCK moves from user to contract
test_stake_updatesUserInfo()
    // stakedAmount and rewardDebt updated correctly
test_unstake_returnsLUCK()
    // LUCK moves from contract back to user
test_unstake_claimsPending()
    // Pending rewards auto-claimed on unstake
test_claimRewards_transfersAlUSD()
    // Correct alUSD amount transferred
test_addRewards_updatesAccPerShare()
    // accRewardPerShare increases correctly
test_addRewards_zeroStakers()
    // Rewards held when no stakers (orphaned)
test_multipleStakers_fairDistribution()
    // Two stakers with equal stake get equal rewards
test_stakeAfterRewards_noFreeRewards()
    // New staker after rewards are added doesn't get historical rewards
test_rewardDebt_calculatedCorrectly()
    // MasterChef accounting is exact (within 1 wei)

// ──── PrizeVault Tests ────
test_deposit_onlyCoordinator()
test_deposit_increasesAllocation()
test_resolveDrawing_noWinner_rollsOver()
test_resolveDrawing_withWinner_setsState()
test_applyRollover_addsToNewDrawing()
test_claimPrize_splitsEvenly()
    // 3 winners split equally
test_claimPrize_dustHandling()
    // Rounding dust stays in vault
test_doubleClaimPrevented()
    // Handled by coordinator, but vault should not overpay

// ──── DrawingManager Tests ────
test_startDrawing_setsTimings()
test_registerTicket_incrementsCounts()
test_registerTicket_afterClose_reverts()
test_closeTicketSales_beforeTime_reverts()
test_triggerDrawing_beforeDrawTime_reverts()
test_triggerDrawing_requestsVRF()
test_fulfillRandomWords_setsWinningHash()
test_fulfillRandomWords_countsWinners()
test_fulfillRandomWords_noWinner()
test_getHashPopularity_accurate()
test_getWinningTickets_returnsCorrectIds()

// ──── Canvas Hash Tests ────
test_computeCanvasHash_deterministic()
    // Same input → same output, 100 iterations
test_computeCanvasHash_uniformDistribution()
    // 10000 random canvases → chi-squared test on 16-bit distribution
test_computeCanvasHash_allZeros()
    // Known input → known output (regression test)
test_computeCanvasHash_allOnes()
    // Known input → known output (regression test)
test_computeCanvasHash_invalidLength_reverts()
test_computeCanvasHash_matchesFrontend()
    // Compare Solidity output with JavaScript implementation for 1000 samples
```

### 18.2 Integration Tests

```pseudocode
// ──── Full Lifecycle Test ────
test_fullLifecycle_buyTicket_triggerDrawing_claimPrize():
    // 1. Initialize protocol
    // 2. Buy 10 tickets with known canvas data
    // 3. Warp time past drawing period
    // 4. Trigger drawing
    // 5. Mock VRF callback with a hash matching one of the tickets
    // 6. Claim prize
    // 7. Verify alUSD received
    // 8. Verify next drawing started

test_fullLifecycle_noWinner_rollover():
    // 1. Buy tickets for drawing 1
    // 2. Resolve drawing 1 with hash matching no tickets
    // 3. Verify rollover amount
    // 4. Buy tickets for drawing 2
    // 5. Trigger drawing 2
    // 6. Verify prize vault includes rollover

test_fullLifecycle_multipleWinners_splitPot():
    // 1. Buy 5 tickets, 3 of which produce same canvasHash
    // 2. Resolve drawing with that hash as winner
    // 3. All 3 claim
    // 4. Verify each gets 1/3 of prize

test_fullLifecycle_burnForLuck():
    // 1. Buy ticket, lose drawing
    // 2. Burn ticket
    // 3. Verify 0.1 LUCK received
    // 4. Verify NFT burned (ownerOf reverts)

test_fullLifecycle_stakingRewards():
    // 1. Buy tickets (receive LUCK)
    // 2. Stake LUCK
    // 3. Trigger drawing (distributes alUSD to staking)
    // 4. Claim staking rewards
    // 5. Verify alUSD received = 15% of mint × user's share

test_alchemixIntegration_depositAndMint():
    // 1. Fork Arbitrum mainnet (or use Alchemix test deployment)
    // 2. Buy 100 tickets ($500 USDC)
    // 3. Verify USDC deposited in Alchemix
    // 4. Trigger drawing
    // 5. Verify max mint (~$450 alUSD at 90% LTV)
    // 6. Verify distribution: 2% ops, 15% staking, 83% prize

test_multiDrawing_prizeGrowth():
    // Simulate 5 drawings with no winner
    // Verify prize vault balance grows each drawing
    // Verify rollover accounting is correct across all drawings
```

### 18.3 Fuzz Tests

```pseudocode
// ──── Fuzz: Canvas Hash ────
fuzz_canvasHash_alwaysValid(bytes calldata randomCanvas):
    IF randomCanvas.length == 1024:
        uint16 hash = computeCanvasHash(randomCanvas)
        ASSERT hash < 65536
        // Re-compute should give same result
        ASSERT computeCanvasHash(randomCanvas) == hash

// ──── Fuzz: Staking Math ────
fuzz_staking_noFundsLocked(
    uint256 stakeAmount,
    uint256 rewardAmount,
    uint256 unstakeAmount
):
    // Bound inputs
    stakeAmount = bound(stakeAmount, 1, 1e24)
    rewardAmount = bound(rewardAmount, 0, 1e24)
    unstakeAmount = bound(unstakeAmount, 0, stakeAmount)

    stake(stakeAmount)
    addRewards(rewardAmount)
    unstake(unstakeAmount)

    // User can always withdraw remaining stake
    ASSERT luckToken.balanceOf(address(staking)) >= (stakeAmount - unstakeAmount)

// ──── Fuzz: Prize Distribution ────
fuzz_prizeDistribution_exhaustive(uint256 mintAmount):
    mintAmount = bound(mintAmount, 1, 1e24)

    uint256 ops = (mintAmount * 200) / 10000
    uint256 staking = (mintAmount * 1500) / 10000
    uint256 prize = mintAmount - ops - staking

    // All alUSD accounted for
    ASSERT ops + staking + prize == mintAmount

    // Ratios correct (within rounding)
    ASSERT ops <= (mintAmount * 201) / 10000      // Never more than 2% + 1 wei
    ASSERT staking <= (mintAmount * 1501) / 10000  // Never more than 15% + 1 wei

// ──── Fuzz: Multi-Winner Split ────
fuzz_prizeSplit_fair(uint256 totalPrize, uint256 winnerCount):
    totalPrize = bound(totalPrize, 1, 1e24)
    winnerCount = bound(winnerCount, 1, 1000)

    uint256 perWinner = totalPrize / winnerCount
    uint256 totalPaid = perWinner * winnerCount
    uint256 dust = totalPrize - totalPaid

    // Dust is always less than winnerCount
    ASSERT dust < winnerCount
    // Each winner gets the same amount
    ASSERT perWinner * winnerCount + dust == totalPrize
```

### 18.4 Invariant Tests

```pseudocode
// Run with Foundry invariant testing (stateful fuzzing)
// Handler contract calls: buyTicket, triggerDrawing, claimPrize, burnTicket,
//                         stake, unstake, claimRewards in random order

invariant_luckSupplyConsistency():
    ASSERT luckToken.totalSupply() ==
        (totalTicketsSold * LUCK_PER_TICKET) + (totalTicketsBurned * BURN_LUCK_REWARD)

invariant_noAlUSDStuckInCoordinator():
    // After any triggerDrawing, coordinator holds 0 alUSD
    // (Between drawings, small amounts may accumulate — that's ok)
    IF lastActionWas == "triggerDrawing":
        ASSERT alusd.balanceOf(coordinator) == 0

invariant_prizeVaultSolvency():
    // PrizeVault always has enough alUSD to cover unclaimed prizes
    uint256 totalUnclaimed = 0
    FOR each resolved drawing with winners:
        totalUnclaimed += (allocated - claimed)
    ASSERT alusd.balanceOf(prizeVault) >= totalUnclaimed

invariant_stakingSolvency():
    // Staking contract always has enough alUSD for pending rewards
    uint256 totalPending = 0
    FOR each staker:
        totalPending += pendingRewards(staker)
    ASSERT alusd.balanceOf(luckStaking) >= totalPending

invariant_drawingStateOnlyForward():
    FOR each drawing:
        IF drawing was RESOLVED at any point:
            ASSERT drawing is still RESOLVED

invariant_ticketHashConsistency():
    FOR each ticket:
        ASSERT computeCanvasHash(ticket.canvasData) == ticket.canvasHash

invariant_noDoubleClaimOrBurn():
    FOR each ticket:
        ASSERT !(ticketClaimed[id] AND ticketBurned[id])
```

---

## 19. Gas Estimates

**Target chain: Arbitrum One (L2 — gas is cheap)**

| Operation | Estimated Gas | Notes |
|-----------|-------------|-------|
| buyTicket() | ~250,000 | USDC transfer + Alchemix deposit + NFT mint + LUCK mint + hash registration. Canvas data storage dominates (~1024 bytes = 32 slots = ~640K gas on L1, much cheaper on Arb) |
| buyTickets(10) | ~1,500,000 | Batched — single USDC transfer + single Alchemix deposit, 10× NFT mints |
| triggerDrawing() | ~300,000 | Alchemix mint + 3 alUSD transfers + VRF request |
| fulfillRandomWords() | ~100,000 | VRF callback, hash lookup, state update |
| finalizeDrawing() | ~150,000 | PrizeVault resolution + start new drawing |
| claimPrize() | ~80,000 | Ownership check + alUSD transfer |
| burnTicket() | ~100,000 | Ownership check + NFT burn + LUCK mint |
| stake() | ~100,000 | LUCK transfer + state update + auto-claim |
| unstake() | ~120,000 | Auto-claim + LUCK transfer + state update |
| claimRewards() | ~60,000 | alUSD transfer + state update |
| computeCanvasHash() | ~5,000 | keccak256(1024 bytes) — view only |
| tokenURI() | ~500,000+ | On-chain SVG rendering — view only (no gas cost for reads) |

**Canvas data storage cost (key concern):**
- 1024 bytes = 32 storage slots = ~640,000 gas on mainnet (~$3-10 at normal gas)
- On Arbitrum: ~10-50× cheaper = ~$0.05-0.20 per ticket
- Acceptable for $5 ticket price

**Alternative:** Store canvas hash on-chain, full canvas data on Arweave/IPFS. Reduces buyTicket to ~100K gas. Tradeoff: tokenURI can't render SVG without external data.

**Recommendation:** Store on-chain for V1 on Arbitrum (cheap enough). Revisit if deploying to mainnet.

---

## 20. Frontend Integration Notes

### 20.1 Canvas Editor

```pseudocode
// HTML5 Canvas, 64×64 grid, 4-color palette
// Each cell is clickable, cycles through colors on click
// Grid displayed at 512×512px (8× zoom for crisp pixels)

state:
    pixels[64][64] : uint2    // 0-3 color index
    palette: ["#0f380f", "#306230", "#8bac0f", "#9bbc0f"]  // Game Boy green

function onCellClick(x, y):
    pixels[x][y] = (pixels[x][y] + 1) % 4

function randomize():
    FOR x = 0 TO 63:
        FOR y = 0 TO 63:
            pixels[x][y] = random(0, 3)

function exportCanvasData() -> Uint8Array(1024):
    // Pack pixels into bytes: 4 pixels per byte (2 bits each)
    data = new Uint8Array(1024)
    FOR y = 0 TO 63:
        FOR x = 0 TO 63 STEP 4:
            byteIndex = (y * 64 + x) / 4
            byte = (pixels[x][y] << 6) | (pixels[x+1][y] << 4) |
                   (pixels[x+2][y] << 2) | pixels[x+3][y]
            data[byteIndex] = byte
    return data

function computeHash(canvasData: Uint8Array) -> uint16:
    fullHash = keccak256(canvasData)
    return Number(BigInt(fullHash) & 0xFFFFn)
```

### 20.2 Hash Popularity Display

```pseudocode
// Show during ticket purchase:
// "Your hash: 0xA3F2 — 3 other tickets share this hash"
// Color code: green (unique) → yellow (2-5) → red (10+)

function getHashPopularity(canvasHash) -> uint256:
    return LuckyPotion.getHashPopularity(canvasHash)

// Display as: "Crowded Zone ⚠️" or "Uncharted Territory 🏴‍☠️"
```

### 20.3 Drawing Reveal Animation

```pseudocode
// After VRF resolves:
// 1. Show blank 64×64 canvas
// 2. Fill in winning image pixel by pixel (random order, ~30 seconds)
// 3. Show final winning hash
// 4. Highlight matching tickets (if any)
// 5. Confetti for winners

// Data source: DrawingManager.getDrawing(drawingId).winningHash
// NOTE: The winning hash doesn't correspond to a specific image!
// It's just a 16-bit number. The "reveal animation" is purely cosmetic.
// Could generate a deterministic visual from the hash for dramatic effect.
```

### 20.4 Required Contract Reads

```pseudocode
// Dashboard data:
LuckyPotion.protocolStats()              // All key metrics in one call
LuckyPotion.getCurrentDrawing()          // Current drawing state + timing
LuckyPotion.getHashPopularity(hash)      // For canvas editor
LuckyPotion.getTicketInfo(ticketId)      // Full ticket state
LuckStaking.pendingRewards(address)      // User's claimable alUSD
LuckStaking.userInfo(address)            // User's staked LUCK
PrizeVault.getPrizeInfo(drawingId)       // Prize pool details
PrizeVault.getPerWinnerAmount(drawingId) // What each winner gets
DrawingManager.getWinningTickets(drawingId) // All winning ticket IDs
```

### 20.5 Required Contract Writes

```pseudocode
// User actions:
USDC.approve(luckyPotion, amount)        // Before buying tickets
LuckyPotion.buyTicket(canvasData)        // Buy single ticket
LuckyPotion.buyTickets(canvasDataArray)  // Buy batch
LuckyPotion.claimPrize(ticketId)         // Claim winning prize
LuckyPotion.burnTicket(ticketId)         // Burn losing ticket for LUCK
LUCK.approve(luckStaking, amount)        // Before staking
LuckStaking.stake(amount)               // Stake LUCK
LuckStaking.unstake(amount)             // Unstake LUCK
LuckStaking.claimRewards()              // Claim alUSD rewards

// Permissionless (anyone/keeper):
LuckyPotion.triggerDrawing()             // After draw time
LuckyPotion.finalizeDrawing(drawingId)   // After VRF resolves
```

---

## Appendix A: Deployment Addresses (TBD)

```
Chain: Arbitrum One (42161)

USDC:           0xaf88d065e77c8cC2239327C5EDb3A432268e5831
alUSD:          TBD (Alchemix V3 Arbitrum deployment)
AlchemistV3:    TBD
yieldToken:     TBD
VRF Coordinator: 0x41034678D6C633D8a95c75e1138A360a28bA15d1 (Chainlink Arb)
VRF Key Hash:   TBD (depends on gas lane selection)

LuckyPotion:    TBD
TicketNFT:      TBD
LuckToken:      TBD
LuckStaking:    TBD
PrizeVault:     TBD
DrawingManager: TBD
```

---

## Appendix B: Glossary

| Term | Definition |
|------|-----------|
| Canvas | 64×64 pixel grid with 4-color palette. The user's ticket art. |
| Canvas Hash | 16-bit value derived from keccak256 of canvas data. The lottery "number." |
| Drawing | One complete lottery cycle: open → close → VRF → resolve. |
| Megapot | The accumulated prize vault. Rolls over between drawings. |
| LUCK | ERC-20 token. 1 minted per ticket. Stakeable for alUSD yield. |
| Rollover | When no winner, entire prize allocation carries to next drawing. |
| Hash Popularity | Number of tickets sharing the same 16-bit canvas hash in a drawing. |
| Burn-for-LUCK | Destroying a losing ticket NFT in exchange for 0.1 LUCK. |

---

*End of Technical Specification*
