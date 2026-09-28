#!/usr/bin/env python3
"""Fetch and verify released stable v1 headers outside the shared .deps tree."""
from pathlib import Path
import argparse
import hashlib
import json
import urllib.request

root = Path(__file__).resolve().parents[1]
pin = json.loads((root / 'ducksassy-package.json').read_text())['v1_host']
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('destination', nargs='?', type=Path, default=root / '.deps-v1/sdk')
target = parser.parse_args().destination
target.mkdir(parents=True, exist_ok=True)
for name, expected in pin['sdk_sha256'].items():
    url = f"https://raw.githubusercontent.com/duckdb/duckdb/{pin['duckdb_version']}/src/include/{name}"
    with urllib.request.urlopen(url, timeout=60) as response:
        content = response.read()
    if hashlib.sha256(content).hexdigest() != expected:
        raise SystemExit(f'{name}: SDK checksum mismatch')
    (target / name).write_bytes(content)
print(f"Verified {pin['duckdb_version']} stable {pin['extension_api_version']} SDK in {target}")
