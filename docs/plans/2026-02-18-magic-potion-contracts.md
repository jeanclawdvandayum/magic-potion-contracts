# Magic Potion Smart Contracts — Implementation Plan

> **For agents:** Each PR is a self-contained unit. Read the full spec at `~/Desktop/projects/lucky-potion/TECHNICAL_SPEC.md`. This plan breaks implementation into 8 PRs, each reviewed by two auditors (Opus + Codex). Do NOT delete branches after merge.

**Goal:** Build the full Magic Potion self-repaying lottery protocol: 6 contracts, Chainlink VRF integration, Alchemix V3 integration, comprehensive tests + invariant fuzzing.

**Architecture:** Coordinator pattern — `LuckyPotion.sol` orchestrates 5 sub-contracts (LuckToken, TicketNFT, LuckStaking, PrizeVault, DrawingManager). Single Alchemix position. MasterChef staking. Chainlink VRF V2.5 for randomness.

**Tech Stack:** Foundry (Solidity 0.8.24), OpenZeppelin 5.x, Chainlink VRF V2.5, forge-std

**Chain:** Arbitrum One (L2)

**Repo:** `jeanclawdvandayum/magic-potion-contracts`

---

## PR Dependency Graph

```
PR-01 (Foundation)
  │
  ├── PR-02 (LuckToken + LuckStaking)
  │     │
  │     └── PR-05 (LuckyPotion coordinator)
  │           │
  ├── PR-03 (TicketNFT + Canvas Hash)
  │     │     │
  │     └─────┘
  │           │
  ├── PR-04 (PrizeVault + DrawingManager)
  │     │     │
  │     └─────┘
  │           │
  │     PR-06 (Integration tests)
  │           │
  │     PR-07 (Invariant + Fuzz tests)
  │           │
  │     PR-08 (Deployment scripts + docs)
```

---

## PR-01: Foundation — Project Setup, Interfaces & Constants

**Branch:** `PR-01/foundation`
**Dependencies:** None
**Estimated effort:** Small

### What this PR does
Sets up the Foundry project properly, installs OpenZeppelin + Chainlink deps, defines all interfaces, constants, errors, and events used across the protocol. Every subsequent PR imports from here.

### Tasks

1. **Clean forge init boilerplate**
   - Delete `src/Counter.sol`, `test/Counter.t.sol`, `script/Counter.s.sol`

2. **Install dependencies**
   ```bash
   forge install OpenZeppelin/openzeppelin-contracts@v5.3.0 --no-commit
   forge install smartcontractkit/chainlink@v2.19.0 --no-commit
   ```

3. **Configure `foundry.toml`**
   ```toml
   [profile.default]
   src = "src"
   out = "out"
   libs = ["lib"]
   solc = "0.8.24"
   optimizer = true
   optimizer_runs = 200
   via_ir = false
   ffi = false

   remappings = [
       "@openzeppelin/=lib/openzeppelin-contracts/",
       "@chainlink/=lib/chainlink/contracts/",
       "forge-std/=lib/forge-std/src/"
   ]

   [profile.default.invariant]
   runs = 256
   depth = 50
   fail_on_revert = false

   [profile.default.fuzz]
   runs = 1000
   ```

4. **Create `src/interfaces/IAlchemistV3.sol`**
   - `deposit(address yieldToken, uint256 amount, address recipient) external returns (uint256)`
   - `mint(uint256 amount, address recipient) external`
   - `getMintAllowance(address account) external view returns (uint256)`
   - `totalValue(address account) external view returns (uint256)`
   - `debt(address account) external view returns (int256)`

5. **Create `src/libraries/Constants.sol`**
   All protocol constants as a library:
   - `TICKET_PRICE = 5_000_000` (6 decimals)
   - `LUCK_PER_TICKET = 1e18`
   - `BURN_LUCK_REWARD = 0.1e18`
   - `DRAWING_DURATION = 14 days`
   - `TICKET_CUTOFF = 2 hours`
   - `HASH_SPACE = 65_536`
   - `OPS_BPS = 200`, `STAKING_BPS = 1500`, `PRIZE_BPS = 8300`, `BPS_DENOMINATOR = 10_000`
   - `CANVAS_DATA_LENGTH = 1024`
   - `VRF_TIMEOUT = 24 hours`

