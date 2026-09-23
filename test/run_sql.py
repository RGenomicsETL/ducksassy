#!/usr/bin/env python3
"""Offline integration tests for v1/v2 hosts and staged extensions."""
from pathlib import Path
import argparse
import shutil
import re
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
    parser.add_argument('--host', choices=('v1', 'v2'), default='v2')
    parser.add_argument('--duckdb', type=Path, default=ROOT / '.deps/duckdb-build/duckdb')
    parser.add_argument('--extension', type=Path, default=ROOT / 'build/ducksassy.duckdb_extension')
    parser.add_argument('--duckhts', type=Path, default=ROOT / '.deps/duckhts.duckdb_extension')
    args = parser.parse_args()
    cli, extension = args.duckdb.resolve(), args.extension.resolve()
    duckhts = args.duckhts.resolve()
    bootstrap = ((ROOT / 'sql/ducksassy.sql').read_text() if args.host == 'v2' else
                 'LOAD duckhts; LOAD ducksassy;\n' + (ROOT / 'test/v1_scalar_helpers.sql').read_text())
    def common_sql(sql):
        if args.host == 'v1':
            sql = re.sub(r'\bsassy_(matches|count|contains|crispr_matches)(_many)?(?=\()',
                         r'sassy_\1\2_opts', sql)
            sql = sql.replace('SELECT UNNEST(__sassy_backend_info()) AS backend FROM range(8193)',
                              'SELECT b AS backend FROM range(8193) CROSS JOIN sassy_backend_info() b')
        return sql
    with tempfile.TemporaryDirectory(prefix='ducksassy-test-') as directory:
        compatibility = (
            "SET autoinstall_known_extensions=false;\n"
            "SET autoload_known_extensions=false;\n"
        )
        if args.host == 'v2':
            # DuckHTS registers its SQL helpers on a separate connection.
            compatibility += "SET GLOBAL lambda_syntax='ENABLE_SINGLE_ARROW';\n"
        setup = compatibility + f"SET extension_directory={quote(directory)};\n"
        install = setup + f"INSTALL {quote(extension)}; INSTALL {quote(duckhts)};\n"
        fixtures = sorted((ROOT / 'test/sql').glob('*.sql')) if args.host == 'v2' else [
            ROOT / 'test/sql' / name for name in
            ('backend_info.sql', 'grep.sql', 'output_growth.sql', 'packed_cigar.sql')]
        conformance = common_sql('\n'.join(path.read_text() for path in fixtures))
        if args.host == 'v1':
            conformance += (ROOT / 'test/v1_sources.sql').read_text()
        completed = execute(cli, install + bootstrap + conformance)
        if completed.returncode:
            raise SystemExit(completed.stdout + completed.stderr)
        quoted_fastq = Path(directory) / "reads';SELECT error('path injection');--.fastq"
        shutil.copyfile(ROOT / 'test/data/reads.fastq', quoted_fastq)
        source = (f"sassy_search_fastq({quote(quoted_fastq)}, 'ACGA', 0, rc := false)" if args.host == 'v2' else
                  f"read_fastq({quote(quoted_fastq)}) r CROSS JOIN LATERAL "
                  "unnest(sassy_matches('ACGA', r.sequence, 0, 'iupac', false)) AS hits(hit)")
        quoted = execute(cli, setup + bootstrap +
            f"SELECT CASE WHEN count(*) = 2 THEN true ELSE error('quoted path') END FROM {source};")
        if quoted.returncode:
            raise AssertionError(quoted.stdout + quoted.stderr)
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
            ("SELECT sassy_matches('AA', repeat('A',1048580),0,rc:=false,all_endpoints:=true);", 'chunk exceeds'),
            ("SELECT * FROM sassy_grep(NULL, 'error', 0);", 'arguments cannot be NULL'),
            ("SELECT * FROM sassy_grep('', 'error', 0);", 'pattern must contain'),
            ("SELECT * FROM sassy_grep('é', 'error', 0);", 'must be ASCII'),
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
            failed = execute(cli, setup + bootstrap + common_sql(sql))
            if failed.returncode == 0 or expected not in failed.stderr:
                raise AssertionError(f'expected error {expected!r}: {failed.stdout}\n{failed.stderr}')
        with tempfile.TemporaryDirectory(prefix='ducksassy-no-dependency-') as missing:
            isolated = compatibility + f"SET extension_directory={quote(missing)};\n"
            if args.host == 'v1':
                isolated += f"LOAD {quote(extension)};\n"
                standalone = (ROOT / 'test/v1_native.sql').read_text()
                passed = execute(cli, isolated + standalone)
                if passed.returncode:
                    raise AssertionError(passed.stdout + passed.stderr)
                failed = execute(cli, isolated + "SELECT * FROM read_fasta('missing.fa') r "
                    "CROSS JOIN LATERAL unnest(sassy_matches('ACGT', r.sequence, 0)) AS hits(hit);")
                expected = 'read_fasta'
            else:
                failed = execute(cli, isolated + bootstrap)
                expected = 'duckhts'
            if failed.returncode == 0 or expected not in failed.stderr.lower():
                raise AssertionError(f'missing dependency did not identify {expected}: {failed.stderr}')
            if 'Failed to download extension' in failed.stderr:
                raise AssertionError(f'missing dependency attempted network access: {failed.stderr}')
    print(f'Real DuckDB/DuckHTS SQL integration tests passed ({args.host})')
if __name__ == '__main__':
    main()
