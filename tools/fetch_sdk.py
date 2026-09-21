#!/usr/bin/env python3
"""Fetch an explicitly pinned SDK at build time; never used at extension runtime."""
from pathlib import Path
import sys
from urllib.request import urlopen

REVISION = "fece4143738e2b1d05a851d5c5dc036838aff8ec"
HEADERS = ("duckdb_v2.h", "duckdb_extension_v2.h")

def main():
    if len(sys.argv) != 2:
        raise SystemExit("usage: fetch_sdk.py OUTPUT_DIRECTORY")
    target = Path(sys.argv[1])
    target.mkdir(parents=True, exist_ok=True)
    for name in HEADERS:
        url = f"https://raw.githubusercontent.com/duckdb/duckdb/{REVISION}/src/include/{name}"
        with urlopen(url, timeout=60) as response:
            data = response.read()
        if b"duckdb_v2_" not in data:
            raise RuntimeError(f"not a DuckDB C API v2 header: {name}")
        staging = target / (name + ".tmp")
        staging.write_bytes(data)
        staging.replace(target / name)
    (target / "REVISION").write_text(REVISION + "\n")
    print(f"DuckDB v2 SDK: {REVISION} -> {target}")

if __name__ == "__main__":
    main()
