# ducksassy

Approximate sequence matching as typed DuckDB expressions, composed with **DuckHTS**.

```text
sassy (Rust crate) -> libsassy_c.a (our C ABI) -> C adapter (DuckDB C API v2)
DuckHTS readers -> sequence columns -> matches/counts/predicates -> ordinary SQL
```

No `duckdb-rs`, `libduckdb-sys`, DuckDB C++ internals, v1 adapter, nested thread
pool, or duplicated FASTA/FASTQ parser. The Rust library is independently usable
from C and does not know that DuckDB exists.

## Status and compatibility

This is an initial **v2-preview** implementation. The adapter disables the
unstable and deprecated *symbol surfaces* and targets `C_STRUCT` / `v2.0.0`.
The currently inspected upstream extension header nevertheless warns that the
v2 ABI is not frozen. The SDK and integration host are therefore pinned to
DuckDB commit `fece4143738e2b1d05a851d5c5dc036838aff8ec`. Do not interpret this
as a tested cross-version compatibility guarantee or try loading it into DuckDB 1.x.

Sassy is pinned to `0.2.1`, matching the established Rsassy interface. The
portable scalar feature is enabled. There is no unvalidated `target-cpu=native`
distribution build and no claim of AVX2/AVX-512 dispatch yet.

## Build

Requires a C11 compiler, CMake >=3.20, Python >=3.11 for build/test tooling,
Cargo/rustc >=1.91, and the initialized `extension-ci-tools` submodule.

```sh
git submodule update --init
make sdk
make test
# build/ducksassy.duckdb_extension
# rust/target/release/libsassy_c.a
```

Offline SDK builds can set `DUCKDB_CAPI_DIR` to the pinned DuckDB checkout's
`src/include`. Cargo dependencies must likewise already be cached or vendored.
Set `DUCKDB_PLATFORM` through CMake when it differs from the detected target.
The first CI target is Linux amd64. Windows and browser/WASM deployment are not
claimed by this initial implementation.

## Required DuckHTS dependency and public bindings

Install DuckHTS and the built artifact explicitly, then execute `sql/ducksassy.sql`
on each connection that needs the public macros. In the DuckDB CLI:

```sql
INSTALL duckhts FROM community;
INSTALL 'build/ducksassy.duckdb_extension';
.read sql/ducksassy.sql
```

The SQL bootstrap runs **`LOAD duckhts` before `LOAD ducksassy`** and retains
`duckhts_htslib_version()` in public expressions. Missing DuckHTS fails rather
than silently falling back to another reader. No install/download is hidden
inside an extension callback. Macros are temporary/connection-scoped.

**Dependency boundary:** this is an explicit SQL-package bootstrap dependency,
not automatic dependency loading from the native entrypoint. A bare
`LOAD ducksassy` registers only the low-level `__sassy_*` kernels, which can be
used without DuckHTS. The pinned v2 surface used here exposes no dependency
loader or safe nested-query convenience; the implementation does not bypass
that restriction with v1, C++ access or a second hidden DuckDB connection.

## High-level SQL

```sql
SELECT sassy_contains('ACGA', 'TTACGATT', 0, rc := false);
SELECT sassy_matches('ACGA', 'TTACGATT', 0, rc := false);

SELECT hit.text_start, hit.text_end, hit.cost, hit.strand, hit.cigar
FROM sassy_search_fastq('reads.fastq.gz', 'AGATCGGAAGAGC', 2, rc := false);

SELECT hit.pattern_idx, count(*) AS observations
FROM sassy_panel_search_fastq('reads.fastq.gz', ['ACGA', 'TTGC'], 1, rc := false)
GROUP BY hit.pattern_idx;

CREATE TEMP VIEW reads AS SELECT * FROM read_fastq('reads.fastq.gz');
SELECT * FROM sassy_search_table('reads', 'ACGA', 1, rc := false);

-- Any DuckHTS or user relation can feed the same scalar kernel.
SELECT r.*, unnest(sassy_matches('ACGA', r.sequence, 1, rc := false)) AS hit
FROM reads r;
```

Single-pattern and panel forms of `sassy_matches`, `sassy_count`, and
`sassy_contains` are provided. Panel forms have the `_many` suffix and accept
`VARCHAR[]` or `BLOB[]`; `pattern_idx` is zero-based and preserves panel order,
including duplicate patterns. Both pattern and text must use the same SQL byte
representation. A `BLOB` here means sequence **bytes**, not DuckHTS nt16/nt4
packed symbols. Decode packed sequences before searching them.

