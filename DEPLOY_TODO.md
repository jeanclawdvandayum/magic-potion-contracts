============================================================
 MAGIC POTION - PRODUCTION DEPLOYMENT TODO
============================================================

CONFIRMED ADDRESSES (from control.alchemix.fi):

  USDC                  0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48
  alUSD                 0xBC6DA0FE9aD5f3b0d58160288917AA56653660E9
  AlchemistV3           0xeB83112d925268BeDe86654C13D423a987587e3E
  Position NFT          0x872a03FabC86b59c883CD9c439E969321b719bEB
  MYT Vault             0x9B44efCa3e2a707B63Dc00CE79d646E5E5D24bA5
  VRF Coordinator V2.5  0x50e47677a03e54D66c258BA18367D7122B5d21bE


============================================================
 BLOCKER: V3 INTERFACE REWRITE (must do before anything else)
============================================================

The contracts were written against a guessed V3 interface that does
not match the real thing. Pulled the actual source from
github.com/alchemix-finance/v3 and found major differences.

DONE:
  - Updated IAlchemistV3.sol to match real V3 signatures
  - Created .env.example with all confirmed addresses
  - Documented VRF coordinator + key hash options

TODO:

  1. Rewrite LuckyPotion for NFT-based positions
     V3 uses tokenId (position NFT) not address for all operations.
     deposit() returns a tokenId on first call, reused after that.
     LuckyPotion needs to store its positionTokenId after first deposit
     and pass it to every subsequent deposit/mint/query.

  2. Rewrite buyTicket() flow
     Current: takes USDC, approves Alchemist, calls deposit(yieldToken, amount, this)
     Real:    deposit takes yield tokens (MYT shares) not USDC
              need to figure out the USDC -> yield token wrapping step
              either the token adapter handles it automatically, or we
              deposit USDC into MYT vault first to get shares, then deposit those

  3. Rewrite triggerDrawing() mint call
     Current: mint(amount, address(this))
     Real:    mint(tokenId, amount, recipient)

  4. Replace protocolStats() queries
     Current: totalValue(address), debt(address)
     Real:    getCDP(tokenId) returns (collateral, debt, earmarked)
              totalValue(tokenId), getMaxBorrowable(tokenId)

  5. Rewrite MockAlchemistV3.sol to match real interface
     All 151 tests will break until this is done.

  6. Re-run all tests, fix failures
  7. Run on mainnet fork with real V3 addresses
  8. Re-run slither after changes


============================================================
 CHAINLINK VRF
============================================================

DONE:
  - Coordinator address confirmed
  - Key hash options documented in .env.example

TODO:

  9.  Create VRF subscription at vrf.chain.link
  10. Fund subscription with LINK
  11. After deploy, add LuckyPotion as authorized consumer
  12. Verify our IVRFCoordinatorV2Plus matches V2.5 exactly
  13. Test full VRF request -> callback flow on a fork
  14. Confirm callbackGasLimit of 500k is sufficient
  15. Confirm requestConfirmations of 3 is right for mainnet


============================================================
 TREASURY
============================================================

TODO:

  16. Deploy a Gnosis Safe (recommend 2/3 or 3/5 signers)
  17. Put Safe address in .env as TREASURY_ADDRESS
  18. After deploy: call transferOwnership(safe)
  19. Call acceptOwnership() from the Safe
  20. Verify Safe can call all admin functions


============================================================
 TESTING
============================================================

TODO:

  21. forge test --gas-report (after V3 rewrite)
  22. forge coverage (target 90%+ on src/)
  23. forge script script/Deploy.s.sol --rpc-url (dry run, no broadcast)
  24. Verify all 6 contracts deploy at predicted addresses
  25. Test full lifecycle on mainnet fork:
      buy ticket -> trigger drawing -> VRF resolves -> finalize -> claim
  26. Test keeper reward escalation
  27. Test fee split (83/12/5) with real alUSD decimals
  28. Test LUCK staking epoch system
  29. Final slither run


============================================================
 AUDIT
============================================================

DONE:
  - evm-cortex rules applied (pragma fixed, Ownable2Step, forceApprove,
    immutable vars, unchecked loops, custom errors, SafeERC20)
  - Slither: 0 HIGH/MEDIUM, 31 INFO-level findings

TODO:

  30. Get formal audit from a firm (Pashov, Spearbit, Sherlock, etc)
  31. Re-run slither after the V3 rewrite
  32. Consider Aderyn as second static analyzer
  33. Set up Immunefi bug bounty post-launch


============================================================
 DEPLOY
============================================================

TODO:

  34. Dry run: forge script script/Deploy.s.sol --rpc-url $RPC
  35. Verify address prediction is correct
  36. Deploy: forge script script/Deploy.s.sol --rpc-url $RPC --broadcast
  37. Verify all 6 contracts on Etherscan (forge verify-contract)
  38. Add LuckyPotion address as VRF consumer
  39. Call initialize() to start first drawing
  40. Test a $5 ticket purchase from the Safe
  41. Transfer ownership to Safe (2-step: propose + accept)


============================================================
 KEEPER BOT
============================================================

TODO:

  42. Write a simple script that polls LuckyPotion.getCurrentDrawing()
      every block, checks timestamps, calls triggerDrawing/finalizeDrawing
  43. Deploy on a cheap server or raspberry pi
  44. The escalating LUCK reward means anyone can run this
  45. Multiple independent keepers = more resilient
  46. No gas funding needed (keeper pays gas, earns LUCK)


============================================================
 POST-DEPLOY
============================================================

TODO:

  47. Monitor first drawing lifecycle end to end
  48. Update frontend with deployed addresses
  49. Fix HTML title (still says "Stellar Lottery")
  50. Get production WalletConnect project ID
  51. Deploy frontend to permanent hosting
  52. Set up subgraph or event indexing
  53. Test full buy -> draw -> claim on mainnet
