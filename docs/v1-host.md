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
make release-v2 test-v2 sql-test oracle-test r-test readme
make windows-host-check  # requires x86_64-w64-mingw32-gcc
```

### Distribution and CI

The released-host distribution contract uses DuckDB **v1.5.5** and stable
C API **v1.2.0** metadata. `extension-ci-tools` is pinned to
`72e76e99cd7fee45a99739cd118ec2db64e034ec` from its `v1.5.5` branch;
the upstream repository publishes version branches, not tags. The reusable
workflow uses that same `v1.5.5` ref for both workflow and CI tools.

```sh
git submodule update --init
make configure
make release test_release
make debug test_debug
```

`configure` downloads checksum-verified headers to `configure/sdk-v1` and sets
up the upstream Python test environment. These targets use
`base.Makefile` and `c_cpp.Makefile`; CMake builds the Rust static archives, so
the Rust-only makefile is not included. Builds use `cmake_build/{release,debug}`
and produce `build/{release,debug}/ducksassy.duckdb_extension` plus the nested
`extension/ducksassy/` copies expected by distribution CI. Install `ccache`, or
pass `CMAKE_FLAGS=-DCMAKE_C_COMPILER_LAUNCHER=` to build without its launcher.
The local v1 targets above use `build-v1/`; v2 uses `configure-v2`, `release-v2`
and `test-v2` in `build/`. R packages bundle the v2 adapter.

`MainDistributionPipeline.yml` enables the full upstream Linux x86-64/ARM64
and macOS x86-64/ARM64 matrix (`reduced_ci_mode: disabled`). Windows is excluded
because CMake lacks its archive/link/metadata implementation. Wasm is excluded
because the Rust backend is only cross-type-checked, not linked into a tested
extension. Native v1 sqllogictests cover the public symbols, scalar defaults,
BLOB/VARCHAR, NULL/empty inputs, text/packed CIGAR, CRISPR, backend inspection,
relation composition and grep. Separate jobs run ARM64 NEON C/Rust contracts
and native-only ASan/LSan checks. LSan excludes QEMU tests because its thread
inspection does not work under ptrace; unsanitized CTest retains QEMU coverage.
DuckHTS is not loaded by the sanitizer job, and Rust archives are not instrumented.

`cran-check.yml` builds a self-contained R source tarball and checks its unpacked
contents with `r-lib/actions/check-r-package` on Linux and macOS, using R release
and the `duckdb.2.0.dev` preview package. A Linux job also runs `make r-test`.
The exact preview engine revision remains checked by that integration test.
Windows is outside the package's `OS_type: unix` support. R-devel/source-built
DuckDB compatibility is outside this binary-oriented matrix.

`test/native_load.py` checks native catalog types, repeated `LOAD`, fresh file
close/reopen, read-only primary loading, unchanged database bytes and worker
teardown. Native SQL tests cover positional defaults, both sequence types,
NULLs, empty panels, mixed packed formats, filtered parallel vectors and
CRISPR option columns. Shared packed, growth and grep fixtures run on both
hosts; test-only scalar macros translate shared named fixtures into v1 calls.
V1 file tests use explicit DuckHTS readers and lateral joins. Full grep scans
reject a late invalid byte while `LIMIT 1` succeeds.

Linux x86-64 is runtime-tested. MinGW GCC 13 compiles `host_v1.c` and
`ducksassy_core.c` with `-Wall -Wextra -Werror`; Windows loading, Rust linkage
and threaded runtime behavior are **not tested**. The CMake distribution build
still targets Linux, macOS and Emscripten; Windows archive/link/metadata support
remains packaging work. macOS and ARM hosts are not runtime-tested here. Build/export checks and sanitizer evidence do not replace
those platform runs.

Verification on Linux: both SQL suites and C ABI/dispatch tests pass, including
the v2 macro collision probe; upstream CRISPR agrees across 36 profiles and 864
guide/record comparisons. Nine SQL families pass through the R/DBI preview
(`bcff503658`), and README rendering succeeds. ASan/LSan on the v1 C adapter/core
passes native-only read-only/load/close/reopen tests without a leak report.
The source R package builds and passes `R CMD check --no-manual` with
`Status: OK`. `--as-cran` has no errors or warnings; its incoming-feasibility
NOTE covers the development version, preview repository and Pages URL (404
until first deployment). `Rduckhts` is a suggested runtime dependency: the
connection helpers require its installed extension files but do not import
its R namespace. Examples explicitly select the v2 preview driver.

The full sanitizer suite with the existing DuckHTS binary reports:

```text
ERROR: LeakSanitizer: detected memory leaks
    #2 ... in register_read_hts_index_function (.../duckhts.duckdb_extension+0x246969)
    #2 ... in register_read_hts_header_function (.../duckhts.duckdb_extension+0x246899)
    #2 ... in register_read_hts_index_spans_function (.../duckhts.duckdb_extension+0x246a39)
