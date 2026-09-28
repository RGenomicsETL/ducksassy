#!/usr/bin/env python3
"""Check functions.yaml against the rendered reference and the released v1 artifact.

Without --duckdb/--extension only the rendered documents are checked.
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
import render_function_catalog as catalog  # noqa: E402


def run_sql(duckdb: str, extension: str, sql: str) -> str:
    result = subprocess.run([duckdb, "-unsigned", "-no-init", "-json", "-c",
                             f"LOAD '{extension}';\n{sql}"],
                            capture_output=True, text=True, timeout=120)
    if result.returncode != 0 or "Error" in result.stderr:
        raise AssertionError(f"SQL failed:\n{sql}\n{result.stderr}")
    return result.stdout


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--duckdb")
    parser.add_argument("--extension")
    args = parser.parse_args()

    manifest = catalog.load_manifest(ROOT / "functions.yaml")
    functions = manifest["functions"]
    expected = catalog.render_reference(functions)
    if (ROOT / "docs" / "functions.md").read_text(encoding="utf-8") != expected:
        raise AssertionError("docs/functions.md is stale; run make function_catalog")

    descriptor = catalog.render_description_yaml(ROOT, manifest, "0.0.0-check")
    try:
        import yaml  # optional: validates the descriptor when PyYAML is present
    except ImportError:
        yaml = None
    if yaml is not None:
        parsed = yaml.safe_load(descriptor)
        assert parsed["extension"]["name"] == manifest["community_extension"]["extension"]["name"]
        assert parsed["docs"]["hello_world"].strip() and parsed["docs"]["extended_description"].strip()

    if not args.duckdb:
        print(f"Function catalog renders cleanly ({len(functions)} functions)")
        return 0
    extension = str(Path(args.extension).resolve())
    rows = json.loads(run_sql(args.duckdb, extension,
        "SELECT DISTINCT function_name, function_type FROM duckdb_functions() "
        "WHERE function_name LIKE 'sassy\\_%' ESCAPE '\\' ORDER BY 1;"))
    registered = {row["function_name"]: row["function_type"] for row in rows}
    documented = {entry["name"]: entry["kind"] for entry in functions}
    if registered != documented:
        raise AssertionError(f"Catalog and registered functions differ:\n"
                             f"  undocumented: {sorted(set(registered) - set(documented))}\n"
                             f"  not registered: {sorted(set(documented) - set(registered))}\n"
                             f"  kind mismatch: {sorted(k for k in registered.keys() & documented.keys() if registered[k] != documented[k])}")
    hello = "\n".join(line for line in manifest["community_extension"]["docs"]["hello_world_lines"]
                      if not line.startswith("LOAD "))
    run_sql(args.duckdb, extension, hello)
    for entry in functions:
        for example in entry["examples"]:
            run_sql(args.duckdb, extension, example)
    count = sum(len(entry["examples"]) for entry in functions)
    print(f"Function catalog matches {len(registered)} registered functions; "
          f"hello_world and {count} examples ran")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
