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
options. The R package builds and loads the released v1 host.

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
Single-threaded Emscripten variants retain one worker per scalar overload;
threaded Emscripten uses the pthread path. All variants free their workers and
result buffers at catalog teardown. Backend selection uses Win32 `INIT_ONCE`,
POSIX `pthread_once`, or a single-threaded Emscripten initialization flag.

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
and `test-v2` in `build/`. Rducksassy bundles the v1 adapter.

`MainDistributionPipeline.yml` enables the full upstream Linux x86-64/ARM64,
macOS x86-64/ARM64 and Windows x86-64 MinGW/Rtools matrix
(`reduced_ci_mode: disabled`). MSVC and the optional DuckDB-Wasm COI/threads
bundle remain excluded. The default DuckDB-Wasm MVP and EH bundles are release
targets.
Native v1 sqllogictests cover the public symbols, scalar defaults,
BLOB/VARCHAR, NULL/empty inputs, text/packed CIGAR, CRISPR, backend inspection,
relation composition and grep. Separate jobs run ARM64 NEON C/Rust contracts
and native-only ASan/LSan checks. LSan excludes QEMU tests because its thread
inspection does not work under ptrace; unsanitized CTest retains QEMU coverage.
DuckHTS is not loaded by the sanitizer job, and Rust archives are not instrumented.

`cran-check.yml` builds a self-contained R source tarball and checks its unpacked
contents with `r-lib/actions/check-r-package` on Linux, macOS and Windows, using
R release and the stable CRAN `duckdb` package. Package tests load the bundled
v1 extension and exercise scalar, table and backend-inspection functions.
R-devel/source-built DuckDB compatibility is outside this binary-oriented
matrix.

`test/native_load.py` checks native catalog types, repeated `LOAD`, fresh file
close/reopen, read-only primary loading, unchanged database bytes and worker
teardown. Native SQL tests cover positional defaults, both sequence types,
NULLs, empty panels, mixed packed formats, filtered parallel vectors and
CRISPR option columns. Shared packed, growth and grep fixtures run on both
hosts; test-only scalar macros translate shared named fixtures into v1 calls.
V1 file tests use explicit DuckHTS readers and lateral joins. Full grep scans
reject a late invalid byte while `LIMIT 1` succeeds.

Linux x86-64 is runtime-tested. MinGW GCC 13 and Rtools42 GCC 10.4 cross-build
complete DLLs with the stable C API entry point and only Windows system imports.
The MinGW artifact loads under Wine in DuckDB R 1.5.5; this is not a native
Windows-runner result. Rtools-tagged loading, macOS and ARM hosts are not
runtime-tested here. Build/export checks do not replace those platform runs.

### Portable builds

The Makefile installs the selected Rust target into the **project-pinned 1.91.0**
toolchain: `x86_64-pc-windows-gnu` for MinGW/Rtools and
`wasm32-unknown-emscripten` for Wasm. Runner setup alone is insufficient because
it can install targets into a different toolchain. Native developers do not
need the cross-target downloads. The project does not use nightly or `build-std`.

#### MinGW and Rtools

Windows distribution builds produce `cmake_build/release/libducksassy.dll`.
CMake selects the GNU Rust target even when rustc's host is MSVC, links the
native libraries reported by `cargo rustc -- --print native-static-libs`
(`kernel32 ntdll userenv ws2_32 dbghelp`), and statically links GCC/winpthreads.
Only `ducksassy_init_c_api` is exported. Archive assembly accepts `.o` and `.obj`
and uses an `ar` response file to stay below Windows' command-line limit.
Rtools42 combines the unwind runtime into `libgcc.a`; when its split
`libgcc_eh.a` is absent, a build-local linker script redirects Rust's request to
`libgcc`. This also permits Cargo to link Sassy's unused cdylib output.

Linux cross-build, with SDK downloads confined to `configure/`:

```sh
python3 tools/fetch_v1_sdk.py configure/sdk-v1
rustup target add x86_64-pc-windows-gnu
cmake -S . -B build-mingw -DCMAKE_TOOLCHAIN_FILE=cmake/mingw-w64.cmake \
  -DDUCKSASSY_HOST=v1 -DDUCKDB_CAPI_DIR="$PWD/configure/sdk-v1" \
  -DCMAKE_BUILD_TYPE=Release -DDUCKDB_PLATFORM=windows_amd64_mingw
cmake --build build-mingw -j2
x86_64-w64-mingw32-objdump -p build-mingw/libducksassy.dll
```

