This development package targets R-universe. The extension requires DuckDB C
API v2 at runtime. It builds from bundled headers without loading or linking
an R DuckDB host. The optional duckdb.2.0.dev Suggests dependency supplies a
compatible test host; it is not needed to build or install the package. A CRAN
submission still needs a compatible released host. DuckDB 1.5.5 supports only
C API v1; the search tests report this specific incompatibility and skip when
no v2 host is installed. Other load failures fail the tests.

R CMD check reports an unused-import NOTE for Rduckhts. It is a required native
resource dependency: `system.file(package = "Rduckhts")` locates the extension
built by that package. Loading its R namespace loads the stable duckdb driver,
whose methods can conflict with another DuckDB driver chosen by the caller,
so Rducksassy loads the native extension directly.
