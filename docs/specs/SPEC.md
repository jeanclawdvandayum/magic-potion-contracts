# Lucky Potion 🧪🎰

**Self-Repaying On-Chain Lottery Powered by Alchemix V3**

*Status: DRAFT v0.1 — Feb 14, 2026*

---

## Elevator Pitch

A Powerball-style on-chain lottery where ticket purchases ($5 USDC) are deposited into Alchemix V3, creating a self-sustaining prize pool. Ticket buyers receive an NFT ticket + LUCK tokens. The pot is funded by max-minting alUSD against deposited collateral, and grows perpetually because the principal never leaves. Even after a winner claims the pot, the system regenerates from yield on the locked USDC.

---

## Core Mechanics

### Ticket Purchase
- **Price:** $5 USDC (flat)
- **Buyer receives:**
  1. **NFT Ticket** — ERC-721 with assigned lottery number for the current drawing
  2. **LUCK Token** — ERC-20, flat 1 LUCK per ticket (regardless of timing)
- **USDC flow:** Deposited directly into Alchemix V3 as collateral

### Drawing Mechanics (Megapot)
- **Frequency:** Every 2 weeks
- **Format:** Visual canvas matching (see Canvas Engine below)
  - Each ticket is a unique 256×256 monochrome image
  - Winning image revealed via Chainlink VRF → deterministic hash-to-canvas mapping
  - If no ticket matches → pot rolls over to next drawing
- **Odds:** 1/65,536 per ticket (256×256 = 65,536 possible outcomes)

### Canvas Engine 🎨
The lottery "number" is derived from a **64×64 pixel art canvas** with a **4-color palette** (Game Boy style).

**How it works:**
1. **Draw** — User creates pixel art on 64×64 canvas with 4-color palette
2. **Random** — Generate a random canvas, shuffle until you see one you like
3. **Hash** — Canvas data is deterministically hashed to a 16-bit value (0–65,535)
4. **Match** — VRF produces winning 16-bit number. If your hash matches, you win.

The art and the odds are decoupled:
- Canvas size and palette are aesthetic choices (64×64, 4 colors)
- Odds are determined by hash output size (16 bits = 1/65,536)
- Any canvas configuration hashes to exactly one of 65,536 outcomes