6. **Create `src/libraries/Errors.sol`**
   All custom errors from TECHNICAL_SPEC.md §13.

7. **Create `src/libraries/Events.sol`**
   All events from TECHNICAL_SPEC.md §14.

8. **Create `src/libraries/CanvasHash.sol`**
   ```solidity
   function computeCanvasHash(bytes calldata canvasData) internal pure returns (uint16) {
       if (canvasData.length != 1024) revert InvalidCanvasData();
       return uint16(uint256(keccak256(canvasData)) & 0xFFFF);
   }
   ```

9. **Write basic tests for CanvasHash**
   - Deterministic (same input → same output)
   - All-zeros known value
   - All-ones known value
   - Invalid length reverts
   - Output < 65536

10. **Commit and push**

### Review notes for auditors
- Focus on: constants correctness, interface completeness vs spec, hash function properties
- Verify BPS sum to 10000
- Verify canvas encoding matches spec (1024 bytes = 64×64 × 2 bits/pixel ÷ 8)

---

## PR-02: LuckToken + LuckStaking

**Branch:** `PR-02/luck-token-staking`
**Dependencies:** PR-01
**Estimated effort:** Medium

### What this PR does
Implements the LUCK ERC-20 token with restricted minting, and the MasterChef-style staking pool that distributes alUSD rewards to LUCK stakers.

### Tasks

1. **Create `src/LuckToken.sol`**
   - Inherit OZ ERC20, Ownable
   - `minter` address (set in constructor, only minter can call `mint()`)
   - `setMinter(address)` — only current minter can call
   - Name: "Lucky Potion", Symbol: "LUCK", 18 decimals

2. **Write LuckToken tests (`test/LuckToken.t.sol`)**
   - `test_mint_onlyMinter` — non-minter reverts
   - `test_mint_updatesBalanceAndSupply`
   - `test_transfer_standard` — ERC20 transfer works
   - `test_setMinter_onlyCurrentMinter`
   - `test_setMinter_zeroAddressReverts`
   - `test_name_symbol_decimals`

3. **Create `src/LuckStaking.sol`**
   - MasterChef single-asset staking
   - State: `totalStaked`, `accRewardPerShare`, `PRECISION = 1e18`
   - `UserInfo { stakedAmount, rewardDebt }`
   - `addRewards(uint256)` — coordinator only, updates accRewardPerShare
   - `stake(uint256)` — auto-claims pending, transfers LUCK in
   - `unstake(uint256)` — auto-claims pending, transfers LUCK out
   - `claimRewards()` — claim without changing stake
   - `pendingRewards(address)` — view function
   - ReentrancyGuard on stake/unstake/claim
   - Track orphaned rewards when totalStaked == 0

4. **Write LuckStaking tests (`test/LuckStaking.t.sol`)**
   - `test_stake_transfersLUCK`
   - `test_stake_updatesUserInfo`
   - `test_unstake_returnsLUCK`
   - `test_unstake_autoClaimsPending`
   - `test_claimRewards_transfersCorrectAmount`
   - `test_addRewards_updatesAccPerShare`
   - `test_addRewards_zeroStakers_orphaned`
   - `test_multipleStakers_fairDistribution`
   - `test_stakeAfterRewards_noFreeRewards`
   - `test_zeroAmount_reverts`
   - `test_insufficientStake_reverts`

5. **Run all tests, commit, push**

### Review notes for auditors
- MasterChef math: verify no rounding exploits (stake 1 wei, get disproportionate rewards)
- Orphaned rewards handling: alUSD stuck if no one ever stakes
- Reentrancy: all state updated before external calls?
- Check that rewardDebt is calculated AFTER stakedAmount update (classic MasterChef bug)

