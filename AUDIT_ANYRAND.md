# Randomness Evaluation: drand + Anyrand for Magic Potion
Date: 2026-08-05
Scope: drand protocol (drand.love) + Anyrand EVM contracts (github.com/frogworksio/anyrand)
Method: evm-cortex manual review (CEI, access control, crypto, timing)
Purpose: Evaluate viability as Chainlink VRF replacement

---

## PART 1: drand Protocol Evaluation

### What drand is

drand is a distributed randomness beacon run by the League of Entropy, a consortium of ~20 organizations (Cloudflare, Ethereum Foundation, Protocol Labs, etc.). It generates a BLS threshold signature every 3 seconds continuously, producing a publicly verifiable random value.

- Written in Go (github.com/drand/drand, 832 stars, 131 forks)
- Maintained by Randamu, Inc.
- Client libraries: Go, JavaScript/TypeScript
- Transport: HTTPS REST API, libp2p PubSub
- 3 mainnet networks: default (BLS12-381 chained), quicknet (BLS12-381 unchained), evmnet (BN254 unchained)

### Cryptographic properties

- Threshold BLS signatures: t-of-n nodes must cooperate. No single party can predict or bias the output.
- Unpredictable: signature is deterministic but unknown until threshold of parties reveal their partial signatures
- Unbiasable: a single party withholding their share cannot change the final signature (Lagrange interpolation guarantees this)
- Publicly verifiable: anyone with the collective public key can verify a signature

### The evmnet network

This is the key feature for EVM integration. evmnet uses the BN254 curve instead of BLS12-381. BN254 is natively supported by the EVM pairing precompile (address 0x06, EIP-197). This means a Solidity contract can verify drand signatures entirely on-chain.

- evmnet chain hash: 04f1e9062b8a81f848fded9c12306733282b2727ecced50032187751166ec8c3
- Unchained scheme (each round signs H(round_number), no chaining to previous signature)
- Signatures on G1 (64 bytes), public key on G2 (128 bytes)

### What drand does NOT provide

drand provides no Solidity contracts, no EVM on-chain verification, no coordinator/callback pattern. It is purely a beacon that produces randomness via HTTP API and client libraries. Any EVM integration requires a third-party contract to:
1. Store the drand public key
2. Verify BLS signatures on-chain via BN254 pairing precompile
3. Implement a request/fulfill coordinator pattern

drand itself has no opinion on how this is done.

### drand assessment: SOUND

The protocol itself is mature, well-documented, battle-tested, and run by credible organizations. The League of Entropy has been running since 2020. The threshold BLS cryptography is well-understood and peer-reviewed. The evmnet network specifically exists to enable EVM integration. No concerns with the underlying randomness source.

---

## PART 2: Anyrand Contract Audit (the EVM layer)

Anyrand (github.com/frogworksio/anyrand, by Kevin Charm / frogworks.io) is a Solidity implementation of the EVM integration layer that drand does not provide. It consists of:

- DrandBeacon.sol: immutable contract storing the drand public key + verifying BLS signatures via BN254 precompile
- Anyrand.sol: UUPS-upgradeable coordinator implementing request/fulfill/callback pattern
- GasStation contracts: gas price estimation for fulfillment pricing

Could not run Slither (solc 0.8.28 not available on this machine). Manual review only. Formal audit exists: 2024-10-14.

### Findings

#### [HIGH-1] UUPS upgradeability on the coordinator
File: contracts/Anyrand.sol:89
The Anyrand coordinator is upgradeable. The owner can push a new implementation at any time that overrides how randomness is derived or verified. For a lottery where randomness integrity IS the product, whoever controls the upgrade key controls the outcome.
Fix: Fork as non-upgradeable (immutable implementation). Or deploy behind governance timelock + multisig.

#### [HIGH-2] Owner can drain all ETH including pending request payments
File: contracts/Anyrand.sol:106-114
withdrawETH pulls from the entire contract balance. No per-request accounting. If many requests are pending and owner withdraws, keepers cannot be reimbursed.
Fix: Track per-request deposits. Only allow withdrawing surplus (total balance minus pending liabilities).

#### [MED-1] Failed callback = permanent loss, no retry
File: contracts/Anyrand.sol:326-331
If receiveRandomness reverts, the request goes to Failed state with hash zeroed. ETH is stuck. No mechanism to retry fulfillment or refund.
Fix: Keep receiveRandomness callback trivial (store value only). Request with adequate callbackGasLimit.

#### [MED-2] Solady Ownable (not 2-step)
File: contracts/Anyrand.sol:27
Single-step ownership transfer. Accidental transfer to wrong address bricks the protocol.
Fix: Use Solady Ownable2Step.

#### [LOW-1] Floating pragmas on interfaces
Files: Gas.sol, IDrandBeacon.sol, IAnyrand.sol, IRandomiserCallbackV3.sol (^0.8)
Implementation contracts pin 0.8.28. Interfaces float. Acceptable for interfaces.

