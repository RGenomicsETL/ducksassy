# ducksassy 0.1.0

- Provide approximate ASCII, DNA and IUPAC search through ten DuckDB functions,
  including scalar matches/counts, pattern panels, CRISPR guide search,
  streaming grep and backend inspection.
- Return text CIGAR, SAM-oriented packed BAM operations, or both from general
  and CRISPR match functions. All match formats use one fixed struct with
  nullable `cigar` and `cigar_ops` fields.
- Distribute the stable C API v1 extension for Linux and macOS x86-64/ARM64,
  Windows x86-64 MinGW, and the default DuckDB-Wasm MVP/EH bundles. The browser
  contract isolates internal Rust panics to one worker and verifies restart in
  a fresh worker. The optional COI/threads bundle remains excluded pending an
  atomics-enabled Rust standard library.
- Keep C API v2 preview development behind private native functions and public
  named-argument macros, with shared validation, batching and search kernels
  across both DuckDB hosts.
- Build `Rducksassy` from bundled, locked sources against stable CRAN `duckdb`
  and load the packaged extension on Linux, macOS and Windows.
- Publish the function catalog, R reference, evaluated examples, benchmarks and
  DuckDB community-extension descriptor from repository manifests.
