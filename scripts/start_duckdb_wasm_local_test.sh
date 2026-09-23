#!/usr/bin/env bash
# Local-only DuckDB-Wasm harness, following DuckHTS's loopback/COOP/COEP setup.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
NODE_DIR="$ROOT/.deps-port/wasm-node"
mkdir -p "$NODE_DIR"
cp test/wasm/package.json test/wasm/package-lock.json "$NODE_DIR/"
npm ci --prefix "$NODE_DIR" --no-audit --no-fund
if [[ ! -e test/wasm/node_modules ]]; then
    ln -s ../../.deps-port/wasm-node/node_modules test/wasm/node_modules
fi
if [[ ${1:-} == --test ]]; then
    bash scripts/build_wasm_panic_probe.sh
    "$NODE_DIR/node_modules/.bin/playwright" install chromium
    cd test/wasm
    exec ./node_modules/.bin/playwright test
fi
exec node test/wasm/server.mjs
