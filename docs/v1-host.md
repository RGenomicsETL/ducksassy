# DuckDB hosts

## Public API

`DUCKSASSY_HOST=v1` builds for the stable C extension API **v1.2.0**.
The tested released runtime is DuckDB **v1.5.5** (`d8cdaa33fd`); the ABI floor
is not a claim that every older DuckDB release has been tested.
`LOAD` registers native functions in the running database instance. It executes
no SQL or DDL, persists no catalog entries, and works with a read-only primary
database. Value searches and diagnostics do not require DuckHTS.

V1 scalar arguments are positional, with these trailing defaults:

```text
sassy_matches(pattern, text, k, alphabet='iupac', rc=true,
              all_endpoints=false, cigar_format='text')
sassy_matches_many(patterns, text, k, alphabet='iupac', rc=true,
                   all_endpoints=false, cigar_format='text')
sassy_count / sassy_contains(pattern, text, k, alphabet='iupac', rc=true,
                            all_endpoints=false)
sassy_count_many / sassy_contains_many(patterns, text, k, alphabet='iupac',
                                      rc=true, all_endpoints=false)
sassy_crispr_matches(guide, text, k, pam_length=3, allow_pam_edits=false,
                     max_n_frac=0.2, rc=true)
sassy_crispr_matches_many(guides, text, k, pam_length=3, allow_pam_edits=false,
                          max_n_frac=0.2, rc=true)
```

Each has VARCHAR and BLOB overloads; panels use a matching list type. An omitted
trailing argument takes its default; an explicit NULL propagates NULL.
`sassy_matches` and `_many` always return a nine-field hit struct with nullable
`cigar` and `cigar_ops UINTEGER[]`. `cigar_format` can vary by row:
`text` gives text only, `packed` gives packed operations only, and `both` gives
both. Packed operations follow the BAM encoding and forward-reference ordering,
including reverse-strand operation reversal and query soft clips. CRISPR returns
its eight-field text-CIGAR hit struct.

V1 also registers two native table functions:

- `sassy_grep(pattern VARCHAR, text VARCHAR, k BIGINT)`: the four streaming hit
  columns, ASCII, all endpoints, no reverse complement; `LIMIT` stops scanning.
- `sassy_backend_info()`: `name`, `compiled`, `supported`, `selected` diagnostics
  without initializing a search backend.

V1 has **no relation-name or file helpers**, SQL bootstrap, or scalar `:=`
syntax. Stable table-function binding cannot receive a caller relation by name
as an input relation without issuing a query, which would lose caller CTE scope
and optimizer composition. Use a lateral join instead:

```sql
LOAD 'build-v1/ducksassy.duckdb_extension';
SELECT sassy_count('ACGA', 'TTACGATT', 0, 'dna', false);
SELECT * FROM sassy_backend_info();
SELECT * FROM sassy_grep('error', 'error: disk full', 0);

-- The same composition works on any table or CTE with a sequence column.
LOAD '/absolute/path/duckhts.duckdb_extension';
SELECT r.*, hit
FROM read_fasta('reference.fa', scan_mode := 'sequential') r
CROSS JOIN LATERAL unnest(
    sassy_matches('ACGTAGG', r.sequence, 1, 'iupac', false, false, 'both')
) AS matches(hit);

SELECT r.*, hit
FROM read_fastq('reads.fastq', scan_mode := 'sequential') r
CROSS JOIN LATERAL unnest(
    sassy_matches_many(['ACGA', 'GATT'], r.sequence, 1, 'iupac', false)
) AS matches(hit);

SELECT r.*, hit FROM targets r
CROSS JOIN LATERAL unnest(sassy_crispr_matches('ACGTNGG', r.sequence, 1)) AS matches(hit);
```

Use `LEFT JOIN LATERAL ... ON true` to keep unmatched or NULL sequence rows.
For a panel, `hit.pattern_idx` is the zero-based input-list index.

The **v2 preview** keeps its existing public macros, named defaults, relation
and file helpers in `sql/ducksassy.sql`; it does not gain public positional
optional arguments. A same-named TEMP macro hides a native scalar, including
calls matching the native function's full arity. The executable probe
`test/v2_macro_collision.sql` demonstrates this on preview `fece414373`:
`__sassy_count` returns 1 before the macro, the three-argument macro returns 42,
and the six-argument call then fails with:

