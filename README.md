# 🧪 Magic Potion — Self-Repaying Lottery

A **regenerative lottery** built on [Alchemix V3](https://alchemix.fi). Buy a $5 USDC ticket, paint 64×64 pixel art, and your deposit earns yield forever. Prize pots regenerate from Alchemix's self-repaying loan mechanism — your principal never leaves.

**Chain:** Arbitrum One  
**Stack:** Solidity 0.8.24, Foundry, OpenZeppelin 5.x, Chainlink VRF V2.5

## How It Works

```
  USDC ($5)         Alchemix V3            alUSD Yield
  ────────> ┌──────────────────┐  ────────> ┌──────────────┐
   Ticket   │  Deposit as      │  Every 14d │  2% → Ops    │
   Purchase │  Collateral      │  Max-mint  │ 15% → Stakers│
            └──────────────────┘  alUSD     │ 83% → Prize  │
                                            └──────┬───────┘
                                                   │
                                            Chainlink VRF
                                                   │
                                            ┌──────▼───────┐
                                            │ keccak256 →  │
                                            │ 16-bit hash  │
                                            │ 1/65,536 odds│
                                            └──────────────┘
```

1. **Buy ticket** → $5 USDC deposited into Alchemix → receive NFT (pixel art) + 1 LUCK token
2. **Every 14 days** → max-mint alUSD against deposits → distribute to ops/stakers/prize vault
3. **VRF drawing** → Chainlink picks winning 16-bit hash → matching tickets split the pot
4. **No winner?** → Prize rolls over to next drawing (pot grows!)
5. **Burn losing tickets** → receive 0.1 LUCK → LUCK stakers earn 15% of all yield

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    LuckyPotion.sol                       │
│              (Main Coordinator Contract)                 │
│                                                         │
│  buyTicket() · buyTickets() · triggerDrawing()          │
│  finalizeDrawing() · claimPrize() · burnTicket()        │
└───┬────────┬────────┬────────┬────────┬────────────────┘
    │        │        │        │        │
    ▼        ▼        ▼        ▼        ▼
┌────────┐┌────────┐┌──────┐┌───────┐┌──────────────┐
│Ticket  ││Luck    ││Luck  ││Prize  ││Drawing       │
│NFT     ││Token   ││Stake ││Vault  ││Manager       │
│ERC-721 ││ERC-20  ││Master││alUSD  ││VRF + State   │
│+SVG    ││        ││Chef  ││escrow ││Machine       │
└────────┘└────────┘└──────┘└───────┘└──────────────┘
```

## Contracts

| Contract | Description |
|----------|-------------|
| `LuckyPotion.sol` | Main coordinator — all user-facing functions |
| `TicketNFT.sol` | ERC-721 with on-chain 64×64 pixel art + SVG rendering |
| `LuckToken.sol` | ERC-20 governance/reward token with restricted minting |
| `LuckStaking.sol` | MasterChef-style staking — stake LUCK, earn alUSD |
| `DrawingManager.sol` | Drawing state machine + Chainlink VRF V2.5 |
| `PrizeVault.sol` | Per-drawing prize escrow with rollover mechanics |
| `SVGRenderer.sol` | Library — renders 64×64 pixel art as on-chain SVG |
| `CanvasHash.sol` | Library — keccak256 → 16-bit hash (1/65,536 odds) |
| `Constants.sol` | All protocol constants ($5 ticket, 14d duration, BPS splits) |

## Key Parameters

| Parameter | Value |
|-----------|-------|
| Ticket price | 5 USDC |
| Drawing period | 14 days |
| Ticket cutoff | 2 hours before draw |
| Hash space | 65,536 (16-bit) |
| Ops share | 2% |
| Staker share | 15% |
| Prize share | 83% |
| LUCK per ticket | 1.0 |
| LUCK per burn | 0.1 |
| Max batch | 100 tickets |

## Development

```bash
# Install
forge install

# Build
forge build

# Test (151 tests)
forge test

# Test with gas report
forge test --gas-report

# Invariant tests (longer)
forge test --match-path "test/invariant/*" -v
```

## Test Coverage

- **Unit tests:** CanvasHash, Constants, TicketNFT, SVGRenderer, LuckToken, LuckStaking, DrawingManager, PrizeVault, LuckyPotion
- **Integration tests:** Full lifecycle (buy→trigger→claim), multi-drawing rollover, multi-winner split, staking rewards, NFT transfer + claim/burn
- **Edge cases:** Zero tickets, max batch, permissionless trigger/finalize, hash collisions
- **Invariant tests:** 7 protocol invariants with stateful handler
- **Fuzz tests:** Staking precision, proportional rewards, no-funds-locked

## Deployment

```bash
# 1. Deploy all contracts
source .env
forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast --verify

# 2. Add DrawingManager as VRF consumer (via Chainlink UI)

# 3. Initialize the protocol
forge script script/Initialize.s.sol --rpc-url $RPC_URL --broadcast
```

## License

MIT
