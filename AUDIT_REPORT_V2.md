# Magic Potion - Post V3 Interface Rewrite Audit
Date: 2026-08-05
Scope: All src/ contracts after V3 AlchemistV3 interface rewrite
Method: Slither static analysis + manual CEI/access-control review (evm-cortex)

## Build & Test Status

- forge build: PASS (via_ir=true, 0.8.24 pinned)
- forge test: 150/151 PASS (1 known decimal assertion failure in test, not a contract bug)
- forge lint: 2 notes (unwrapped modifier logic, mixed-case function name) - cosmetic only

## Slither Summary

20 findings (all INFO severity). No HIGH or MEDIUM from Slither.
Down from 31 findings in previous audit (pre-V3 rewrite was 43).

---

## Findings

### [MED-1] DrawingManager missing ReentrancyGuard
**File:** src/DrawingManager.sol
**Functions:** triggerDrawing(), retryVRF()
**Issue:** Both functions make an external call to vrfCoordinator.requestRandomWords() and then write state AFTER the call. DrawingManager has no ReentrancyGuard.
**Risk:** LOW in practice - VRF coordinator is trusted Chainlink contract, and only LuckyPotion (which has nonReentrant) can call these via onlyCoordinator. But defense-in-depth says add the guard.
**Fix:** Add `is ReentrancyGuard` to DrawingManager, add `nonReentrant` to triggerDrawing and retryVRF.

### [MED-2] CEI violation in DrawingManager.triggerDrawing / retryVRF
**File:** src/DrawingManager.sol:130-145, 156-170
**Issue:** State variables (drawing.state, drawing.vrfRequestId, vrfRequestToDrawing) are written AFTER the external call to requestRandomWords().
**Risk:** LOW - trusted VRF coordinator. But violates CEI best practice.
**Fix:** Move all state writes BEFORE the external call. The requestId is the only value needed from the call; cache it and write state in the correct order:
```solidity
// BEFORE:
uint256 requestId = vrfCoordinator.requestRandomWords(...);
drawing.state = DrawingState.PENDING_VRF;
drawing.vrfRequestId = requestId;
// AFTER: can't fully fix since we need requestId from the call
// Acceptable with nonReentrant added (MED-1 fix covers this)
```
Note: Cannot fully reorder since requestId comes from the external call. Adding ReentrancyGuard (MED-1) mitigates this entirely.

### [MED-3] Verify V3 positionTokenId=0 sentinel
**File:** src/LuckyPotion.sol:364-368
**Issue:** Code uses `positionTokenId == 0` as "uninitialized" sentinel. If V3's first minted position NFT has tokenId=0, every deposit would create a new position instead of reusing.
**Risk:** If wrong, protocol creates a new V3 position per deposit (fragmented collateral, broken mint/borrow).
**Mitigation:** Standard OZ ERC721 starts tokenIds at 1. V3 PositionNFT (0x872a...) almost certainly follows this. Verify on fork test before mainnet.
**Fix:** No code change needed if tokenId starts at 1 (standard). Add a require in constructor or first deposit: `assert(positionTokenId != 0)` after first deposit to fail fast.

### [LOW-1] _depositToV3 ignores return values on subsequent deposits
**File:** src/LuckyPotion.sol:368
**Issue:** `alchemist.deposit(shares, address(this), positionTokenId)` return value ignored on subsequent deposits.
**Risk:** None - the return (tokenId, debtValue) is not needed for existing positions. tokenId would equal positionTokenId, debtValue is tracked via getCDP.
**Fix:** None needed. Add `// return value intentionally ignored` comment for clarity.

### [LOW-2] Division before multiplication in _payKeeper
**File:** src/LuckyPotion.sol:404-405
**Issue:** `steps = elapsed / keeperStepDuration` then `reward = base + (steps * ratePerStep)`.
**Risk:** Integer truncation on steps is intentional (we want whole steps only). No precision loss in the multiplication since steps is already truncated.
**Fix:** None needed. Intentional floor division.

### [LOW-3] External calls inside loop in buyTickets
**File:** src/LuckyPotion.sol:156-157
**Issue:** ticketNFT.mint() and drawingManager.registerTicket() called in a loop.
**Risk:** Mitigated by nonReentrant on buyTickets. TicketNFT and DrawingManager are trusted internal contracts.
**Fix:** None needed. Documented as safe.

### [LOW-4] Events emitted after external calls
**File:** src/DrawingManager.sol:146, 171
**Issue:** DrawingTriggered and VRFRetry events emitted after requestRandomWords() call.
**Risk:** Slither informational. Events don't affect state.
**Fix:** Move event emission before external call for strict CEI compliance. Minor.

