#!/usr/bin/env Rscript
# Stage one self-contained source package from the canonical extension sources.
root <- normalizePath(".", mustWork = TRUE)
package <- file.path(root, "r", "Rducksassy")
extension <- file.path(package, "src", "extension")
files <- c(
  "CMakeLists.txt", "rust/Cargo.toml", "rust/Cargo.lock", "rust/src/lib.rs",
  "include/sassy_c.h", "src/ducksassy.c", "src/sassy_backend.h", "src/sassy_dispatch.c",
  "duckdb_capi/duckdb_v2.h", "duckdb_capi/duckdb_extension_v2.h", "duckdb_capi/REVISION",
  "third_party/rust/vendor.tar.xz",
  "extension-ci-tools/scripts/append_extension_metadata.py"
)
missing <- files[!file.exists(file.path(root, files))]
if (length(missing)) stop("Missing staged sources: ", paste(missing, collapse = ", "))
unlink(extension, recursive = TRUE)
for (path in files) {
  target <- file.path(extension, path)
  dir.create(dirname(target), recursive = TRUE, showWarnings = FALSE)
  if (!file.copy(file.path(root, path), target)) stop("Could not copy ", path)
}
dir.create(file.path(package, "inst", "sql"), recursive = TRUE, showWarnings = FALSE)
stopifnot(file.copy(file.path(root, "sql", "ducksassy.sql"),
                   file.path(package, "inst", "sql"), overwrite = TRUE))
stopifnot(file.copy(file.path(root, "third_party", "rust", "NOTICE"),
                   file.path(package, "inst"), overwrite = TRUE))
dir.create(file.path(package, "inst", "licenses"), showWarnings = FALSE)
stopifnot(file.copy(file.path(root, "duckdb_capi", "LICENSE"),
                   file.path(package, "inst", "licenses", "DuckDB"), overwrite = TRUE))
description <- read.dcf(file.path(package, "DESCRIPTION.in"))
authors <- readLines(file.path(root, "third_party", "rust", "AUTHORS"))
contributors <- lapply(authors, function(author) {
  utils::person(given = sub(" *<.*$", "", author), role = "ctb",
                comment = "Rust dependency; see NOTICE")
})
people <- eval(parse(text = description[1L, "Authors@R"]))
for (contributor in contributors) people <- c(people, contributor)
description[1L, "Authors@R"] <- paste(format(people, style = "R"), collapse = "\n")
write.dcf(description, file.path(package, "DESCRIPTION"), keep.white = "Authors@R")
message("Staged ", length(files), " extension source files in ", package)