#### [LOW-2] withdrawETH has no ReentrancyGuard
File: contracts/Anyrand.sol:106
Raw call{value} before effect, no nonReentrant. Negligible since it's onlyOwner with no balance accounting to exploit, but violates CEI best practice.

#### [LOW-3] GasStationEthereum uses tx.gasprice in view function
File: contracts/networks/GasStationEthereum.sol:17
Returns incorrect values when called statically from block explorers. Documented in NatSpec.

### Cryptographic review of DrandBeacon.sol

- Domain separation tag: "BLS_SIG_BN254G1_XMD:KECCAK-256_SVDW_RO_NUL_"
- Public key stored via SSTORE2 (bytecode deployment, immutable)
- hashToPoint maps round number to G1 using the DST
- verifySingle checks pairing: e(signature, -pubkey) * e(message, G2_generator) == 1
- Uses EIP-197 precompile (0x06)
- assert(callSuccess) ensures precompile never silently fails
- Randomness derivation: keccak256(signature[0], signature[1], chainId, address(this), requestId, requester)

Sound. Domain separation prevents cross-chain/cross-contract/cross-request correlation. BN254 verification is standard BLS signature verification.

### Access control review

| Function | Access | nonReentrant |
|---|---|---|
| requestRandomness | anyone | YES |
| fulfillRandomness | anyone | YES |
| withdrawETH | onlyOwner | NO |
| setBeacon | onlyOwner | NO |
| setRequestPremiumMultiplierBps | onlyOwner | NO |
| _authorizeUpgrade | onlyOwner | NO |

### CEI review

- requestRandomness: validates payment, stores commitment hash, emits event. No external calls. PASS.
- fulfillRandomness: checks state, verifies hash commitment, nullifies hash (anti-replay), verifies BLS signature, calls callback, updates state. ReentrancyGuard present. Anti-replay via hash nullification. PASS.
- withdrawETH: call{value} before effect, no guard. CONCERN (mitigated by onlyOwner).

---

## PART 3: Timing Analysis for Magic Potion

The fundamental difference from Chainlink VRF:

Chainlink VRF: randomness does not exist until your specific request is fulfilled. No one can know the outcome in advance.

drand: randomness is produced continuously every 3 seconds regardless of your request. When you request, you commit to a future round. That round's output is PUBLIC the moment it is produced. Anyone can see it via the HTTP API before it is submitted on-chain.

For a lottery this matters. The attack:
1. triggerDrawing commits to drand round N
2. Round N is produced at time T
3. Attacker fetches round N output from api.drand.sh
4. Attacker computes what the winning ticket hash will be
5. Attacker buys matching tickets before ticket sales close

MITIGATION (already in Magic Potion):
- DrawingManager.closeTicketSales runs inside triggerDrawing, BEFORE the randomness request
- Once triggerDrawing is called, the drawing state changes to CLOSED and no more tickets can be registered
- The window between drand round production and on-chain fulfillment is ~30 seconds (keeper latency)
- During that window, no tickets can be purchased because sales are already closed
- The attack is not possible

This makes drand viable for Magic Potion specifically because the drawing flow already provably closes ticket sales before requesting randomness.

---

## PART 4: Verdict and Integration Path

### drand: viable and recommended as an alternative

The drand protocol is sound, mature, and well-operated. The evmnet network exists specifically for EVM use. For Magic Potion's architecture (close sales -> request randomness -> open keeper fulfills), the timing attack is not exploitable.

### Anyrand: usable with modifications

The Anyrand contracts provide the missing EVM layer. The code is well-written and audited. However:

1. Deploy your own fork with UUPS removed (immutable implementation). Eliminates HIGH-1.
2. Add per-request ETH accounting. Fixes HIGH-2.
3. Keep receiveRandomness trivial. Avoids MED-1.
4. Use Ownable2Step. Fixes MED-2.

Or: deploy Anyrand as-is behind a multisig + timelock if you trust the upgrade path.

### Integration for Magic Potion

The frontend relay pattern (scoopy's conversation with Kevin Charm):
1. triggerDrawing on LuckyPotion closes ticket sales and calls anyrand.requestRandomness()
2. Frontend polls api.drand.sh/evmnet for the target round's signature
3. Once available (~3-30 seconds), frontend (or any keeper) calls anyrand.fulfillRandomness() with the beacon data
4. Anyrand verifies BLS on-chain, calls LuckyPotion.receiveRandomness()
5. Drawing resolves, keeper gets LUCK reward

This maps directly onto the existing open keeper system. The LUCK escalating reward incentivizes fulfillment. No LINK dependency. Pays in native ETH.

### For mainnet: deploy both Chainlink VRF and drand as dual paths

Magic Potion's DrawingManager can support both:
- Primary: Chainlink VRF (already integrated, 150/151 tests passing)
- Fallback: drand via Anyrand (if VRF fails or for L2 deployments)

Or go drand-only from the start if you're confident in the League of Entropy's liveness (which has been >99.99% since 2020).
