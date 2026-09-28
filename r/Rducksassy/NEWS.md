# Rducksassy 0.1.0

- Build and load the stable C API v1 `ducksassy` extension with the CRAN
  `duckdb` package.
- Provide `rducksassy_connect()` and `rducksassy_load()` for approximate text,
  DNA, IUPAC and CRISPR guide search from SQL.
- Compile the bundled C and Rust sources offline with runtime selection of the
  scalar, AVX2, AVX-512 or NEON search backend.
