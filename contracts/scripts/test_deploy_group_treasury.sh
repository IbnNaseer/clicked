#!/usr/bin/env bash
# Exercise deployment argument wiring without building or contacting a network.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
LOG=$(mktemp)
trap 'rm -f "$LOG"' EXIT
export LOG

cargo() { echo "cargo $*" >> "$LOG"; }
stellar() {
  echo "stellar $*" >> "$LOG"
  case "$1 $2" in
    'contract upload') echo mock-wasm-hash ;;
    'contract deploy') echo mock-contract ;;
    'keys public-key') echo mock-admin ;;
  esac
}
export -f cargo stellar

for threshold in 1 2 4294967295; do
  : > "$LOG"
  env -u TOKEN_CONTRACT_ID DEPLOYER_SECRET=mock-secret THRESHOLD="$threshold" \
    NETWORK=testnet bash "$SCRIPT_DIR/deploy_group_treasury.sh" > /dev/null
  grep -Fq -- "-- initialize --admin mock-admin --threshold $threshold" "$LOG"
  if grep -Fq -- '--token' "$LOG"; then
    echo 'Unexpected token argument' >&2
    exit 1
  fi
done

for threshold in '' 0 -1 1.5 abc 01 4294967296 999999999999999999999; do
  : > "$LOG"
  if DEPLOYER_SECRET=mock-secret THRESHOLD="$threshold" NETWORK=testnet \
    bash "$SCRIPT_DIR/deploy_group_treasury.sh" > /dev/null 2>&1; then
    echo "Unexpected success for threshold '$threshold'" >&2
    exit 1
  fi
  test ! -s "$LOG" # Reject invalid input before any build or deployment.
done

: > "$LOG"
output=$(env -u THRESHOLD DEPLOYER_SECRET=mock-secret NETWORK=testnet \
  bash "$SCRIPT_DIR/deploy_group_treasury.sh")
grep -Fq -- '-- initialize --admin mock-admin --threshold 1' "$LOG"
grep -Fq -- 'Threshold   : 1' <<< "$output"

echo 'Deployment argument checks passed (explicit, invalid, and default thresholds).'