**4-Color Palette:**
```
██  ░░  ▒▒  ▓▓
BG  Light  Mid  Dark
```
Game Boy aesthetic. Constraints breed creativity. Seasonal palette drops possible (Valentine's, Halloween, etc.) — same odds, different vibe.

**Why this matters:**
- Tickets become **shareable pixel art** — inherently viral
- Winning reveal is a **visual spectacle**, not a boring number readout
- Every ticket is a **tradeable on-chain artwork** (ERC-721)
- Winning tickets become **historical collectibles**
- "I drew a cat and won $80K in alUSD" writes its own headline
- Losing tickets still have value as art pieces or can be burned for LUCK

### Prize Pool Funding (per drawing)
At each drawing, the contract max-mints alUSD against all deposited USDC collateral:

| Allocation | % | Destination |
|-----------|---|-------------|
| Operations | 2% | Lottery multisig (ops/infra/dev) |
| LUCK Stakers | 15% | Distributed pro-rata to staked LUCK |
| Prize Vault | 83% | Accumulates until a winner is drawn |

**V3 LTV: 90%** — So $100K USDC deposited → $90K alUSD minted per cycle (minus existing debt).

### Post-Win Regeneration
When someone wins and claims the prize vault (paid in alUSD):
1. USDC principal remains in Alchemix ✅
2. Outstanding debt gradually self-repays from yield ✅
3. As debt repays, more alUSD becomes mintable ✅
4. New drawings resume automatically ✅

**The system is perpetual.** The only "drain" is the alUSD leaving as prizes — but the USDC collateral stays and keeps earning.

---

## Economics Deep Dive

### Scenario Modeling

**Assumptions:** 5% APY on USDC in Alchemix V3, 90% LTV

#### Phase 1: Launch (Weeks 1-2, first drawing)
| Metric | Conservative | Moderate | Optimistic |
|--------|-------------|----------|------------|
| Tickets sold | 5,000 | 20,000 | 100,000 |
| USDC deposited | $25,000 | $100,000 | $500,000 |
| Max mint alUSD | $22,500 | $90,000 | $450,000 |
| Ops (2%) | $450 | $1,800 | $9,000 |
| LUCK stakers (15%) | $3,375 | $13,500 | $67,500 |
| Prize vault (83%) | $18,675 | $74,700 | $373,500 |

#### Phase 2: Subsequent Drawings (no winner, new tickets)
After max mint, new drawings can only distribute:
1. **Newly freed credit** from yield repaying debt
2. **New deposits** from ticket sales in the period

At $100K deposited, 5% APY:
- ~$192/week in yield → ~$384 freed per 2-week drawing
- Plus new ticket sales add fresh collateral

So the pot growth becomes: `new_tickets × $5 × 0.9 × 0.83 + yield_freed × 0.83`

#### Compounding Example (Moderate scenario, no winner for 6 months)
| Drawing | New Tickets | Total USDC | New Mintable | Prize Vault (cumulative) |
|---------|-------------|-----------|--------------|------------------------|
| 1 | 20,000 | $100K | $90,000 | $74,700 |
| 2 | 10,000 | $150K | $45,384 | $112,368 |
| 3 | 8,000 | $190K | $36,384 | $142,567 |
| 6 | 5,000 | $280K | $22,884 | $215,000+ |
| 13 | 3,000 | $350K | $13,884 | $350,000+ |

*Numbers approximate — actual depends on yield rate, ticket velocity, and debt repayment timing.*

**Key insight:** Even with declining ticket sales, the pot keeps growing because yield keeps freeing mintable credit AND the prize vault accumulates.

### LUCK Token Economics

**Supply:** 1 LUCK per ticket purchased (flat, forever)
**Transferrable:** Yes — freely tradeable ERC-20. Secondary market enables price discovery.

**Value proposition:**
- LUCK stakers earn 15% of every drawing's minted alUSD via MasterChef-style staking pool
- Early buyers benefit because the staking pool is smaller relative to distributions
- LUCK never expires — it's a permanent claim on future yield distributions
- Secondary market: people can buy LUCK without buying lottery tickets (pure yield play)

**Staking: MasterChef-style pool**
- Stake LUCK → earn alUSD rewards proportional to share of pool
- Rewards accumulate per-drawing (15% of each mint distributed to pool)
- `pendingRewards = userShare × accRewardsPerShare - rewardDebt`
- No lockup required (MasterChef pattern handles entry/exit cleanly)
- Claim anytime

**Anti-dump dynamics:**
- LUCK is yield-bearing via staking → natural holding incentive
- Selling LUCK = selling a perpetual alUSD yield stream → rational actors hold
- No LUCK inflation beyond ticket purchases

### Ticket Burn Mechanics

Tickets are soulbound but burnable. Question is whether burning should be purely cosmetic (wallet cleanup) or have game-theoretic utility:

**Option A: Cosmetic burn only**
- Burn losing tickets after drawing resolves
- No reward, just declutters wallet
- Simple, no exploit surface

**Option B: Burn-for-LUCK bonus**
- Burn a losing ticket → receive small LUCK bonus (e.g. 0.1 LUCK)
- Incentivizes engagement after losing
- Creates a "consolation prize" loop
- Risk: people buy tickets just to burn for LUCK (probably fine — they still deposit USDC into Alchemix)

**Option C: Burn-to-boost**
- Burn N losing tickets from past drawings → boost odds on next ticket purchase
- Creates collectibility / engagement loop
- More complex, harder to balance

**Decision: Option B** — Burn-for-LUCK. Consolation LUCK keeps losers engaged, and the system benefits regardless (more USDC deposited). The "graveyard" of burned ticket art could be its own social feature.

**Implementation note:** Burn should only be allowed after the associated drawing has resolved. Burning a ticket for an active drawing = destroying your entry.

### Hash Collision Mechanics

Multiple tickets can produce the same 16-bit hash. The contract tracks this:

```solidity
// Per drawing: how many tickets share each hash
mapping(uint256 => mapping(uint16 => uint256)) public hashTicketCount;
// Per drawing: which tickets have a given hash (for claim verification)
mapping(uint256 => mapping(uint16 => uint256[])) public hashTicketIds;
```

**If the winning hash has N matching tickets → prize vault splits evenly (prizeAmount / N).**

**Game theory this creates:**
- Draw something "obvious" (smiley face, heart, etc.) = higher chance of hash collision = split pot if you win
- Draw something weird/unique = less likely to share your hash = keep the full pot
- **Creativity is rewarded** — the more original your art, the better your expected value
- This info could be public: "47 tickets share hash #0xA3F2" — do you want to pile on or go unique?

**Display option:** Show hash popularity during ticket purchase ("3 other tickets share this hash" / "You're the only one!"). Creates a real-time strategy layer without revealing the art itself.

---

## Odds Design

### The Problem
Powerball odds (1:292M) don't work for a niche crypto dapp. We need odds that:
- Create regular winners to maintain excitement and trust
- Still allow meaningful pot accumulation via rollovers
- Scale with a much smaller player base (thousands, not millions)

### Chosen: 1/65,536 (via 256×256 Canvas)

The canvas engine naturally gives us 65,536 possible outcomes (2^16). This is a sweet spot:

| Tickets/Drawing | P(winner) | Expected drawings between wins |
|----------------|-----------|-------------------------------|
| 1,000 | 1.5% | ~65 drawings (~2.5 years) |
| 5,000 | 7.4% | ~13 drawings (~26 weeks) |
| 10,000 | 14.2% | ~7 drawings (~14 weeks) |
| 20,000 | 26.3% | ~4 drawings (~8 weeks) |
| 50,000 | 53.5% | ~2 drawings (~4 weeks) |
| 65,536 | 63.2% | ~1-2 drawings |

### Analysis

At **5,000 tickets/drawing** (moderate launch): winner roughly every 6 months. Pot accumulates to massive levels, driving FOMO and viral growth.

At **20,000 tickets/drawing** (growth phase): winner every ~8 weeks. Frequent enough to maintain trust that winning is real.

**1/65,536 vs 1/100,000:** More favorable odds = more winners = more "proof someone won" stories. Better for a niche crypto audience where trust is earned through visible outcomes.

**Risk:** At 50K+ tickets/drawing, winners every month. Solutions:
1. Dynamic canvas complexity increase (governance)
2. Multi-layer matching (canvas + secondary condition)
3. Accept it — frequent smaller wins + LUCK staking may be the better endgame

### Future: Tiered Prizes (V2)
With canvas-based matching, "closeness" becomes visual similarity — partially matching images could win smaller prizes. Needs a well-defined similarity metric.

| Tier | Match Quality | Prize |
|------|-------------|-------|
| Megapot | Exact match | 83% of vault |
| Major | >90% pixel similarity | 5% of drawing mint |
| Minor | >75% pixel similarity | 1% of drawing mint |

*Visual "near-miss" prizes are more exciting than digit matching — you can SEE how close you were.*

---

## Randomness

### Option A: Chainlink VRF (Recommended for V1)
- **Pros:** Battle-tested, easy integration, available on all major chains
- **Cons:** Centralized trust assumption (Chainlink operators), VRF subscription cost
- **Cost:** ~$0.25-2.00 per request depending on chain/gas

### Option B: VDF (Verifiable Delay Function)
- **Pros:** Truly permissionless, no trusted third party, mathematically guaranteed delay
- **Cons:** Complex implementation, high gas for on-chain verification (~500K-2M gas for Pietrzak VDF), no battle-tested Solidity libraries yet
- **Best for:** V2 upgrade when the protocol has resources to audit a custom VDF verifier

### Option C: Hybrid (Commit-Reveal + Chainlink)
- Drawing trigger commits to block hash
- Chainlink VRF generates randomness seeded with committed hash
- Two sources of entropy, harder to manipulate

**Recommendation:** Chainlink VRF for V1. Upgrade path to VDF for V2.

---

## Contract Architecture (Draft)

```
┌─────────────────┐     ┌──────────────────┐
│  LuckyPotion    │────▶│  AlchemistV3     │
│  (Main Contract)│     │  (USDC Vault)    │
│                 │     └──────────────────┘
│  - buyTicket()  │
│  - triggerDraw()│     ┌──────────────────┐
│  - claimPrize() │────▶│  Chainlink VRF   │
│  - stakeLUCK()  │     └──────────────────┘
│  - unstakeLUCK()│
│  - claimReward()│     ┌──────────────────┐
└─────────────────┘     │  LUCK Token      │
                        │  (ERC-20)        │
┌─────────────────┐     └──────────────────┘
│  TicketNFT      │
│  (ERC-721)      │     ┌──────────────────┐
│  - number       │     │  Prize Vault     │
│  - drawingId    │     │  (alUSD holder)  │
│  - owner        │     └──────────────────┘
└─────────────────┘
```

### Key Contracts

1. **LuckyPotion.sol** — Main coordinator
   - Receives USDC, deposits into Alchemix, mints tickets + LUCK
   - Triggers drawings, requests randomness, resolves winners
   - Manages alUSD minting and distribution

2. **TicketNFT.sol** — ERC-721 (Tradeable)
   - Each token = one lottery entry + on-chain pixel art
   - Metadata: drawingId, hash-derived number, purchase timestamp, 64×64 canvas data
   - **Fully transferable** — tickets are tradeable art pieces; winning tickets become historical collectibles
   - **Burnable** — holders can burn after drawing resolves for 0.1 LUCK consolation (see Burn Mechanics)
   - Secondary market creates natural tension: burn for LUCK yield vs hold/sell the art

3. **LuckToken.sol** — ERC-20
   - Flat mint: 1 LUCK per ticket purchased
   - Staking mechanism (could be built-in or separate StakingVault)

4. **PrizeVault.sol** — Holds accumulated alUSD
   - Releases to winner on valid claim
   - Tracks per-drawing allocations for tiered prizes (future)

5. **DrawingManager.sol** — Manages drawing lifecycle
   - Ticket sale windows, drawing triggers, number reveal
   - Integrates with Chainlink VRF
   - Handles rollover logic

### Key Functions

```solidity
// Buy a ticket for current drawing
function buyTicket() external returns (uint256 ticketId, uint256 luckAmount);

// Trigger a drawing (permissionless, anyone can call after window closes)
function triggerDrawing(uint256 drawingId) external;

// Chainlink VRF callback
function fulfillRandomWords(uint256 requestId, uint256[] memory randomWords) internal;

// Winner claims prize
function claimPrize(uint256 ticketId) external;

// LUCK staking
function stakeLUCK(uint256 amount) external;
function unstakeLUCK(uint256 amount) external;
function claimStakingRewards() external;
```

---

## Alchemix V3 Integration Details

### Deposit Flow
```
User pays $5 USDC
  → LuckyPotion.buyTicket()
    → USDC.transferFrom(user, address(this), 5e6)
    → AlchemistV3.deposit(USDC, 5e6, address(this))
    → TicketNFT.mint(user, assignedNumber, currentDrawingId)
    → LuckToken.mint(user, 1e18)
```

### Drawing Flow
```
Drawing period ends
  → LuckyPotion.triggerDrawing(drawingId)
    → AlchemistV3.mint(maxMintable, address(this))  // 90% LTV
    → alUSD distribution:
       - 2% → opsMultisig
       - 15% → LUCKStaking contract
       - 83% → PrizeVault
    → VRF request → winning number revealed
    → If match: winner can claim from PrizeVault
    → If no match: PrizeVault balance rolls over
```

### Position Management
- LuckyPotion holds ONE position in AlchemistV3 (aggregated)
- All ticket USDC goes into this single position
- Simplifies accounting — no per-user positions needed
- The contract is the borrower, users are ticket/LUCK holders

---

## Chain Selection

**Primary candidates:**
- **Arbitrum** — Low gas, Alchemix already deployed, large DeFi user base
- **Optimism** — Same benefits, OP incentives possible
- **Mainnet** — Higher gas but largest liquidity, "premium" feel for a lottery

**Recommendation:** Arbitrum for V1. Cross-chain expansion later.

---

## Security Considerations

1. **Front-running protection** — Ticket purchases must close BEFORE randomness is requested. Hard cutoff enforced on-chain.
2. **VRF manipulation** — Chainlink VRF is resistant but not immune to operator collusion. VDF upgrade path addresses this.
3. **Flash loan attacks** — Not applicable (USDC deposits, no price oracles involved in ticket purchase)
4. **Reentrancy** — Standard guards on claimPrize, stakeLUCK flows
5. **Admin keys** — Ops multisig receives 2% but should NOT have power to drain prize vault. Prize vault should be fully autonomous.
6. **Drawing griefing** — triggerDrawing should be permissionless (anyone can call after window) to prevent censorship
7. **Alchemix dependency** — If Alchemix yield drops to 0, the system stalls but doesn't break. Prize vault retains accumulated alUSD. New mintable credit slows.

---

## Regulatory Notes

⚠️ **"Lottery" has heavy legal baggage.** Most jurisdictions regulate lotteries under gambling law.

**Possible framings:**
- "Prize-linked savings protocol" (PoolTogether's approach)
- "Yield distribution game"
- "Prediction market" (weaker fit)

**Key distinction:** Users receive LUCK tokens (yield-bearing asset) for every ticket. This arguably makes it closer to a "savings product with bonus prizes" than a pure lottery.

**Needs legal review** before launch. Particularly:
- US state-by-state gambling laws
- EU gambling directives
- Whether LUCK token constitutes a security (Howey test implications)

---

## Open Questions

1. ~~LUCK staking lockup~~ → **RESOLVED:** MasterChef-style, no lockup. Entry/exit anytime.
2. ~~Ticket transferability~~ → **RESOLVED:** Fully tradeable ERC-721. Winning tickets = collectibles.
3. **Multiple tickets per address** — Allow or cap? Multiple tickets = better odds but whales dominate.
4. **Drawing window** — How long before a drawing are ticket sales open? Continuous or windowed?
5. **Partial match prizes** — V1 or V2 feature?
6. **Governance** — Who adjusts odds, fees, drawing frequency? Token-weighted (LUCK)?
7. **Treasury bootstrapping** — Initial liquidity for ops? Pre-mine LUCK?
8. **Cross-chain expansion** — Unified pot or per-chain drawings?
9. ~~Ticket burn utility~~ → **RESOLVED:** Option B, burn-for-LUCK bonus (0.1 LUCK per burn)
10. **Hash function choice** — Which hash maps 64×64 canvas → 16-bit value? Needs to be deterministic, collision-resistant within the 65K space, and gas-efficient for on-chain verification.
11. **On-chain art storage** — Store full 64×64 canvas on-chain? Or IPFS/Arweave with on-chain hash? On-chain is more pure but costs gas.
12. **Seasonal palettes** — Governance-controlled palette swaps? Limited edition drawings?
13. ~~Duplicate hash handling~~ → **RESOLVED:** Pot splits evenly among all tickets sharing the winning hash. Contract tracks ticket count per hash via `mapping(uint256 drawingId => mapping(uint16 hash => uint256 count))`. See Hash Collision Mechanics below.

---

## Roadmap (Draft)

### V1 — MVP
- Single chain (Arbitrum)
- $5 flat tickets, 1 LUCK per ticket
- Megapot only (no tiered prizes)
- Chainlink VRF
- Biweekly drawings
- 1/100,000 odds (5-digit number)

### V2 — Growth
- Tiered prizes (partial matches)
- Dynamic odds adjustment
- VDF upgrade for randomness
- Multi-chain deployment
- LUCK governance for parameter changes

### V3 — Expansion
- Multiple asset pools (ETH lottery, DAI lottery)
- Cross-chain unified pot via bridging
- Referral system (earn LUCK for bringing new players)
- Social features (ticket gifting, pools/syndicates)

---

## References

- [Alchemix V3 Docs](https://alchemix-finance.gitbook.io/v2/)
- [PoolTogether V5 Design](https://dev.pooltogether.com/protocol/design/)
- [Chainlink VRF Docs](https://docs.chain.link/vrf)
- [Pietrzak VDF — Ethereum Implementation Study](https://arxiv.org/html/2405.06498v3)
- [Verifiable Delay Functions (Boneh et al.)](https://eprint.iacr.org/2018/601.pdf)