---

## PR-03: TicketNFT + On-Chain SVG

**Branch:** `PR-03/ticket-nft`
**Dependencies:** PR-01
**Estimated effort:** Medium-Large

### What this PR does
Implements the ERC-721 ticket with on-chain canvas data storage, canvas hash computation, and on-chain SVG rendering for tokenURI.

### Tasks

1. **Create `src/TicketNFT.sol`**
   - Inherit OZ ERC721Enumerable
   - `TicketData` struct: drawingId, canvasHash (uint16), purchaseTime (uint64), burned (bool), canvasData (bytes)
   - `coordinator` address (set in constructor)
   - `mint(to, drawingId, canvasHash, canvasData)` — coordinator only
   - `burn(tokenId)` — coordinator only, marks burned + calls _burn
   - `getTicket(tokenId)` — returns TicketData
   - `tokenURI(tokenId)` — override, generates on-chain JSON + SVG
   - Canvas data validation: exactly 1024 bytes

2. **Create `src/libraries/SVGRenderer.sol`**
   - Pure library for rendering canvas data → SVG string
   - Game Boy palette: `#0f380f`, `#306230`, `#8bac0f`, `#9bbc0f`
   - Render 64×64 grid using `<rect>` elements
   - Optimization: batch consecutive same-color pixels into wider rects (row-scanning)
   - Returns base64-encoded SVG data URI

3. **Create `src/libraries/Base64.sol`**
   - Use OZ's Base64 library or include a gas-efficient one
   - Needed for tokenURI encoding

4. **Write TicketNFT tests (`test/TicketNFT.t.sol`)**
   - `test_mint_onlyCoordinator`
   - `test_mint_storesCanvasData`
   - `test_mint_incrementsTokenId`
   - `test_mint_invalidCanvasData_reverts`
   - `test_burn_onlyCoordinator`
   - `test_burn_removesOwnership`
   - `test_burn_preventDoubleBurn`
   - `test_transfer_works`
   - `test_tokenURI_returnsValidJSON` — parse base64, verify structure
   - `test_getTicket_returnsCorrectData`

5. **Write SVGRenderer tests (`test/SVGRenderer.t.sol`)**
   - `test_render_allZeros` — all BG color
   - `test_render_allOnes` — all lightest color
   - `test_render_knownPattern` — specific pixel arrangement
   - `test_render_outputIsSVG` — starts with `<svg`, ends with `</svg>`

6. **Run all tests, commit, push**

### Review notes for auditors
- Canvas data is stored on-chain (1024 bytes per ticket). Gas cost acceptable on Arbitrum?
- tokenURI is view-only (no gas cost for reads), but verify it doesn't revert for edge cases
- Verify burned tickets can't be transferred
- Check that canvasHash stored matches recomputation from canvasData
- SVG rendering: any XSS concerns if tokenURI is displayed in a browser? (shouldn't be, it's data URI)

---

## PR-04: PrizeVault + DrawingManager

**Branch:** `PR-04/prize-drawing`
**Dependencies:** PR-01
**Estimated effort:** Large

### What this PR does
Implements the prize vault (holds alUSD, manages per-drawing allocations and rollovers) and the drawing lifecycle manager (state machine + Chainlink VRF integration).

### Tasks

1. **Create `src/PrizeVault.sol`**
   - `coordinator` address
   - `DrawingPrize` struct: allocated, claimed, winnerCount, resolved, winningHash
   - `rolledOverBalance` — carried over from no-winner drawings
   - `deposit(drawingId, amount)` — coordinator only
   - `resolveDrawing(drawingId, winningHash, winnerCount)` — coordinator only
   - `applyRollover(newDrawingId)` — coordinator only
   - `claimPrize(drawingId, winner)` — coordinator only, ReentrancyGuard
   - View: `getPrizeInfo(drawingId)`, `getPerWinnerAmount(drawingId)`

