#!/usr/bin/env Rscript
# Refresh the shared source bundle from the committed dependency lockfile.
root <- normalizePath(".", mustWork = TRUE)
manifest <- file.path(root, "rust", "Cargo.toml")
destination <- file.path(root, "third_party", "rust")
staging <- tempfile("ducksassy-vendor-")
dir.create(staging)

run <- function(command, args, ...) {
  status <- system2(command, shQuote(args), ...)
  if (!identical(status, 0L)) stop(command, " failed", call. = FALSE)
}

main <- function() {
  on.exit(unlink(staging, recursive = TRUE))
  dir.create(destination, recursive = TRUE, showWarnings = FALSE)
  config <- file.path(staging, "config.toml")
  run("cargo", c("vendor", "--locked", "--versioned-dirs", "--manifest-path",
                 manifest, file.path(staging, "vendor")), stdout = config)
  metadata <- file.path(staging, "metadata.json")
  run("cargo", c("metadata", "--locked", "--offline", "--format-version", "1",
                 "--manifest-path", manifest), stdout = metadata)
  packages <- jsonlite::fromJSON(metadata, simplifyVector = FALSE)$packages
  packages <- Filter(function(package) !is.null(package$source), packages)
  packages <- packages[order(vapply(packages, function(package) {
    paste(package$name, package$version)
  }, character(1)))]
  notices <- unlist(lapply(packages, function(package) {
    authors <- paste(package$authors, collapse = "; ")
    if (!nzchar(authors)) authors <- "See the bundled crate license files"
    c(paste(package$name, package$version),
      paste("Authors:", authors),
      paste("License:", package$license),
      paste("Source:", package$repository), "")
  }))
  writeLines(c("Rust dependencies bundled in vendor.tar.xz.",
               "Upstream license files are retained in each crate directory.", "",
               head(notices, -1L)), file.path(destination, "NOTICE"))
  authors <- sort(unique(unlist(lapply(packages, function(package) package$authors))))
  writeLines(authors, file.path(destination, "AUTHORS"))
  old <- setwd(staging)
  on.exit(setwd(old), add = TRUE)
  run("tar", c("--sort=name", "--mtime=@0", "--owner=0", "--group=0",
               "--numeric-owner", "-cJf", file.path(destination, "vendor.tar.xz"), "vendor"))
  message("Bundled ", length(packages), " crates from rust/Cargo.lock")
}

main()
