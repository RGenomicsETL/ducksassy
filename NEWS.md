# ducksassy 0.1.0-dev

- Add `cigar_format := 'packed'` and `'both'` to `sassy_matches` and
  `sassy_matches_many` for SAM-oriented BAM `UINTEGER[]` operations. Text CIGAR
  remains in pattern direction; packed-only calls do not build text CIGAR.
  All formats return a struct with nullable `cigar` and `cigar_ops` fields.

- Reuse hit and CIGAR buffers per searcher and keep successful error bookkeeping
  allocation-free. C callers can return consumed results with
  `sassy_c_result_recycle()`; outstanding owned results keep independent lifetimes.
- Cache output-vector handles within each scalar chunk and refresh them when
  buffers grow. Add resident-input upstream library, Rust C ABI and SQL timings
  with complete hit comparisons.
- Rducksassy has an evaluated README, a Sassy paper citation and selectable
  DuckDB drivers. Package builds use bundled C API v2 headers without starting
  an R DuckDB host.

- Add Rducksassy with offline vendored Rust builds and DuckDB v2 preview
  connections. Include a BAM read-sequence CRISPR example and an upstream CLI
  timing baseline for the sequence benchmark.

- Add `sassy_grep(pattern, text, k)` as an incremental ASCII table scan. SQL
  `LIMIT` can stop searches after an output batch. Scalar searches borrow
  vector strings and materialize one complete result per input value.
- Add a build-time wasm128 backend for Emscripten targets. The Rust wasm target
  is typechecked in CI; a linked DuckDB-Wasm extension needs platform validation.

- Use Sassy 0.2.6, including its native CRISPR N-content filtering. Public C ABI and SQL signatures are unchanged.

- Add executed FASTA, CRISPR and relational benchmarks with one-/four-thread measurements, backend comparisons and upstream CRISPR validation.

- Fix DuckHTS setup downloads rejected with HTTP 403.
- README examples lead with FASTA searches, CRISPR candidates and guide–target joins.

- The standalone C library and extension select a CPU/OS-eligible scalar, AVX2, AVX512 or NEON backend, with `SASSY_C_BACKEND` forcing and recoverable errors for unavailable requests. The `scalar` label follows Sassy's baseline feature and includes SSE2 paths on x86-64. `sassy_backend_info()` reports compiled, supported and selected status. Linux x86-64 scalar and AVX2 are exercised; other backends remain platform-validation work.

- FASTA single-pattern and panel searches compose DuckHTS readers with the native matching kernels.
- CRISPR value, panel, FASTA and relation searches expose Sassy's IUPAC edit-distance, PAM endpoint and N-content filters through the Rust C ABI and DuckDB C API v2.
- DNA/IUPAC validation follows upstream profiles, accepting soft-masked sequence without rewriting input values. SQL tests cover CTEs, guide/target joins, NULL-preserving lateral joins and row-varying CRISPR options.
- README examples execute through duckknit's persistent DuckDB session against bundled FASTA and FASTQ fixtures. Rendering checks the CLI revision and fails on SQL errors.
- `make setup` stages pinned runtimes and R tools under `.deps/`; builds use locked, cached Cargo dependencies. SQL tests, upstream comparisons and documentation renders use repository-relative defaults.
- SQL integration stages a checksum-pinned DuckHTS artifact from a released-host repository route. The test runner uses local artifacts without automatic extension downloads.
- Preview setup documents DuckHTS 1.5.2's global legacy-lambda requirement and its database-instance scope.
- CI takes the host revision from `ducksassy-package.json` and caches the matching statically linked executable.