2. **Write PrizeVault tests (`test/PrizeVault.t.sol`)**
   - `test_deposit_onlyCoordinator`
   - `test_deposit_increasesAllocation`
   - `test_resolveDrawing_noWinner_rollsOver`
   - `test_resolveDrawing_withWinner`
   - `test_applyRollover_addsToNewDrawing`
   - `test_claimPrize_splitsEvenly` — 3 winners split
   - `test_claimPrize_dustStaysInVault` — rounding dust
   - `test_claimPrize_overPayPrevented`
   - `test_doubleResolve_reverts`

3. **Create `src/DrawingManager.sol`**
   - Inherit `VRFConsumerBaseV2Plus`
   - `DrawingState` enum: OPEN, CLOSED, PENDING_VRF, RESOLVED
   - `Drawing` struct per spec §8.1
   - Hash tracking: `hashTicketCount[drawingId][hash]`, `hashTicketIds[drawingId][hash]`
   - `startDrawing()` — coordinator only
   - `registerTicket(drawingId, ticketId, canvasHash)` — coordinator only
   - `closeTicketSales(drawingId)` — permissionless after closeTime
   - `triggerDrawing(drawingId)` — coordinator only, requests VRF
   - `fulfillRandomWords(requestId, randomWords)` — VRF callback
   - `retryVRF(drawingId)` — after VRF_TIMEOUT
   - Views: `getDrawing`, `isDrawingOpen`, `getHashPopularity`, `getWinningTickets`

4. **Create mock VRF coordinator for testing: `test/mocks/MockVRFCoordinator.sol`**
   - Stores requests, allows manual fulfillment in tests
   - `fulfillRandomWordsWithOverride(requestId, consumer, randomWords)`

5. **Write DrawingManager tests (`test/DrawingManager.t.sol`)**
   - `test_startDrawing_setsTimings`
   - `test_registerTicket_incrementsCounts`
   - `test_registerTicket_afterClose_reverts`
   - `test_closeTicketSales_beforeTime_reverts`
   - `test_triggerDrawing_beforeDrawTime_reverts`
   - `test_triggerDrawing_requestsVRF`
   - `test_fulfillRandomWords_setsWinningHash`
   - `test_fulfillRandomWords_countsWinners`
   - `test_fulfillRandomWords_noWinner`
   - `test_retryVRF_afterTimeout`
   - `test_retryVRF_beforeTimeout_reverts`
   - `test_stateTransitions_onlyForward`
   - `test_getHashPopularity_accurate`
   - `test_getWinningTickets_returnsCorrectIds`

6. **Run all tests, commit, push**

### Review notes for auditors
- State machine: verify no state can go backwards
- VRF: verify only the VRF coordinator can call fulfillRandomWords
- Prize split rounding: verify dust is bounded by winnerCount-1
- Rollover: verify no double-apply of rollover
- Timing: verify TICKET_CUTOFF (2h before draw) is enforced correctly
- Hash extraction: `uint16(randomWords[0] % HASH_SPACE)` — any modulo bias? (65536 is power of 2, so no bias with bitwise AND)

---

## PR-05: LuckyPotion Coordinator

**Branch:** `PR-05/coordinator`
**Dependencies:** PR-01, PR-02, PR-03, PR-04
**Estimated effort:** Large

### What this PR does
The main coordinator contract that ties everything together. Handles ticket purchases (USDC→Alchemix), drawing triggers (mint alUSD→distribute), prize claims, ticket burns, and admin functions.

### Tasks

1. **Create mock Alchemist for testing: `test/mocks/MockAlchemistV3.sol`**
   - Tracks deposits per account
   - Returns mintable based on deposits × LTV (90%)
   - Tracks debt
   - Simple but functional for integration testing

2. **Create mock ERC20 for testing: `test/mocks/MockERC20.sol`**
   - Mintable mock token (for USDC and alUSD in tests)

