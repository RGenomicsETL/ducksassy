run <- function(command, args, capture = FALSE) {
  result <- system2(command, shQuote(args), stdout = if (capture) TRUE else "",
                    stderr = if (capture) TRUE else "")
  status <- if (capture) attr(result, "status") else result
  if (!is.null(status) && status != 0L) stop(command, " failed", call. = FALSE)
  result
}

if (dir.exists(path.expand("~/.cargo/bin"))) {
  Sys.setenv(PATH = paste(Sys.getenv("PATH"), path.expand("~/.cargo/bin"),
                         sep = .Platform$path.sep))
}
required_versions <- c(rustc = "1.91.0", cargo = "1.91.0", cmake = "3.20.0")
for (command in names(required_versions)) {
  if (!nzchar(Sys.which(command))) stop("Install ", command, " before building Rducksassy.")
  version <- run(command, "--version", capture = TRUE)
  cat(paste(version, collapse = "\n"), "\n")
  version_line <- grep(paste0("^", command, "[[:space:]]"), version, value = TRUE)
  found <- if (length(version_line) > 0L) {
    regmatches(version_line[[1L]], regexpr("[0-9]+\\.[0-9]+(\\.[0-9]+)?",
                                          version_line[[1L]], perl = TRUE))
  } else {
    ""
  }
  if (!nzchar(found) || utils::compareVersion(found, required_versions[[command]]) < 0L) {
    stop(command, " >= ", required_versions[[command]], " is required.", call. = FALSE)
  }
}

configure_args <- commandArgs(trailingOnly = TRUE)
host_arg <- grep("^--host=", configure_args, value = TRUE)
host_triplet <- if (length(host_arg) > 0L) sub("^--host=", "", host_arg[[1L]]) else ""
configured_cc <- Sys.getenv("CC")
wasm <- grepl("emcc|wasm|emscripten", paste(configured_cc, host_triplet),
              ignore.case = TRUE)

# The extension uses bundled C API headers and does not link to an R driver.
# DUCKDB_PLATFORM can supply the deployment target when cross-compiling.
platform <- Sys.getenv("DUCKDB_PLATFORM")
rust_target <- Sys.getenv("CARGO_BUILD_TARGET")
if (wasm) {
  platform <- if (nzchar(platform)) platform else "linux_i686_musl"
  rust_target <- if (nzchar(rust_target)) rust_target else "wasm32-unknown-emscripten"
} else if (!nzchar(platform)) {
  system <- Sys.info()[["sysname"]]
  architecture <- R.version$arch
  if (identical(system, "Windows")) {
    arm64 <- architecture %in% c("aarch64", "arm64")
    if (!arm64 && !architecture %in% c("x86_64", "x86-64")) {
      stop("Set DUCKDB_PLATFORM for this Windows build target.", call. = FALSE)
    }
    platform <- if (arm64) "windows_arm64_mingw" else "windows_amd64_mingw"
    if (!nzchar(rust_target)) {
      rust_target <- if (arm64) "aarch64-pc-windows-gnullvm" else "x86_64-pc-windows-gnu"
    }
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
if (nzchar(rust_target)) {
  target_libdir <- run("rustc", c("--print", "target-libdir", "--target", rust_target),
                       capture = TRUE)[[1L]]
  if (!dir.exists(target_libdir)) {
    stop("Install the Rust target ", rust_target, " before building Rducksassy.",
         call. = FALSE)
  }
}

r_config <- function(name) {
  paste(run(file.path(R.home("bin"), "R"), c("CMD", "config", name),
            capture = TRUE), collapse = " ")
}
if (!nzchar(configured_cc)) configured_cc <- r_config("CC")
Sys.setenv(CC = configured_cc)
package_version <- read.dcf("DESCRIPTION", fields = "Version")[[1L]]
build <- file.path(tempdir(), "ducksassy-build")
cmake_args <- c("-S", "src/extension", "-B", build,
                "-DCMAKE_BUILD_TYPE=Release", "-DBUILD_TESTING=OFF",
                paste0("-DCARGO_TARGET_DIR=", file.path(build, "rust-target")),
                paste0("-DDUCKDB_PLATFORM=", platform),
                "-DDUCKSASSY_HOST=v1",
                paste0("-DDUCKDB_CAPI_DIR=", normalizePath("src/extension/duckdb_capi")),
                paste0("-DDUCKSASSY_EXTENSION_VERSION=", package_version),
                "-DSASSY_CARGO_JOBS=2")
if (nzchar(rust_target)) cmake_args <- c(cmake_args, paste0("-DRUST_TARGET=", rust_target))
if (wasm) {
  emscripten <- Sys.getenv("EMSCRIPTEN")
  if (!nzchar(emscripten)) emscripten <- file.path(Sys.getenv("EMSDK"), "upstream", "emscripten")
  toolchain <- file.path(emscripten, "cmake", "Modules", "Platform", "Emscripten.cmake")
  if (!file.exists(toolchain)) stop("Could not locate the Emscripten CMake toolchain.")
  linker_flags <- gsub("-s[[:space:]]*SIDE_MODULE=1", "", Sys.getenv("LDFLAGS"))
  Sys.setenv(LDFLAGS = linker_flags)
  cmake_args <- c(cmake_args,
                  paste0("-DCMAKE_TOOLCHAIN_FILE=", normalizePath(toolchain)),
                  paste0("-DCMAKE_C_COMPILER=", configured_cc),
                  "-DDUCKDB_WASM_EXTENSION=ON", "-DDUCKSASSY_WEBR_EXTENSION=ON",
                  paste0("-DCMAKE_C_FLAGS=", Sys.getenv("CFLAGS")),
                  paste0("-DCMAKE_EXE_LINKER_FLAGS=", linker_flags),
                  paste0("-DCMAKE_SHARED_LINKER_FLAGS=", linker_flags))
} else {
  cmake_args <- c(cmake_args,
                  paste0("-DCMAKE_C_FLAGS=", trimws(paste(r_config("CPPFLAGS"),
                                                           r_config("CFLAGS")))),
                  paste0("-DCMAKE_SHARED_LINKER_FLAGS=", r_config("LDFLAGS")))
}
run("cmake", cmake_args)
# One backend at a time; each Cargo build uses at most two jobs.
run("cmake", c("--build", build, "--target", "ducksassy", "--parallel", "1"))
if (!file.copy(file.path(build, "ducksassy.duckdb_extension"), "src", overwrite = TRUE)) {
  stop("Could not stage the built extension")
}
