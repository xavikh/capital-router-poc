#!/usr/bin/env bash
# Starts an Anvil fork of Sepolia (unless one is running), deploys the playground to it (unless it's
# already there) and serves the UI at http://127.0.0.1:5173/playground/
set -euo pipefail
cd "$(dirname "$0")/.."

ANVIL=http://127.0.0.1:8545
FORK_URL=${FORK_URL:-https://ethereum-sepolia-rpc.publicnode.com}
UI_PORT=${UI_PORT:-5173}

if ! cast block-number --rpc-url "$ANVIL" >/dev/null 2>&1; then
  echo "Starting an Anvil fork of Sepolia from $FORK_URL"
  # Pinned to Prague: forge's gas estimates undershoot contract creation on Sepolia's newer hardforks
  anvil --fork-url "$FORK_URL" --hardfork prague --silent &
  ANVIL_PID=$!
  trap 'kill $ANVIL_PID' EXIT
  until cast block-number --rpc-url "$ANVIL" >/dev/null 2>&1; do sleep 1; done
fi

forge build
python3 playground/abis.py

DAO=$(python3 -c 'import json; print(json.load(open("playground/deployment.json"))["dao"])' 2>/dev/null || true)
if [ -z "$DAO" ] || [ "$(cast code "$DAO" --rpc-url "$ANVIL")" = "0x" ]; then
  forge script script/playground/Playground.s.sol --sig "play()" --rpc-url "$ANVIL" --broadcast --slow
else
  echo "Playground already deployed (DAO $DAO)"
fi

echo
echo "Open http://127.0.0.1:$UI_PORT/playground/"
python3 -m http.server "$UI_PORT" --bind 127.0.0.1