3. **Create `src/LuckyPotion.sol`**
   - Constructor deploys all sub-contracts (or accepts addresses)
   - **buyTicket(canvasData):** USDC transfer → Alchemix deposit → mint NFT + LUCK → register hash
   - **buyTickets(canvasData[]):** Batch version, max 100
   - **triggerDrawing():** Permissionless after drawTime. Max-mint alUSD → distribute (2% ops, 15% staking, 83% prize) → apply rollover → request VRF
   - **finalizeDrawing(drawingId):** After VRF resolves. Notify PrizeVault → start next drawing
   - **claimPrize(ticketId):** Verify ownership + winning hash → claim from PrizeVault
   - **burnTicket(ticketId):** Verify ownership + drawing resolved + not winner → burn NFT + mint 0.1 LUCK
   - **Admin:** initialize(), setPaused(), setOpsMultisig(), rescueToken()
   - **Views:** getCurrentDrawing(), getHashPopularity(), getTicketInfo(), protocolStats()

4. **Write coordinator tests (`test/LuckyPotion.t.sol`)**
   - `test_buyTicket_fullFlow` — USDC transfer, Alchemix deposit, NFT mint, LUCK mint, hash registered
   - `test_buyTicket_whenPaused_reverts`
   - `test_buyTicket_whenNotInitialized_reverts`
   - `test_buyTicket_whenDrawingClosed_reverts`
   - `test_buyTickets_batch` — buy 5 tickets in one tx
   - `test_buyTickets_tooMany_reverts` — >100 tickets
   - `test_triggerDrawing_distributesCorrectly` — verify 2/15/83 split
   - `test_triggerDrawing_beforeDrawTime_reverts`
   - `test_triggerDrawing_noMintableAlUSD` — still requests VRF
   - `test_finalizeDrawing_startsNextDrawing`
   - `test_claimPrize_validWinner`
   - `test_claimPrize_notOwner_reverts`
   - `test_claimPrize_notWinner_reverts`
   - `test_claimPrize_doubleClaim_reverts`
   - `test_burnTicket_losersOnly`
   - `test_burnTicket_winner_reverts`
   - `test_burnTicket_activeDrawing_reverts`
   - `test_burnTicket_doubleBurn_reverts`
   - `test_burnTicket_mintsLUCK`
   - `test_initialize_onlyOnce`
   - `test_setPaused_onlyOwner`
   - `test_rescueToken_cannotRescueProtocol`
   - `test_protocolStats_accurate`

5. **Run all tests, commit, push**

### Review notes for auditors
- USDC decimal handling: TICKET_PRICE is 6 decimals, alUSD is 18 decimals — verify no mixing
- Alchemix approval: approve before each deposit? Or infinite approval? (prefer exact approval per call)
- Distribution math: verify `prizeAmount = mintable - ops - staking` (not BPS calc) to avoid rounding loss
- Reentrancy: buyTicket makes external calls to Alchemix — verify state is clean
- claimPrize: checks-effects-interactions pattern
- Access control: verify opsMultisig CANNOT drain prize vault
- Emergency pause: what's still callable when paused? (view functions only)

---

## PR-06: Integration Tests — Full Lifecycle

**Branch:** `PR-06/integration-tests`
**Dependencies:** PR-05
**Estimated effort:** Medium

### What this PR does
End-to-end tests that exercise the complete protocol lifecycle: buy tickets → trigger drawing → VRF resolves → claim/burn → next drawing. Tests multi-drawing scenarios, rollovers, staking rewards, and edge cases.

### Tasks

1. **Create `test/integration/FullLifecycle.t.sol`**
   - `test_fullLifecycle_buyTicket_triggerDrawing_claimPrize`
   - `test_fullLifecycle_noWinner_rollover` — 3 drawings with no winner, verify accumulation
   - `test_fullLifecycle_multipleWinners_splitPot` — 3 tickets same hash, verify even split
   - `test_fullLifecycle_burnForLuck` — lose → burn → verify 0.1 LUCK
   - `test_fullLifecycle_stakingRewards` — stake LUCK → trigger drawing → claim alUSD
   - `test_multiDrawing_prizeGrowth` — 5 drawings, verify prize grows
   - `test_stakingAcrossMultipleDrawings` — rewards accumulate correctly