```text
Binder Error: Macro __sassy_count() does not support the supplied arguments. You might need to add explicit type casts.
Candidate macros:
        __sassy_count(p, t, k)
```

V2 therefore retains private `__sassy_*` natives and public macros. Required
arguments are positional on both hosts; only v1 has positional trailing
options. The R package targets the v2 preview.

## Host boundary and ownership

`src/ducksassy_core.c` is DuckDB-free: it validates rows, prepares pattern panels,
selects text/packed Rust output, validates result slabs, batches searches and
owns grep's rolling-window algorithm. Ten host operations expose typed inputs,
worker acquisition, errors, scalar results and hit batches. Adapters alone
handle vectors, list capacities, validity and string storage.

V2 flattens through a shared input arena and uses execution-local workers.
Stable v1 flattens chunks, including list children, and writes flat vectors
through the public C API. The released stable scalar API has no execution-local
init hook. Each scalar overload therefore owns a TLS key and a synchronized list
of per-thread workers; all workers, result buffers, the key and lock are freed
at function/catalog teardown. Workers may remain cached until database close.
POSIX uses pthread TLS/mutexes; Windows uses `TlsAlloc`/`TlsFree` and `SRWLOCK`,
with the same catalog-owned lifetime and no thread-exit destructor dependency.

Grep copies bound VARCHAR values through a private, single-thread in-memory
`SELECT $1::VARCHAR, $2::VARCHAR` at bind time. Stable v1's value getter provides
no string byte length, and casting to BLOB interprets backslash escapes. The
private query exposes length-bearing vectors, preserving NULs and literal
backslashes without unstable API slots or a scalar shim. This adds bind-time
connection/query overhead and copies both inputs once; search/window processing
remains lazy. It never queries or writes the caller's database and runs no DDL.

## Build and verification

Keep host artifacts in separate directories. The runtime handles are loaded by
DuckDB's extension loader, not linked against `libduckdb`.

```sh
make sdk-v1
mkdir -p .deps-v1/cli
curl -fL --retry 3 https://github.com/duckdb/duckdb/releases/download/v1.5.5/duckdb_cli-linux-amd64.zip -o .deps-v1/cli.zip
unzip .deps-v1/cli.zip -d .deps-v1/cli
make release-v1 sql-test-v1
make release test sql-test oracle-test readme
```

`test/native_load.py` checks native catalog types, repeated `LOAD`, fresh file
close/reopen, read-only primary loading, unchanged database bytes and worker
teardown. Native SQL tests cover positional defaults, both sequence types,
NULLs, empty panels, mixed packed formats, filtered parallel vectors and
CRISPR option columns. Shared packed, growth and grep fixtures run on both
hosts; test-only scalar macros translate shared named fixtures into v1 calls.
V1 file tests use explicit DuckHTS readers and lateral joins. Full grep scans
reject a late invalid byte while `LIMIT 1` succeeds.

Linux x86-64 is runtime-tested. MinGW GCC 12 compiles `host_v1.c` and
`ducksassy_core.c` with `-Wall -Wextra -Werror`; Windows loading, Rust linkage
and threaded runtime behavior are **not tested**. macOS and ARM hosts are not
runtime-tested here. Build/export checks and sanitizer evidence do not replace
those platform runs.

## Measurements

`benchmarks/host_comparison.R` compares the packed-CIGAR monolithic v2 adapter,
the shared-core v2 adapter and released v1 using the same AVX2 Rust archive.
Inputs are a seeded 4,641,652-base synthetic reference, eight 23-base guides,
65,536 150-base reads and 2,048 dense-CIGAR rows. Complete sorted hit multisets,
including packed lists, must agree before timing.

Nine alternating repetitions use persistent CLIs pinned to CPUs 16–19, with
three calls per timing batch. Measurements include bind, local DuckHTS reads,
search, output aggregation and JSON decoding, but not startup or full-hit
verification. They compare complete host queries, not isolated vector-write
cost. Raw timings, input/runtime hashes and exact-hit checks live in
`benchmarks/data/host_comparison/`.

## Community submission

Before publication: run the released-host platform matrix (especially Windows
loading, concurrent workers and close/reopen), build distribution archives,
validate signatures/metadata and licensing against community-extension
requirements, and decide the v1 artifact/version naming. Keep v2/R preview
compatibility separate. Publishing or opening a submission requires explicit
owner approval.
