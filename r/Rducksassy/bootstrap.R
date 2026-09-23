#!/usr/bin/env Rscript
# Bootstrap the self-contained package sources from the ducksassy repository.
# Run from r/Rducksassy/:  Rscript bootstrap.R ../..
#
# Every copied file is listed in tools/sources.tsv. Generated copies are never
# edited by hand: package-only changes needed by R CMD check live as patches in
# tools/patches/ and are applied after copying.

args <- commandArgs(trailingOnly = TRUE)
if (length(args) != 1L) {
  stop("Usage: Rscript bootstrap.R /path/to/ducksassy", call. = FALSE)
}
repo_root <- normalizePath(args[[1L]], mustWork = TRUE)
package <- normalizePath(".", mustWork = TRUE)
if (!file.exists(file.path(package, "DESCRIPTION.in")) ||
    !file.exists(file.path(repo_root, "src", "ducksassy_core.c"))) {
  stop("Run from r/Rducksassy/ and pass the ducksassy repository root.", call. = FALSE)
}

manifest <- utils::read.delim(file.path(package, "tools", "sources.tsv"), sep = "|",
                              header = FALSE, col.names = c("repo_path", "package_path"),
                              stringsAsFactors = FALSE, quote = "", comment.char = "")
missing <- manifest$repo_path[!file.exists(file.path(repo_root, manifest$repo_path))]
if (length(missing)) stop("Missing canonical sources: ", paste(missing, collapse = ", "), call. = FALSE)

# Remove previous copies so files dropped from the manifest cannot linger.
generated_dirs <- unique(vapply(strsplit(manifest$package_path, "/", fixed = TRUE),
                                function(parts) paste(parts[seq_len(min(2L, length(parts) - 1L))], collapse = "/"),
                                character(1)))
unlink(file.path(package, generated_dirs), recursive = TRUE)
for (i in seq_len(nrow(manifest))) {
  target <- file.path(package, manifest$package_path[[i]])
  dir.create(dirname(target), recursive = TRUE, showWarnings = FALSE)
  if (!file.copy(file.path(repo_root, manifest$repo_path[[i]]), target, overwrite = TRUE)) {
    stop("Could not copy ", manifest$repo_path[[i]], call. = FALSE)
  }
}
message("Copied ", nrow(manifest), " canonical files")

notices <- c("DuckDB C API headers and extension metadata tool.",
             "Copyright 2018-2026 Stichting DuckDB Foundation.",
             "License: MIT; see licenses/DuckDB for the full license.", "",
             readLines(file.path(repo_root, "third_party", "rust", "NOTICE")))
writeLines(notices, file.path(package, "inst", "LICENCE.note"))
stopifnot(file.copy(file.path(package, "DESCRIPTION.in"),
                    file.path(package, "DESCRIPTION"), overwrite = TRUE))

patches <- sort(list.files(file.path(package, "tools", "patches"),
                           pattern = "[.]patch$", full.names = TRUE))
for (patch in patches) {
  message("Applying ", basename(patch))
  status <- system2("patch", c("-p1", "--forward", "--batch", "-d", shQuote(package),
                               "-i", shQuote(patch)))
  if (!identical(status, 0L)) stop("Failed to apply ", basename(patch), call. = FALSE)
}
message("Bootstrapped ", package)