2. **Create `test/integration/EdgeCases.t.sol`**
   - `test_zeroTickets_drawingResolves` — drawing with 0 tickets
   - `test_singleTicket_wins` — only 1 ticket, and it wins
   - `test_maxBatchBuy` — 100 tickets in one tx
   - `test_triggerDrawing_permissionless` — random address can trigger
   - `test_finalizeDrawing_permissionless` — random address can finalize
   - `test_burnAfterTransfer` — buy ticket, transfer to someone, they burn
   - `test_claimAfterTransfer` — buy winning ticket, transfer, new owner claims
   - `test_canvasHashCollisions` — many tickets with same hash

3. **Create `test/integration/CanvasHashConsistency.t.sol`**
   - Generate 100 random canvases
   - Verify `computeCanvasHash` is deterministic
   - Verify output distribution is approximately uniform (chi-squared-like check)

4. **Run all tests, commit, push**

### Review notes for auditors
- Time manipulation: verify `vm.warp` is used correctly (skip DRAWING_DURATION, not set absolute)
- Mock VRF: verify fulfillment matches real VRF behavior
- Transfer + claim: verify new owner can claim (ERC-721 ownership is what matters)
- Multi-drawing state: verify old drawing state is immutable after resolution

---

## PR-07: Invariant & Fuzz Tests

**Branch:** `PR-07/invariant-fuzz`
**Dependencies:** PR-06
**Estimated effort:** Medium-Large

