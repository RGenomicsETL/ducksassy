#!/usr/bin/env Rscript

main <- function() {
  library <- normalizePath(".deps", mustWork = TRUE)
  library <- file.path(library, "Rlib")
  dir.create(library, showWarnings = FALSE)
  .libPaths(c(library, .libPaths()))
  required <- c("jsonlite", "digest", "knitr", "rmarkdown", "processx", "tibble")
  missing <- required[!vapply(required, requireNamespace, logical(1), quietly = TRUE)]
  if (length(missing) > 0L) {
    install.packages(missing, lib = library, repos = "https://cloud.r-project.org")
  }
  sources <- normalizePath(c(".deps/duckknit", ".deps/duckhtsbench-source/r/duckhtsbench"), mustWork = TRUE)
  old_directory <- getwd()
  on.exit(setwd(old_directory))
  setwd(".deps")
  for (source in sources) {
    metadata <- read.dcf(file.path(source, "DESCRIPTION"))
    archive <- paste0(metadata[1L, "Package"], "_", metadata[1L, "Version"], ".tar.gz")
    status <- system2(file.path(R.home("bin"), "R"),
                      c("CMD", "build", "--no-build-vignettes", "--no-manual", shQuote(source)))
    if (status != 0L) stop("R package build failed: ", source, call. = FALSE)
    status <- system2(file.path(R.home("bin"), "R"),
                      c("CMD", "INSTALL", shQuote(paste0("--library=", library)), shQuote(archive)))
    if (status != 0L) stop("R package install failed: ", archive, call. = FALSE)
  }
}

main()
