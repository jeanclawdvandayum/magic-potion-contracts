# Security Audit Report: Magic Potion

## 1. Executive Summary
- **Protocol**: Magic Potion - self-repaying lottery on Alchemix V3
- **Scope**: All src/ contracts (8 files, ~1400 SLOC)
- **Methodology**: Manual review + Slither static analysis + evm-cortex ruleset
- **Tools**: Foundry 1.5.1, Slither 0.10.x, evm-cortex v1.0.0 rules
- **Findings Summary**:
  | Severity | Count |
  |----------|-------|
  | High     | 1     |
  | Medium   | 5     |
  | Low      | 8     |
  | Info     | 4     |

## 2. Findings

### [HIGH] H-1: Floating Pragma in ALL Source Files
**Severity**: High
**Type**: Security
**Location**: All `src/**/*.sol` files
**Status**: Confirmed

**Description**: Every source file uses `pragma solidity ^0.8.24;` (floating). EVM Cortex rule: "Fixed pragma, never floating. Never use `^0.8.x` in production contracts."

**Impact**: Floating pragma allows compilation with untested compiler versions. A future compiler bug could introduce vulnerabilities.

**Recommendation**: Change all to `pragma solidity 0.8.24;` (remove the `^`).

### [MEDIUM] M-1: Ownable Instead of Ownable2Step
**Severity**: Medium
**Type**: Access Control
**Location**: `src/LuckyPotion.sol:24`
**Status**: Confirmed

**Description**: Uses `Ownable` instead of `Ownable2Step`. EVM Cortex rule: "Use Ownable2Step over Ownable (prevents accidental ownership transfer)."

**Impact**: Owner can accidentally transfer to wrong address, permanently bricking the protocol with no recovery.

**Recommendation**: Import `Ownable2Step` and use it instead.

### [MEDIUM] M-2: usdc.approve() Not Using SafeERC20
**Severity**: Medium
**Type**: Token Safety
**Location**: `src/LuckyPotion.sol:135, 164, 384, 395`
**Status**: Confirmed

**Description**: Uses raw `.approve()` on USDC and alUSD instead of SafeERC20's `forceApprove()`. While USDC does return bool, some tokens (USDT) don't. EVM Cortex rule: "Use SafeERC20 for ALL token transfers and approvals."

**Impact**: If the yield token or alUSD implementation changes to a non-standard ERC-20, approve could silently fail.

**Recommendation**: Use `usdc.forceApprove(address(alchemist), amount)` and `alUSD.forceApprove(...)`.

### [MEDIUM] M-3: External Calls Inside Loop (buyTickets)
**Severity**: Medium
**Type**: Reentrancy
**Location**: `src/LuckyPotion.sol:171-175`
**Status**: Acknowledged

**Description**: `buyTickets()` calls `ticketNFT.mint()` and `drawingManager.registerTicket()` in a loop. Slither flagged this. Mitigated by `nonReentrant`, but EVM Cortex audit-mindset rule says to document why it's safe.

**Impact**: Low due to ReentrancyGuard, but if guard is ever removed, this is exploitable.

**Recommendation**: Add a comment documenting that nonReentrant makes this safe.

### [MEDIUM] M-4: Coordinator Vars Should Be Immutable
**Severity**: Medium
**Type**: Gas / Security
**Location**: DrawingManager.sol:33, LuckStaking.sol:31, PrizeVault.sol:19, TicketNFT.sol:20
**Status**: Confirmed

**Description**: Slither detected that `coordinator` in all 4 sub-contracts is set once in constructor and never changed, but is not marked `immutable`. This costs an extra SLOAD (2100 gas cold, 100 warm) on every access control check.

**Impact**: Gas waste on every privileged function call. Also a security smell - mutable coordinator could be changed (though no setter exists).

**Recommendation**: Mark `coordinator` as `immutable` in all 4 contracts. Same for VRF config vars in DrawingManager.

### [MEDIUM] M-5: CEI Violation in buyTicket - Event After External Calls
**Severity**: Medium
**Type**: Security
**Location**: `src/LuckyPotion.sol:126-148`
**Status**: Confirmed

**Description**: In `buyTicket()`, the event `TicketPurchased` is emitted at line 148, AFTER all external calls (usdc.transferFrom, alchemist.deposit, ticketNFT.mint, luckToken.mint, drawingManager.registerTicket). EVM Cortex rule: "Emit events before external calls. This ensures events maintain chronological order."

