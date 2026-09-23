#!/usr/bin/env python3
"""Offline integration tests using a matching v2 host and staged extensions."""
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
    parser.add_argument('--duckdb', type=Path, default=ROOT / '.deps/duckdb-build/duckdb')
    parser.add_argument('--extension', type=Path, default=ROOT / 'build/ducksassy.duckdb_extension')
    parser.add_argument('--duckhts', type=Path, default=ROOT / '.deps/duckhts.duckdb_extension')
    args = parser.parse_args()
    cli, extension = args.duckdb.resolve(), args.extension.resolve()
    duckhts = args.duckhts.resolve()
    bootstrap = (ROOT / 'sql/ducksassy.sql').read_text()
    with tempfile.TemporaryDirectory(prefix='ducksassy-test-') as directory:
        compatibility = (
            "SET autoinstall_known_extensions=false;\n"
            "SET autoload_known_extensions=false;\n"
            # DuckHTS registers its SQL helpers on a separate connection.
            "SET GLOBAL lambda_syntax='ENABLE_SINGLE_ARROW';\n"
        )
        setup = compatibility + f"SET extension_directory={quote(directory)};\n"
        install = setup + f"INSTALL {quote(extension)}; INSTALL {quote(duckhts)};\n"
        conformance = '\n'.join(path.read_text() for path in sorted((ROOT / 'test/sql').glob('*.sql')))
        completed = execute(cli, install + bootstrap + conformance)
        if completed.returncode:
            raise SystemExit(completed.stdout + completed.stderr)
        # DuckDB must stop pulling the table scan after its first result.
        # A full scan reaches the late non-ASCII byte and fails validation.
        late_invalid = "'error' || repeat('x', 5000) || 'é'"
        first_query = (
            "SELECT CASE WHEN (SELECT text_start "
            f"FROM sassy_grep('error', {late_invalid}, 0) LIMIT 1) = 0 "
            "THEN true ELSE error('wrong first grep hit') END;"
        )
        first_hit = execute(cli, setup + bootstrap + first_query)
        if first_hit.returncode:
            raise AssertionError(f'LIMIT did not stop the grep scan: {first_hit.stdout}\n{first_hit.stderr}')
        full_scan = execute(cli, setup + bootstrap +
            f"SELECT * FROM sassy_grep('error', {late_invalid}, 0);")
        if full_scan.returncode == 0 or 'invalid sequence alphabet' not in full_scan.stderr:
            raise AssertionError('full grep scan did not reach the late invalid byte')
        errors = [
            ("SELECT sassy_matches('', 'ACGA', 0);", 'patterns must'),
            ("SELECT sassy_matches('ACGA', 'ACGA', -1);", 'nonnegative'),
            ("SELECT sassy_matches('ACGA', 'NNNN', 0, alphabet := 'dna');", 'invalid sequence alphabet'),
            ("SELECT sassy_matches_many(['ACGA', NULL], 'ACGA', 0);", 'NULL elements'),
            ("SELECT sassy_matches('ACGA', 'ACGA', 0, cigar_format := 'legacy');", 'text, packed, or both'),
            ("SELECT sassy_crispr_matches('ACGTNGG', 'ACGTAGG', 0, pam_length := 0);", 'pam_length'),
            ("SELECT sassy_crispr_matches('ACGTNGG', 'ACGTAGG', 0, pam_length := 8);", 'PAM length'),
            ("SELECT sassy_crispr_matches('ACGTNGG', 'ACGTAGG', 0, max_n_frac := -0.1);", 'max_n_frac'),
            ("SELECT sassy_crispr_matches('ACGTNGG', 'ACGTAGG', 0, max_n_frac := 1.0000000001);", 'max_n_frac'),
            ("SELECT sassy_crispr_matches('ACGTNGG', 'ACGTAGG', 0, max_n_frac := 'NaN'::DOUBLE);", 'max_n_frac'),
            ("SELECT sassy_crispr_matches_many(['ACGTNGG', 'ACGTNGA'], 'ACGTAGG', 0);", 'identical PAM'),
            ("SELECT sassy_crispr_matches_many(['ACGTNGG', NULL], 'ACGTAGG', 0);", 'NULL elements'),
        ]
        for sql, expected in errors:
            failed = execute(cli, setup + bootstrap + sql)
            if failed.returncode == 0 or expected not in failed.stderr:
                raise AssertionError(f'expected error {expected!r}: {failed.stdout}\n{failed.stderr}')
        # Isolated extension directory: public bootstrap must not proceed without DuckHTS.
        with tempfile.TemporaryDirectory(prefix='ducksassy-no-dependency-') as missing:
            failed = execute(cli, compatibility + f"SET extension_directory={quote(missing)};\n" + bootstrap)
            if failed.returncode == 0 or 'duckhts' not in failed.stderr.lower():
                raise AssertionError('missing DuckHTS did not fail the bootstrap')
            if 'Failed to download extension' in failed.stderr:
                raise AssertionError(f'missing dependency attempted network access: {failed.stderr}')
    print('Real DuckDB/DuckHTS SQL integration tests passed')
if __name__ == '__main__':
    main()