Optional arguments: `alphabet := 'iupac'`, `rc := true`,
`all_endpoints := false`, `max_hits := 10000`, `max_text_bytes := 1048576`.
For literal ASCII searches use `alphabet := 'ascii', rc := false`.
Patterns must have 1..4096 bytes, a panel at most 4096 patterns, and `k` must be
smaller than every pattern length. DNA requires uppercase A/C/G/T. IUPAC accepts
uppercase A/C/G/T/R/Y/S/W/K/M/B/D/H/V/N; N is ambiguous, not an error or a
mismatch penalty. The default does not perform lowercase normalization.

A match is:

```text
STRUCT(pattern_idx UBIGINT, text_start UBIGINT, text_end UBIGINT,
       pattern_start UBIGINT, pattern_end UBIGINT, cost INTEGER,
       strand VARCHAR, cigar VARCHAR)
```

Coordinates are **zero-based, half-open** in the original input text. `+`/`-`
indicate strand. Reverse-strand CIGAR is in pattern direction, not SAM direction.
`all_endpoints=false` follows Sassy's rightmost-local-minimum search semantics;
`true` reports qualifying endpoints. Neither means every possible alignment.
NULL arguments propagate to NULL; an empty text or panel returns no hits;
NULL panel elements and empty patterns are errors. SQL result order is not
promised without ORDER BY. Genomic offsets must be added by the caller only when
its sequence-to-reference coordinate map makes that valid.

## Streaming and memory contracts

DuckHTS owns input scanning. FASTQ wrappers explicitly request sequential scans;
records/chunks flow into the scalar kernels without collecting the whole file
or relation in Rust. One mutable searcher per alphabet/orientation is retained
in each DuckDB worker's v2 init state. There is no shared searcher lock or
extension-owned thread pool. Borrowed input pointers never outlive a callback.

Sassy 0.2.1 returns a vector of hits for one pattern/text pair. This implementation
therefore **buffers per-record output**, not an entire relation, and does not
pretend to stream individual traceback hits. It checks `max_text_bytes` before
searching and `max_hits` after each pattern search. The latter is an output cap,
not a hard bound on Sassy's intermediate allocations. An additional fixed
1,048,576-hit limit bounds LIST output per DuckDB chunk. Limits raise errors;
there is no silent truncation. Rust allocations are not spillable DuckDB buffer-
pool allocations and are not fully governed by DuckDB's memory_limit.

Counts/predicates avoid constructing CIGAR strings in the FFI/output adapter,
but the upstream search still performs its normal work. They are not advertised
as early-exit or no-trace kernels. Panel matching is a deterministic **pairwise**
implementation, not an encoded-pattern acceleration or custom join operator.
Input vectors are flattened before acquiring borrowed views for alias safety;
this may materialize vector descriptors. It is not an end-to-end zero-copy claim.

For chromosome-sized sequences, use an appropriate DuckHTS record/region
representation and validate overlap/boundary semantics. Arbitrarily cutting
windows and deduplicating endpoints is not implemented as a supposedly exact
whole-genome streaming search.

## Low-level C library

`include/sassy_c.h` documents the independently versioned C ABI, pointer/length
spans, worker confinement, panic containment, ownership, resource limits, and
borrowed views over a result's hit array plus CIGAR slab. It contains no DuckDB
or Rust-specific types. Link `libsassy_c.a` with the native system libraries
required by the Rust toolchain. See `test/c/test_abi.c` for a complete example.

## Tests

`cargo test --manifest-path rust/Cargo.toml` covers matching, reverse complements,
IUPAC, panels, limits, invalid input, result ownership and ABI layouts.
`make test` also compiles the actual v2 adapter and runs the C caller test and
source-contract checks. Runtime integration, including required DuckHTS,
multiple chunks, BLOB overloads, NULLs and errors, is separate:

```sh
python3 test/run_sql.py --duckdb /path/to/matching/duckdb \
    --extension build/ducksassy.duckdb_extension
```

CI builds the pinned v2 host for this integration test. Passing source checks is
not evidence that a native load or SQL test passed; inspect the separate job.

## Follow-on work

Encoded IUPAC pattern plans cached per bound expression, native CPU dispatch,
true output-cursor/backpressure integration, no-trace/early-exit kernels, and
PAM-aware CRISPR policy are intentionally separate from this initial adapter.
They require semantic and performance tests rather than new SQL names alone.