**Impact**: If any external call reverts after some state changes, the event is lost. This breaks offchain indexing assumptions.

**Recommendation**: Emit events immediately after state changes, before external calls where possible. Or accept that nonReentrant makes this safe and document it.

### [LOW] L-1: Storage Packing Opportunity
**Severity**: Low
**Type**: Gas
**Location**: `src/LuckyPotion.sol:41-42, 56-69`

**Description**: `bool initialized` and `bool paused` each occupy a full 32-byte slot. `keeperBaseReward`, `keeperRatePerStep`, `keeperStepDuration`, `prizeBps`, `stakingBps`, `treasuryBps` are all uint256 but hold small values. EVM Cortex gas rule: "Pack variables into 32-byte slots."

**Recommendation**: Pack `initialized` + `paused` + `keeperStepDuration` (uint32) + BPS vars (uint16 each) into 1-2 slots.

### [LOW] L-2: No unchecked Blocks in Loops
**Severity**: Low
**Type**: Gas
**Location**: `src/LuckyPotion.sol:171`
**Description**: Loop counter `i` is bounded by `count` (array length). EVM Cortex gas rule: use `unchecked { ++i; }`.

### [LOW] L-3: Named Mapping Parameters Missing
**Severity**: Low
**Type**: Style
**Location**: All mapping declarations
**Description**: EVM Cortex style rule: `mapping(address owner => uint256 amount)` not `mapping(address => uint256)`.

### [LOW] L-4: PrizeVault Dust Accumulation
**Severity**: Low
**Type**: Math
**Location**: `src/PrizeVault.sol:96`
**Description**: `prize.allocated / prize.winnerCount` truncates. Dust accumulates in vault permanently with no recovery path.

### [LOW] L-5: No Zero-Amount Check on Keeper Reward
**Severity**: Low
**Type**: Logic
**Location**: `src/LuckyPotion.sol:407-414`
**Description**: `_payKeeper` always mints at least `keeperBaseReward` (1 LUCK). If admin sets base to 0, it still works but mints 0 tokens.

### [LOW] L-6: LuckStaking claimRewards Reverts on Zero Pending
**Severity**: Low
**Type**: UX
**Location**: `src/LuckStaking.sol:172`
**Description**: `if (pending == 0) revert NoPendingRewards()` - standard pattern but prevents idempotent calls.

### [LOW] L-7: SVGRenderer Gas-Heavy (1024 bytes onchain per ticket)
**Severity**: Low
**Type**: Gas
**Location**: `src/TicketNFT.sol:69-75, src/libraries/SVGRenderer.sol`
**Description**: Each ticket stores 1024 bytes of canvas data onchain and renders SVG via string concatenation in a loop. This is gas-intensive. EVM Cortex gas rule: "Do not use assembly unless savings >20%, but measure first." Current gas: ~4.5M per tokenURI call.

### [LOW] L-8: No Timelock on Admin Functions
**Severity**: Low
**Type**: Access Control
**Location**: `src/LuckyPotion.sol:282-318`
**Description**: `setPaused`, `setTreasury`, `setKeeperParams`, `setFeeSplit` are all `onlyOwner` with no timelock. EVM Cortex rule: "Use timelock for admin functions that affect user funds."

### [INFO] I-1 through I-4: Style notes
- I-1: `_paused` / `_treasury` params should be `paused` / `treasury` (mixedCase, no underscore prefix for public external params per cortex)
- I-2: VRF config vars (`s_subscriptionId` etc.) should be immutable
- I-3: All events are properly named and indexed - good
- I-4: Custom errors used throughout - good (meets cortex standard)

## 3. Recommendations (Priority Order)

1. **Fix floating pragmas** (H-1) - trivial, high impact
2. **Switch to Ownable2Step** (M-1) - prevents catastrophic ownership loss
3. **Use forceApprove** (M-2) - token safety
4. **Mark coordinator as immutable** (M-4) - gas + security
5. **Storage packing** (L-1) - gas savings on hot paths
6. **Add timelock or accept the risk** (L-8) - governance hygiene
7. **Fix event ordering** (M-5) - or document nonReentrant safety
8. **unchecked in loops** (L-2) - minor gas
9. **Named mapping params** (L-3) - readability
10. **Dust recovery** (L-4) - completeness