SUMMARY: AddressSanitizer: 2503 byte(s) leaked in 16 allocation(s).
```

A process loading only DuckHTS reproduces that report
(`.deps-v1/duckhts-only-lsan.log`). The combined SQL suite passes address checks
with leak detection disabled; this does not establish dependency leak freedom.
The dependency's leak behavior must be assessed separately.

Tree-sitter anti-slop parses `src/ducksassy_core.c` with zero findings, but the
full `src` scan cannot analyze the extension entrypoint macros and dispatcher
attributes. Its diagnostic is:

```text
ERROR parse-error: Tree-sitter could not parse this source exactly; anti-slop did not run style rules.
```

This is a linter coverage limitation, not a clean whole-tree lint result.

### Documentation site

`make site` runs `tools/build-site.R`. pkgdown builds the R reference under
`site/reference/`; litedown renders the committed evaluated `README.md`, all
`benchmarks/*.md` reports and this host guide. The site build does not execute
README code or benchmarks. It maps report links to HTML, source/evidence links
to GitHub, and verifies local pages, assets and fragments with
`tools/check-site.R`. Generated HTML stays under ignored `site/`, separate from
source Markdown in `docs/`.

`pages.yml` builds and deploys through GitHub's Pages artifact actions on a
push to `main` or manual dispatch. Set **Settings → Pages → Build and deployment
→ Source: GitHub Actions** and allow the `github-pages` environment to deploy
from `main`. The public URL is <https://rgenomicsetl.github.io/ducksassy/>.
Linux local validation is not evidence that the remote multi-platform matrix
or Pages deployment has run; those require an owner-authorized push.

## Measurements

`benchmarks/host_comparison.R` compares the packed-CIGAR monolithic v2 adapter,
the shared-core v2 adapter and released v1 using the same AVX2 Rust archive.
Inputs are a seeded 4,641,652-base synthetic reference, eight 23-base guides,
65,536 150-base reads and 2,048 dense-CIGAR rows. Complete sorted hit multisets,
including packed lists, must agree before timing.

Nine alternating repetitions use persistent CLIs pinned to CPUs 16–19, with
three calls per timing batch. Measurements include bind, local DuckHTS reads,
search, output aggregation and JSON decoding, but not startup or full-hit
verification. All hosts use matching SELECT/UNNEST query shapes, with macros
expanded on v2 and native positional calls on v1. They compare complete host
queries, not isolated vector-write cost. Raw timings, input/runtime hashes and exact-hit checks live in
`benchmarks/data/host_comparison/`.

Median seconds per query; deltas are relative to packed-CIGAR baseline
`a841d8d` on the same v2 runtime. Lower is faster.

| Workload | Threads | Baseline v2 | Shared v2 | Delta | Released v1 | Delta |
|---|---:|---:|---:|---:|---:|---:|
| FASTQ rows | 1 | 0.2240 | 0.2217 | -1.0% | 0.2203 | -1.6% |
| FASTQ rows | 4 | 0.2263 | 0.2240 | -1.0% | 0.2213 | -2.2% |
| FASTA panel | 1 | 0.0557 | 0.0563 | +1.2% | 0.0447 | -19.8% |
| FASTA panel | 4 | 0.0553 | 0.0517 | -6.6% | 0.0473 | -14.5% |
| CRISPR panel | 1 | 0.0957 | 0.0953 | -0.3% | 0.0853 | -10.8% |
| CRISPR panel | 4 | 0.0950 | 0.0957 | +0.7% | 0.0887 | -6.7% |
| Dense text CIGAR | 1 | 0.3000 | 0.2973 | -0.9% | 0.2973 | -0.9% |
| Dense text CIGAR | 4 | 0.2960 | 0.2950 | -0.3% | 0.3003 | +1.5% |
| Dense both formats | 1 | 0.3200 | 0.3187 | -0.4% | 0.3173 | -0.8% |
| Dense both formats | 4 | 0.3170 | 0.3190 | +0.6% | 0.3110 | -1.9% |

All 30 full-hit multiset checks agree. Outputs contain 65,536 FASTQ hits,
eight FASTA-panel hits, four CRISPR-panel hits and 266,237 dense hits per format.
The shared-core v2 refactor shows no material slowdown in these measurements
(maximum observed increase 1.2%). V1 also changes the DuckDB engine version;
its differences cannot be attributed solely to the adapter. Thread settings
are not evidence of scalable parallel work for the single-record FASTA scan.

## Community submission

Before publication: run the supported released-host platform matrix, including
loading, concurrent workers and close/reopen, and build distribution archives,
validate signatures/metadata and licensing against community-extension
requirements, and decide the v1 artifact/version naming. Keep v2/R preview
compatibility separate. Publishing or opening a submission requires explicit
owner approval.
