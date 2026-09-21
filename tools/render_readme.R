#!/usr/bin/env Rscript

main <- function() {
  args <- commandArgs(trailingOnly = TRUE)
  if (length(args) > 1L) {
    stop("Usage: Rscript tools/render_readme.R [document.Rmd]", call. = FALSE)
  }
  input <- if (length(args) == 1L) args[[1L]] else "README.Rmd"
  manifest <- jsonlite::fromJSON("ducksassy-package.json")
  artifacts <- normalizePath(c(
    Sys.getenv("DUCKHTS_EXTENSION", ".deps/duckhts.duckdb_extension"),
    Sys.getenv("DUCKSASSY_EXTENSION", "build/ducksassy.duckdb_extension")
  ), mustWork = TRUE)

  old_options <- options(duckknit.duckdb = normalizePath("tools/duckdb-unsigned"))
  on.exit(options(old_options), add = TRUE)
  session <- duckknit::duckknit_start_session("ducksassy-readme")
  on.exit(duckknit::duckknit_kill_session("ducksassy-readme"), add = TRUE)
  execute_setup <- function(sql) {
    result <- duckknit::duckknit_exec(session, paste(sql, collapse = "\n"))
    if (nzchar(result$stderr)) {
      stop(result$stderr, call. = FALSE)
    }
    invisible(result$stdout)
  }

  # Reject incompatible preview hosts before loading native extension code.
  execute_setup(sprintf(
    "SELECT CASE WHEN source_id = '%s' THEN true ELSE error('README requires the pinned DuckDB SDK host') END FROM pragma_version();",
    substr(manifest$duckdb_sdk_revision, 1L, 10L)
  ))
  execute_setup(c(
    "SET autoinstall_known_extensions=false;",
    "SET autoload_known_extensions=false;",
    "SET GLOBAL lambda_syntax='ENABLE_SINGLE_ARROW';",
    sprintf("LOAD '%s';", gsub("'", "''", artifacts, fixed = TRUE)),
    readLines(manifest$public_bindings)
  ))
  rmarkdown::render(input, envir = new.env(), knit_root_dir = getwd(), quiet = TRUE)
}

main()
