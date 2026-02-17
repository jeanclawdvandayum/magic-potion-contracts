#!/bin/bash
# Deploy Magic Potion to local Anvil testnet
set -e

RPC="http://127.0.0.1:8545"
PK="ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
DEPLOYER="0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"

deploy() {
  forge create --broadcast --rpc-url $RPC --private-key $PK "$@" 2>&1 | grep 'Deployed to:' | awk '{print $3}'
}

echo "🧪 Deploying Magic Potion to Anvil..."

USDC=$(deploy test/mocks/MockERC20.sol:MockERC20 --constructor-args "USD Coin" "USDC" 6)
echo "USDC: $USDC"

ALUSD=$(deploy test/mocks/MockERC20.sol:MockERC20 --constructor-args "Alchemix USD" "alUSD" 18)
echo "alUSD: $ALUSD"

ALCHEMIST=$(deploy test/mocks/MockAlchemistV3.sol:MockAlchemistV3 --constructor-args $ALUSD $USDC)
echo "Alchemist: $ALCHEMIST"

VRFC=$(deploy test/mocks/MockVRFCoordinator.sol:MockVRFCoordinator)
echo "VRFCoordinator: $VRFC"

YIELD_TOKEN="0x000000000000000000000000000000000000bEEF"

# Predict coordinator address
NONCE=$(cast nonce $DEPLOYER --rpc-url $RPC)
PREDICTED=$(cast compute-address $DEPLOYER --nonce $((NONCE + 5)) 2>&1 | grep -oE '0x[0-9a-fA-F]{40}')
echo "Predicted coordinator: $PREDICTED"

DM=$(deploy src/DrawingManager.sol:DrawingManager --constructor-args $VRFC $PREDICTED 1 "0x0000000000000000000000000000000000000000000000000000000000000001" 500000 3)
echo "DrawingManager: $DM"

NFT=$(deploy src/TicketNFT.sol:TicketNFT --constructor-args $PREDICTED)
echo "TicketNFT: $NFT"

LUCK=$(deploy src/LuckToken.sol:LuckToken --constructor-args $PREDICTED)
echo "LuckToken: $LUCK"

STAKING=$(deploy src/LuckStaking.sol:LuckStaking --constructor-args $LUCK $ALUSD $PREDICTED)
echo "LuckStaking: $STAKING"

VAULT=$(deploy src/PrizeVault.sol:PrizeVault --constructor-args $ALUSD $PREDICTED)
echo "PrizeVault: $VAULT"

COORD=$(deploy src/LuckyPotion.sol:LuckyPotion --constructor-args $USDC $ALUSD $ALCHEMIST $YIELD_TOKEN $NFT $LUCK $STAKING $DM $VAULT $DEPLOYER)
echo "LuckyPotion: $COORD"

if [ "$COORD" != "$PREDICTED" ]; then
  echo "❌ Address mismatch! Expected $PREDICTED got $COORD"
  exit 1
fi

# Initialize
cast send --private-key $PK --rpc-url $RPC $COORD "initialize()" > /dev/null 2>&1
echo "✅ Protocol initialized"

# Mint USDC & approve
cast send --private-key $PK --rpc-url $RPC $USDC "mint(address,uint256)" $DEPLOYER 100000000000 > /dev/null 2>&1
cast send --private-key $PK --rpc-url $RPC $USDC "approve(address,uint256)" $COORD $(cast max-uint) > /dev/null 2>&1
echo "✅ Minted 100k USDC to deployer"

# Output JSON
OUTDIR="$(cd "$(dirname "$0")/.." && pwd)/deployments"
mkdir -p "$OUTDIR"
cat > "$OUTDIR/local.json" << EOF
{
  "chainId": 31337,
  "coordinator": "$COORD",
  "usdc": "$USDC",
  "alUSD": "$ALUSD",
  "alchemist": "$ALCHEMIST",
  "vrfCoordinator": "$VRFC",
  "ticketNFT": "$NFT",
  "luckToken": "$LUCK",
  "luckStaking": "$STAKING",
  "drawingManager": "$DM",
  "prizeVault": "$VAULT"
}
EOF

echo ""
echo "🧪 === DEPLOYMENT COMPLETE ==="
cat "$OUTDIR/local.json"
