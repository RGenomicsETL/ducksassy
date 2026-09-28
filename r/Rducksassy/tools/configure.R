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
required_versions <- c(rustc = "1.91.0", cargo = "1.91.0", cmake = "3.20.0")
version_fields <- c(rustc = 2L, cargo = 2L, cmake = 3L)
for (command in names(required_versions)) {
  if (!nzchar(Sys.which(command))) stop("Install ", command, " before building Rducksassy.")
  version <- run(command, "--version", capture = TRUE)
  cat(paste(version, collapse = "\n"), "\n")
  fields <- strsplit(version[[1L]], " ", fixed = TRUE)[[1L]]
  found <- fields[[version_fields[[command]]]]
  if (utils::compareVersion(found, required_versions[[command]]) < 0L) {
    stop(command, " >= ", required_versions[[command]], " is required.", call. = FALSE)
  }
}

# The extension uses bundled C API headers and does not link to an R driver.
# DUCKDB_PLATFORM can supply the deployment target when cross-compiling.
platform <- Sys.getenv("DUCKDB_PLATFORM")
if (!nzchar(platform)) {
  system <- Sys.info()[["sysname"]]
  architecture <- R.version$arch
  if (identical(system, "Windows") && architecture %in% c("x86_64", "x86-64")) {
    target_libdir <- run(
      "rustc", c("--print", "target-libdir", "--target", "x86_64-pc-windows-gnu"),
      capture = TRUE
    )[[1L]]
    if (!dir.exists(target_libdir)) {
      stop("Install the Rust target x86_64-pc-windows-gnu before building Rducksassy.",
           call. = FALSE)
    }
    platform <- "windows_amd64_mingw"
  } else {
    os <- switch(system, Linux = "linux", Darwin = "osx", NA_character_)
    cpu <- if (architecture %in% c("x86_64", "x86-64")) {
      "amd64"
    } else if (architecture %in% c("aarch64", "arm64")) {
      "arm64"
    } else {
      NA_character_
    }
    if (is.na(os) || is.na(cpu)) stop("Set DUCKDB_PLATFORM for this build target.")
    platform <- paste(os, cpu, sep = "_")
  }
}
r_config <- function(name) {
  paste(run(file.path(R.home("bin"), "R"), c("CMD", "config", name),
            capture = TRUE), collapse = " ")
}
Sys.setenv(CC = r_config("CC"))
package_version <- read.dcf("DESCRIPTION", fields = "Version")[[1L]]
build <- file.path(tempdir(), "ducksassy-build")
run("cmake", c("-S", "src/extension", "-B", build,
               "-DCMAKE_BUILD_TYPE=Release", "-DBUILD_TESTING=OFF",
               paste0("-DCARGO_TARGET_DIR=", file.path(build, "rust-target")),
               paste0("-DCMAKE_C_FLAGS=", trimws(paste(r_config("CPPFLAGS"), r_config("CFLAGS")))),
               paste0("-DCMAKE_SHARED_LINKER_FLAGS=", r_config("LDFLAGS")),
               paste0("-DDUCKDB_PLATFORM=", platform),
               "-DDUCKSASSY_HOST=v1",
               paste0("-DDUCKDB_CAPI_DIR=", normalizePath("src/extension/duckdb_capi")),
               paste0("-DDUCKSASSY_EXTENSION_VERSION=", package_version),
               "-DSASSY_CARGO_JOBS=2"))
# One backend at a time; each Cargo build uses at most two jobs.
run("cmake", c("--build", build, "--target", "ducksassy", "--parallel", "1"))
if (!file.copy(file.path(build, "ducksassy.duckdb_extension"), "src", overwrite = TRUE)) {
  stop("Could not stage the built extension")
}
