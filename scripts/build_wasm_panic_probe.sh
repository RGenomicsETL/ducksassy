#!/usr/bin/env bash
# Build a test-only extension using the same Rust std and side-module link ABI.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .deps-port/panic-probe
rustc --target wasm32-unknown-emscripten -C relocation-model=pic -C opt-level=3 \
    --crate-type staticlib test/wasm/panic_probe.rs -o .deps-port/panic-probe/libpanicprobe.a
for variant in wasm_mvp wasm_eh; do
    flags=()
    if [[ $variant == wasm_eh ]]; then flags+=(-fwasm-exceptions); fi
    output="${DUCKSASSY_WASM_ARTIFACT_DIR:-.deps-port/artifacts}/$variant"
    mkdir -p "$output"
    emcc -I configure/sdk-v1 test/wasm/panic_probe.c .deps-port/panic-probe/libpanicprobe.a \
        "${flags[@]}" -O1 -sSIDE_MODULE=2 -sEXPORTED_FUNCTIONS=_panicprobe_init_c_api \
        -o .deps-port/panic-probe/panicprobe.wasm
    python3 extension-ci-tools/scripts/append_extension_metadata.py \
        -l .deps-port/panic-probe/panicprobe.wasm -o "$output/panicprobe.duckdb_extension.wasm" \
        -n panicprobe -dv v1.2.0 -ev 0.0.0 -p "$variant"
done
