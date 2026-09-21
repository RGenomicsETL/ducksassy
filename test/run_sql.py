#!/usr/bin/env python3
"""Real CLI integration test. Requires a v2-capable DuckDB and network for DuckHTS install."""
from pathlib import Path
import argparse
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
def quote(text):
    return "'" + str(text).replace("'", "''") + "'"
def execute(cli, sql):
    return subprocess.run([str(cli), '-unsigned', '-batch', '-bail', ':memory:'],
        input=sql, text=True, cwd=ROOT, capture_output=True, timeout=300)
def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--duckdb', type=Path, required=True)
    parser.add_argument('--extension', type=Path, required=True)
    args = parser.parse_args()
    cli, extension = args.duckdb.resolve(), args.extension.resolve()
    bootstrap = (ROOT / 'sql/ducksassy.sql').read_text()
    with tempfile.TemporaryDirectory(prefix='ducksassy-test-') as directory:
        setup = f"SET extension_directory={quote(directory)};\n"
        install = setup + f"INSTALL {quote(extension)}; INSTALL duckhts FROM community;\n"
        completed = execute(cli, install + bootstrap + (ROOT / 'test/sql/smoke.sql').read_text())
        if completed.returncode:
            raise SystemExit(completed.stdout + completed.stderr)
        errors = [
            ("SELECT sassy_matches('', 'ACGA', 0);", 'patterns must'),
            ("SELECT sassy_matches('ACGA', 'ACGA', -1);", 'nonnegative'),
            ("SELECT sassy_matches('ACGA', 'NNNN', 0, alphabet := 'dna');", 'invalid sequence alphabet'),
            ("SELECT sassy_matches_many(['ACGA', NULL], 'ACGA', 0);", 'NULL elements'),
            ("SELECT sassy_matches('ACGA', 'ACGA', 0, max_text_bytes := 3);", 'max_text_bytes'),
            ("SELECT sassy_matches('A', 'AAAA', 0, rc := false, all_endpoints := true, max_hits := 1);", 'max_hits'),
        ]
        for sql, expected in errors:
            failed = execute(cli, setup + bootstrap + sql)
            if failed.returncode == 0 or expected not in failed.stderr:
                raise AssertionError(f'expected error {expected!r}: {failed.stdout}\n{failed.stderr}')
        # Isolated extension directory: public bootstrap must not proceed without DuckHTS.
        with tempfile.TemporaryDirectory(prefix='ducksassy-no-dependency-') as missing:
            failed = execute(cli, f"SET extension_directory={quote(missing)};\n" + bootstrap)
            if failed.returncode == 0 or 'duckhts' not in failed.stderr.lower():
                raise AssertionError('missing DuckHTS did not fail the bootstrap')
    print('Real DuckDB/DuckHTS SQL integration tests passed')
if __name__ == '__main__':
    main()