The local Rtools check uses CRAN's `rtools42-toolchain-libs-cross-5355.tar.zst`
and `rtools42-toolchain-libs-base-5355.tar.zst`, extracted together under
`.deps-port/rtools42`. Its target `bin/as` and `bin/ld` point to the corresponding
cross tools in the outer `bin/`. Use the same CMake toolchain file with
`-DMINGW_PREFIX="$PWD/.deps-port/rtools42/bin/x86_64-w64-mingw32.static.posix"`,
`-DDUCKDB_PLATFORM=windows_amd64_rtools` and a separate build directory.
GCC 10.4 links successfully with the warning
`Warning: corrupt .drectve at end of def file`; PE inspection confirms the
single correct export and system-only UCRT/Win32 imports. MinGW GCC 13 imports
MSVCRT and Win32 system DLLs; neither DLL imports libgcc or libwinpthread DLLs.
Both tags also build through `make configure release`, using
`EXTRA_CMAKE_FLAGS` to pass the cross-toolchain file and, for Rtools, its prefix.

Wine loads the MinGW artifact using CRAN R 4.6.1, DBI 1.3.0 and duckdb 1.5.5
(`PRAGMA platform`: `windows_amd64_mingw`; engine `d8cdaa33fda`).
`test/windows_smoke.R` exercises public registration, scalar/BLOB/parallel
queries, error recovery and backend selection. The canonical Rtools-tagged
artifact has no matching local host; the available R package identifies as
MinGW and rejects it with:

```text
The file was built for the platform 'windows_amd64_rtools', but we can only load extensions built for platform 'windows_amd64_mingw'.
```

The official Windows CLI identifies as MSVC and cannot test either tag.
Upstream distribution CI only builds MinGW/Rtools, so a native Windows runner
is still needed for complete runtime/lifetime validation. The standalone Rust
unit-test executable under Wine fails before the test summary in both debug
and release (also with an 8 MiB PE stack reserve):

```text
thread 'main' (264) has overflowed its stack
```

That Wine unit-test run is **not a pass**, even though its runner can return
zero. The DLL/SQL smoke test passes; the standalone Rust test harness still
needs a real Windows run.

#### Wasm distribution

Use emsdk **3.1.71** under `.deps-port/`, matching distribution CI. Start with
a clean `cmake_build/` when switching between native and Emscripten toolchains:

```sh
source .deps-port/emsdk/emsdk_env.sh
make wasm_mvp
make wasm_eh
for variant in wasm_mvp wasm_eh; do
  mkdir -p ".deps-port/artifacts/$variant"
  cp "build/$variant/extension/ducksassy/ducksassy.duckdb_extension.wasm" ".deps-port/artifacts/$variant/"
  wasm-validate --disable-simd ".deps-port/artifacts/$variant/ducksassy.duckdb_extension.wasm"
  wasm-objdump -x -j target_features ".deps-port/artifacts/$variant/ducksassy.duckdb_extension.wasm"
done
make wasm-playwright-test
```

CMake creates one static `libducksassy.a` containing adapter, core, dispatcher
and Rust objects; the final `emcc` link needs no extra archive. Cargo outputs
are separated by Wasm variant. MVP/EH compile only the scalar backend without
SIMD. The Emscripten link uses `-O1`; Rust release optimization remains enabled.
No engine or Rust standard library is patched.

Public validation failures return ordinary DuckDB errors and the same worker
remains queryable. Rust's prebuilt Emscripten standard library uses JS exception
handling, which cannot unwind a Rust panic through DuckDB's side-module boundary.
An internal Rust panic therefore follows a fail-stop contract: the browser must
terminate that worker, and a fresh worker must load and query the extension
successfully.

`test/wasm` uses a loopback Playwright server with COOP/COEP, pinned local npm
dependencies and no CDN. The browser gate runs the function-catalog examples,
VARCHAR/BLOB overloads, reverse strands, general and CRISPR packed CIGAR,
NULL/error recovery, result growth, streaming grep and backend selection. A
test-only panic extension verifies worker termination and restart for both MVP
and EH. WABT validates each artifact against its platform feature contract.

The optional `wasm_threads`/COI target remains excluded. It requires an
atomics-enabled Rust standard library, while Rust distributes the Emscripten
standard library without shared-memory atomics. Supporting that target requires
an independently qualified `build-std` toolchain and vendored sysroot
dependencies; MVP and EH cover DuckDB-Wasm's default bundles.

### Native verification

Verification on Linux: both SQL suites and C ABI/dispatch tests pass, including
the v2 macro collision probe; upstream CRISPR agrees across 36 profiles and 864
guide/record comparisons. Nine SQL families pass through the R/DBI preview
(`bcff503658`), and README rendering succeeds. ASan/LSan on the v1 C adapter/core
passes native-only read-only/load/close/reopen tests without a leak report.
The stable-v1 R source package builds offline and passes
`R CMD check --as-cran --no-manual` on local Ubuntu 24.04 with no errors or
warnings. Its only NOTE identifies version 0.1.0 as a new submission. Package
tests load the bundled extension through CRAN `duckdb` 1.5.5; DuckHTS remains
an optional community extension for file readers.

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