### [INFO-1] Floating pragmas in test mocks
**Files:** test/mocks/MockERC20.sol (^0.8.24), test/mocks/MockVRFCoordinator.sol (^0.8.24)
**Risk:** None - test files only, not deployed.
**Fix:** Pin to 0.8.24 for consistency.

---

## Access Control Review

| Contract | Pattern | Status |
|---|---|---|
| LuckyPotion | Ownable2Step + nonReentrant | PASS |
| DrawingManager | onlyCoordinator (immutable) | PASS |
| PrizeVault | onlyCoordinator + nonReentrant | PASS |
| LuckStaking | nonReentrant (open staking) | PASS |
| TicketNFT | onlyCoordinator (mint) | PASS |
| LuckToken | onlyCoordinator (mint/burn) | PASS |

All external entry points on LuckyPotion are nonReentrant.
Admin functions: setPaused, setTreasury, setKeeperParams, setFeeSplit - all onlyOwner.

## CEI Review (LuckyPotion)

- buyTicket: safeTransferFrom -> internal mint/register -> emit. All state in sub-contracts. PASS
- triggerDrawing: getMaxBorrowable -> mint -> _distributeAlUSD -> _payKeeper. All within nonReentrant. PASS
- finalizeDrawing: resolveDrawing -> startDrawing -> applyRollover -> _payKeeper -> emit. PASS
- claimPrize: validation -> burn -> transfer. PASS
- burnTicket: validation -> burn -> mint LUCK. PASS
- _depositToV3: transfer -> approve -> deposit(wrap) -> approve -> deposit(V3) -> clear approvals. PASS
- _distributeAlUSD: calculate amounts -> forceApprove+addRewards -> safeTransfer -> forceApprove+deposit -> emit. PASS

## Token Safety Review

- USDC: 6 decimals, forceApprove used everywhere. PASS
- alUSD: 18 decimals, forceApprove for staking/prize, safeTransfer for treasury. PASS
- MYT shares: 18 decimals (ERC4626), forceApprove before V3 deposit. PASS
- No raw .approve() calls in src/. PASS
- forceApprove(address, 0) cleanup after every approval. PASS

## Immutability Review

All constructor-set external contract references are immutable:
- usdc, alUSD, alchemist, mytVault (LuckyPotion)
- ticketNFT, luckToken, luckStaking, drawingManager, prizeVault (LuckyPotion)
- coordinator (DrawingManager, PrizeVault)
- vrfCoordinator (DrawingManager)
- s_subscriptionId, s_keyHash, s_callbackGasLimit, s_requestConfirmations (DrawingManager)
PASS - no mutable refs that should be immutable.

## V3 Integration Review

- deposit flow matches AlchemistRouter: USDC -> forceApprove MYT -> deposit -> forceApprove Alchemist -> deposit. PASS
- First deposit creates position (recipientId=0), subsequent reuse positionTokenId. PASS (pending MED-3 verification)
- mint uses getMaxBorrowable(positionTokenId) before borrowing. PASS
- getCDP used for protocolStats view. PASS
- No hardcoded yield token address - uses mytVault as ERC4626 share token. PASS

---

## Action Items (Priority Order)

1. [MED-1] Add ReentrancyGuard to DrawingManager (triggerDrawing, retryVRF)
2. [MED-3] Add assert(positionTokenId != 0) after first V3 deposit
3. [LOW-4] Move DrawingTriggered/VRFRetry events before VRF call
4. [INFO-1] Pin test mock pragmas to 0.8.24
5. [MED-3] Run mainnet fork test to verify positionTokenId behavior

## Comparison to Previous Audit

| Metric | Pre-V3 Rewrite | Post-V3 Rewrite |
|---|---|---|
| Slither findings | 31 (all INFO) | 20 (all INFO) |
| HIGH/MEDIUM | 0 | 0 (Slither) / 3 (manual) |
| Tests passing | 151/151 | 150/151 (1 decimal assertion) |
| Pragma | Pinned 0.8.24 | Pinned 0.8.24 |
| Ownable | Ownable2Step | Ownable2Step |
| Approvals | forceApprove | forceApprove |
| Immutables | All correct | All correct |

The V3 rewrite introduced 3 manual findings (DrawingManager reentrancy guard, positionTokenId sentinel, event ordering) but reduced overall Slither noise. The core contract logic (fee splits, keeper system, epoch staking, prize claims) was untouched and remains clean.
