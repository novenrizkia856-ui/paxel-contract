#!/usr/bin/env bash
# Deploys PaxelRegistry, PaxelEventLog and PaxelAttestationRegistry to Robinhood Chain mainnet.
#
#   1. Paste the deployer private key after PRIVATE_KEY= in .env
#   2. bash deploy-mainnet.sh
#
# Runs the tests and a dry run first, then broadcasts. The addresses land in deployments/mainnet.json.
# Then, in paxel-web: npm run contracts:sync
set -euo pipefail
cd "$(dirname "$0")"
export PATH="$HOME/.foundry/bin:$PATH"

[ -f .env ] || { echo "Missing .env. Copy .env.example to .env first."; exit 1; }
grep -Eq '^PRIVATE_KEY=(0x)?[0-9a-fA-F]{64}[[:space:]]*$' .env || { echo "Fill PRIVATE_KEY in .env first (64 hex characters)."; exit 1; }
set -a; . ./.env; set +a
[ "$CHAIN_ID" = "4663" ] || { echo "CHAIN_ID in .env must be 4663 for mainnet."; exit 1; }
[ "$DEPLOY_NETWORK" = "mainnet" ] || { echo "DEPLOY_NETWORK in .env must be mainnet."; exit 1; }

DEPLOYER=$(cast wallet address "$PRIVATE_KEY")
BALANCE=$(cast balance "$DEPLOYER" --rpc-url "$RPC_URL" --ether)
echo "Deployer $DEPLOYER holds $BALANCE ETH on Robinhood Chain"

forge test
forge script script/Deploy.s.sol --rpc-url "$RPC_URL"
forge script script/Deploy.s.sol --rpc-url "$RPC_URL" --broadcast --slow

echo
cat deployments/mainnet.json
