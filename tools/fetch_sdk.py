#!/usr/bin/env python3
"""Stage checksum-verified SDK headers before the network-free extension build."""
from pathlib import Path
import hashlib
import json
import sys
from urllib.request import urlopen

PACKAGE = json.loads((Path(__file__).resolve().parents[1] / "ducksassy-package.json").read_text())
REVISION = PACKAGE["duckdb_sdk_revision"]
HEADERS = PACKAGE["duckdb_sdk_sha256"]

def main():
    if len(sys.argv) != 2:
        raise SystemExit("usage: fetch_sdk.py OUTPUT_DIRECTORY")
    target = Path(sys.argv[1])
    target.mkdir(parents=True, exist_ok=True)
    for name, expected in HEADERS.items():
        existing = target / name
        if existing.exists() and hashlib.sha256(existing.read_bytes()).hexdigest() == expected:
            continue
        url = f"https://raw.githubusercontent.com/duckdb/duckdb/{REVISION}/src/include/{name}"
        with urlopen(url, timeout=60) as response:
            data = response.read()
        if hashlib.sha256(data).hexdigest() != expected:
            raise RuntimeError(f"SDK checksum mismatch: {name}")
        staging = target / (name + ".tmp")
        staging.write_bytes(data)
        staging.replace(target / name)
    (target / "REVISION").write_text(REVISION + "\n")
    print(f"DuckDB v2 SDK: {REVISION} -> {target}")

if __name__ == "__main__":
    main()
