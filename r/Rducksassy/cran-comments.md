This development package targets R-universe. Its required DuckDB v2 preview
host (`duckdb.2.0.dev`) is not a CRAN dependency; a CRAN submission must wait for
a compatible released host or explicitly port to the released C API.

R CMD check reports an unused-import NOTE for Rduckhts. It is a required native
resource dependency: `system.file(package = "Rduckhts")` locates the extension
built by that package. Loading its R namespace loads the stable duckdb driver,
whose methods conflict with the preview driver, so Rducksassy loads the native
extension directly. Revisit that arrangement when both packages use the same
released DuckDB driver.
