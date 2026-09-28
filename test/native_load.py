#!/usr/bin/env python3
"""Catalog lifetime/read-only checks and an executable native/macro binding probe."""
import argparse
import hashlib
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--host', choices=('v1', 'v2'), required=True)
    parser.add_argument('--duckdb', type=Path, required=True)
    parser.add_argument('--extension', type=Path, required=True)
    args = parser.parse_args()
    load = "LOAD '" + str(args.extension.resolve()).replace("'", "''") + "';\n"
    setup = 'SET autoinstall_known_extensions=false; SET autoload_known_extensions=false;\n'

    def run(sql, database=':memory:', readonly=False, error=None):
        command = [str(args.duckdb.resolve()), '-unsigned', '-no-init', '-batch', '-bail']
        if readonly:
            command.append('-readonly')
        result = subprocess.run(command + [str(database)], input=setup + sql,
                                text=True, capture_output=True, cwd=ROOT, timeout=300)
        if error:
            assert result.returncode and error in result.stderr, result.stdout + result.stderr
        else:
            assert result.returncode == 0, result.stdout + result.stderr
        return result

    if args.host == 'v2':
        run(load + (ROOT / 'test/v2_macro_collision.sql').read_text(),
            error='Macro __sassy_count() does not support the supplied arguments')
        print('v2: same-named TEMP macro shadows native scalar, including full arity')
        return

    fixture = (ROOT / 'test/v1_native.sql').read_text()
    absent = """SELECT CASE WHEN count(*) = 0 THEN true ELSE error('persistent sassy catalog entry') END
        FROM duckdb_functions() WHERE function_name LIKE '%sassy%';"""
    with tempfile.TemporaryDirectory(prefix='ducksassy-native-') as directory:
        database = Path(directory) / 'native.duckdb'
        run('CREATE TABLE sentinel AS SELECT 42 AS value;', database)
        digest = hashlib.sha256(database.read_bytes()).hexdigest()
        for readonly in (False, True):
            run(absent, database, readonly)
            run(load + load + fixture + 'SELECT * FROM sentinel;', database, readonly)
            run(absent, database, readonly)
            assert hashlib.sha256(database.read_bytes()).hexdigest() == digest, 'LOAD changed database bytes'
        # Catalog extra-info must release all per-thread workers on close.
        for _ in range(3):
            run(load + fixture)
        run(load + "SELECT * FROM sassy_search_fasta('missing.fa','ACGA',0);",
            database, True, error='sassy_search_fasta')
        run(load + "SELECT sassy_matches('ACGA','ACGA',0,rc:=false);",
            database, True, error='No function matches')
    print('v1: native-only LOAD, reopen, read-only primary, repeated LOAD and teardown passed')


if __name__ == '__main__':
    main()