### What this PR does
Stateful invariant testing (Foundry's invariant fuzzer) and property-based fuzz tests for all critical protocol properties from TECHNICAL_SPEC.md §12.

### Tasks

1. **Create test handler: `test/invariant/Handler.sol`**
   - Wraps all protocol actions with bounded inputs
   - Actions: buyTicket, triggerDrawing, finalizeDrawing, claimPrize, burnTicket, stake, unstake, claimRewards
   - Track ghost variables: totalDeposited, ticketsSold, ticketsBurned, etc.
   - Handle timing: advance time between actions appropriately

2. **Create `test/invariant/Invariants.t.sol`**
   - `invariant_luckSupplyConsistency` — INV-2
   - `invariant_noAlUSDStuckInCoordinator` — INV-3
   - `invariant_prizeVaultSolvency` — INV-4
   - `invariant_stakingSolvency` — INV-5
   - `invariant_noDoubleClaimOrBurn` — INV-6
   - `invariant_drawingStateOnlyForward` — INV-8
   - `invariant_ticketCountConsistency` — INV-9
   - `invariant_hashCountMatchesArray` — INV-10
   - `invariant_luckSupplyOnlyIncreases` — INV-15

3. **Create `test/fuzz/FuzzCanvasHash.t.sol`**
   - `fuzz_canvasHash_alwaysValid(bytes)` — output < 65536
   - `fuzz_canvasHash_deterministic(bytes)` — same input → same output

4. **Create `test/fuzz/FuzzStaking.t.sol`**
   - `fuzz_staking_noFundsLocked(uint256 stake, uint256 reward, uint256 unstake)`
   - `fuzz_staking_rewardDebtAccurate(uint256 stake, uint256 reward)`

5. **Create `test/fuzz/FuzzPrizeDistribution.t.sol`**
   - `fuzz_distribution_exhaustive(uint256 mintAmount)` — ops + staking + prize == mintAmount
   - `fuzz_prizeSplit_fair(uint256 totalPrize, uint256 winnerCount)` — dust < winnerCount

6. **Run all with extended runs, commit, push**
   ```bash
   forge test --match-path "test/invariant/*" -vvv
   forge test --match-path "test/fuzz/*" -vvv
   ```

### Review notes for auditors
- Handler coverage: are all meaningful state transitions exercised?
- Invariant failures: any ghost variable drift? (sum mismatch from rounding)
- Fuzz bounds: are inputs bounded realistically? (no uint256.max ticket prices)
- Solvency invariants: do they account for orphaned staking rewards?

---

## PR-08: Deployment Scripts, Documentation & Cleanup

**Branch:** `PR-08/deployment-docs`
**Dependencies:** PR-07
**Estimated effort:** Small-Medium

### What this PR does
Deployment scripts (Foundry Script), comprehensive README, NatSpec documentation on all contracts, and final cleanup (remove forge boilerplate, verify all tests pass).

### Tasks

1. **Create `script/Deploy.s.sol`**
   - Deployment script following TECHNICAL_SPEC.md §16
   - Accept constructor args from environment variables
   - Deploy LuckyPotion (which deploys sub-contracts)
   - Verify all cross-references
   - Log all deployed addresses
   - NOT calling `initialize()` — that's a separate manual step

2. **Create `script/Initialize.s.sol`**
   - Separate script to call `initialize()` after deploy + VRF subscription setup
   - Verify first drawing is OPEN

3. **Add NatSpec to all contracts**
   - @title, @author, @notice, @dev on every contract
   - @param, @return on every function
   - @inheritdoc where applicable

4. **Write `README.md`**
   - Project overview
   - Architecture diagram (ASCII)
   - Contract descriptions
   - Build & test instructions
   - Deployment instructions
   - Address table (TBD)
   - License

5. **Cleanup**
   - Delete `src/Counter.sol`, `test/Counter.t.sol`, `script/Counter.s.sol` (if not already)
   - Verify `forge build` compiles clean (0 warnings)
   - Verify `forge test` all pass
   - Verify `forge test --gas-report` output is reasonable

6. **Final commit and push**

### Review notes for auditors
- Deployment script: verify it doesn't contain hardcoded addresses
- NatSpec: verify accuracy matches implementation
- No secrets or private keys in any file
- README accuracy

---

## Audit Pipeline (Per PR)

Each PR gets TWO review rounds:

### Round 1: Opus Audit
- Agent: `auditor` (Gildo) with model `opus`
- Focus: Security vulnerabilities, logic errors, spec compliance, edge cases
- Posts findings as GitHub PR comments
- Dev agent fixes, pushes updates

### Round 2: Codex Audit
- Agent: `codex` with OpenAI Codex/ChatGPT
- Focus: Second opinion, pattern matching, alternative attack vectors
- Posts findings as GitHub PR comments
- Dev agent fixes, pushes updates

### Merge Criteria
- Both auditors pass (or all findings addressed)
- All tests pass (`forge test`)
- Build clean (`forge build` — 0 warnings)
- Report written to `reports/PR-XX-report.md`

---

## Execution Order

```
1. PR-01 → implement → opus audit → fix → codex audit → fix → merge
2. PR-02 → implement → opus audit → fix → codex audit → fix → merge
3. PR-03 → implement → opus audit → fix → codex audit → fix → merge
4. PR-04 → implement → opus audit → fix → codex audit → fix → merge
5. PR-05 → implement → opus audit → fix → codex audit → fix → merge
6. PR-06 → implement → opus audit → fix → codex audit → fix → merge
7. PR-07 → implement → opus audit → fix → codex audit → fix → merge
8. PR-08 → implement → opus audit → fix → codex audit → fix → merge
```

Each PR is **sequential** — no parallel execution (rate limit policy).

---

## Key Spec References

- Full spec: `~/Desktop/projects/lucky-potion/SPEC.md`
- Technical spec: `~/Desktop/projects/lucky-potion/TECHNICAL_SPEC.md`
- Constants: TECHNICAL_SPEC §3
- State machine: TECHNICAL_SPEC §11
- Invariants: TECHNICAL_SPEC §12
- Error conditions: TECHNICAL_SPEC §13
- Events: TECHNICAL_SPEC §14
- Access control: TECHNICAL_SPEC §15
- Test plan: TECHNICAL_SPEC §18
- Gas estimates: TECHNICAL_SPEC §19
