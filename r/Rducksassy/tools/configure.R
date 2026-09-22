run <- function(command, args, capture = FALSE) {
  result <- system2(command, shQuote(args), stdout = if (capture) TRUE else "")
  status <- if (capture) attr(result, "status") else result
  if (!is.null(status) && status != 0L) stop(command, " failed", call. = FALSE)
  result
}

if (dir.exists(path.expand("~/.cargo/bin"))) {
  Sys.setenv(PATH = paste(Sys.getenv("PATH"), path.expand("~/.cargo/bin"),
                         sep = .Platform$path.sep))
}
for (command in c("rustc", "cargo", "cmake")) {
  if (!nzchar(Sys.which(command))) stop("Install ", command, " before building Rducksassy.")
  version <- run(command, "--version", capture = TRUE)
  cat(paste(version, collapse = "\n"), "\n")
  if (command == "rustc") {
    found <- strsplit(version[[1L]], " ", fixed = TRUE)[[1L]][[2L]]
    if (utils::compareVersion(found, "1.91.0") < 0L) stop("rustc >= 1.91 is required.")
  }
}

driver <- duckdb.2.0.dev::duckdb(shared_home = FALSE)
con <- DBI::dbConnect(driver)
platform <- tryCatch(DBI::dbGetQuery(con, "PRAGMA platform")[[1L]],
                     finally = DBI::dbDisconnect(con, shutdown = TRUE))
r_config <- function(name) {
  paste(run(file.path(R.home("bin"), "R"), c("CMD", "config", name),
            capture = TRUE), collapse = " ")
}
Sys.setenv(CC = r_config("CC"))
build <- file.path(tempdir(), "ducksassy-build")
run("cmake", c("-S", "src/extension", "-B", build,
               "-DCMAKE_BUILD_TYPE=Release", "-DBUILD_TESTING=OFF",
               paste0("-DCARGO_TARGET_DIR=", file.path(build, "rust-target")),
               paste0("-DCMAKE_C_FLAGS=", r_config("CFLAGS")),
               paste0("-DDUCKDB_PLATFORM=", platform),
               "-DSASSY_CARGO_JOBS=2"))
# One backend at a time; each Cargo build uses at most two jobs.
run("cmake", c("--build", build, "--target", "ducksassy", "--parallel", "1"))
if (!file.copy(file.path(build, "ducksassy.duckdb_extension"), "src", overwrite = TRUE)) {
  stop("Could not stage the built extension")
}
