#!/usr/bin/env bash
# Deploy group_treasury contract to a Stellar network (default: testnet).
#
# Network configuration:
#   NETWORK         Stellar CLI network name (default: testnet). Set to futurenet,
#                   a configured quickstart network, mainnet, or public as needed.
#   CONFIRM_MAINNET Must be "yes" when NETWORK is mainnet or public.
#
# Prerequisites:
#   - stellar CLI installed  (https://developers.stellar.org/docs/tools/stellar-cli)
#   - DEPLOYER_SECRET env var set (Stellar secret key of the deployer/admin account)
#   - Optional THRESHOLD env var (required approvals, defaults to 1, max 4294967295)
#
# Usage:
#   DEPLOYER_SECRET=S... THRESHOLD=2 ./scripts/deploy_group_treasury.sh
#   NETWORK=futurenet DEPLOYER_SECRET=S... THRESHOLD=2 ./scripts/deploy_group_treasury.sh

set -euo pipefail

NETWORK="${NETWORK:-testnet}"
THRESHOLD="${THRESHOLD-1}"
WASM_PATH="target/wasm32-unknown-unknown/release/group_treasury.wasm"

if [[ "$NETWORK" == "mainnet" || "$NETWORK" == "public" ]] && [[ "${CONFIRM_MAINNET:-}" != "yes" ]]; then
  echo "Error: refusing to deploy to $NETWORK without CONFIRM_MAINNET=yes" >&2
  exit 1
fi

if [[ -z "${DEPLOYER_SECRET:-}" ]]; then
  echo "Error: DEPLOYER_SECRET is not set" >&2
  exit 1
fi

if [[ ! "$THRESHOLD" =~ ^[1-9][0-9]{0,9}$ ]] || (( THRESHOLD > 4294967295 )); then
  echo "Error: THRESHOLD must be an integer from 1 to 4294967295" >&2
  exit 1
fi

echo "==> Target network: $NETWORK"

echo "==> Building contract..."
cargo build -p group_treasury --target wasm32-unknown-unknown --release

echo "==> Uploading WASM to $NETWORK..."
WASM_HASH=$(stellar contract upload \
  --network "$NETWORK" \
  --source "$DEPLOYER_SECRET" \
  --wasm "$WASM_PATH")

echo "    WASM hash: $WASM_HASH"

echo "==> Deploying contract instance..."
CONTRACT_ID=$(stellar contract deploy \
  --network "$NETWORK" \
  --source "$DEPLOYER_SECRET" \
  --wasm-hash "$WASM_HASH")

echo "    Contract ID: $CONTRACT_ID"

ADMIN_PUBLIC=$(stellar keys public-key --secret-key "$DEPLOYER_SECRET")

echo "==> Initialising contract..."
stellar contract invoke \
  --network "$NETWORK" \
  --source "$DEPLOYER_SECRET" \
  --id "$CONTRACT_ID" \
  -- initialize \
  --admin "$ADMIN_PUBLIC" \
  --threshold "$THRESHOLD"

echo ""
echo "group_treasury deployed and initialised"
echo "  Contract ID : $CONTRACT_ID"
echo "  Threshold   : $THRESHOLD"
echo "  Admin       : $ADMIN_PUBLIC"
echo ""
echo "Add to your .env:"
echo "  GROUP_TREASURY_CONTRACT_ID=$CONTRACT_ID"
