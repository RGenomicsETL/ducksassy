destination <- file.path(Sys.getenv("R_PACKAGE_DIR"), "libs", Sys.getenv("R_ARCH"))
dir.create(destination, recursive = TRUE, showWarnings = FALSE)
if (!file.copy("ducksassy.duckdb_extension", destination, overwrite = TRUE)) {
  stop("Could not install the ducksassy extension")
}
