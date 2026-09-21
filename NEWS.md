# ducksassy 0.1.0-dev

- The standalone C library and extension select a CPU/OS-eligible scalar, AVX2, AVX512 or NEON backend, with `SASSY_C_BACKEND` forcing and recoverable errors for unavailable requests. The `scalar` label follows Sassy's baseline feature and includes SSE2 paths on x86-64. `sassy_backend_info()` reports compiled, supported and selected status. Linux x86-64 scalar and AVX2 are exercised; other backends remain platform-validation work.

- FASTA single-pattern and panel searches compose DuckHTS readers with the native matching kernels.
- CRISPR value, panel, FASTA and relation searches expose Sassy 0.2.1's IUPAC edit-distance, PAM endpoint and N-content filters through the Rust C ABI and DuckDB C API v2.
- DNA/IUPAC validation follows upstream profiles, accepting soft-masked sequence without rewriting input values. SQL tests cover CTEs, guide/target joins, NULL-preserving lateral joins and row-varying CRISPR options.
- README examples execute through duckknit's persistent DuckDB session against bundled FASTA and FASTQ fixtures. Rendering checks the CLI revision and fails on SQL errors.
- `make setup` stages pinned runtimes and R tools under `.deps/`; builds use locked, cached Cargo dependencies. SQL tests, upstream comparisons and documentation renders use repository-relative defaults.
- SQL integration stages a checksum-pinned DuckHTS artifact from a released-host repository route. The test runner uses local artifacts without automatic extension downloads.
- Preview setup documents DuckHTS 1.5.2's global legacy-lambda requirement and its database-instance scope.
- CI takes the host revision from `ducksassy-package.json` and caches the matching statically linked executable.
