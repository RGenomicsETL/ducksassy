#!/usr/bin/env Rscript
# Exercise the native extension through the pinned R/DBI preview host.

main <- function() {
  manifest <- jsonlite::fromJSON("ducksassy-package.json")
  host <- manifest$r_integration_host
  driver <- getExportedValue(host$package, "duckdb")(
    config = list(allow_unsigned_extensions = "true"), shared_home = FALSE
  )
  con <- DBI::dbConnect(driver)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  version <- DBI::dbGetQuery(con, "SELECT * FROM pragma_version()")
  stopifnot(identical(version$source_id, substr(host$engine_revision, 1L, 10L)))
  artifacts <- normalizePath(c(
    Sys.getenv("DUCKHTS_EXTENSION", ".deps/duckhts.duckdb_extension"),
    Sys.getenv("DUCKSASSY_EXTENSION", "build/ducksassy.duckdb_extension")
  ), mustWork = TRUE)
  DBI::dbExecute(con, "SET autoinstall_known_extensions=false")
  DBI::dbExecute(con, "SET autoload_known_extensions=false")
  DBI::dbExecute(con, "SET GLOBAL lambda_syntax='ENABLE_SINGLE_ARROW'")
  for (artifact in artifacts) {
    DBI::dbExecute(con, paste("LOAD", DBI::dbQuoteString(con, artifact)))
  }
  DBI::dbExecute(con, paste(readLines(manifest$public_bindings), collapse = "\n"))
  tests <- sort(list.files("test/sql", pattern = "\\.sql$", full.names = TRUE))
  stopifnot(length(tests) > 0L)
  for (test in tests) {
    DBI::dbExecute(con, paste(readLines(test), collapse = "\n"))
  }
  backends <- DBI::dbGetQuery(con, "SELECT * FROM sassy_backend_info()")
  stopifnot(sum(backends$selected) == 1L)
  requested_backend <- Sys.getenv("SASSY_C_BACKEND", "auto")
  if (nzchar(requested_backend) && requested_backend != "auto") {
    stopifnot(identical(backends$name[backends$selected], requested_backend))
  }
  failure <- tryCatch(
    DBI::dbGetQuery(con, "SELECT sassy_crispr_matches('ACGTNGG', 'ACGTAGG', 0, max_n_frac := -1)"),
    error = identity
  )
  stopifnot(inherits(failure, "error"), grepl("max_n_frac", conditionMessage(failure), fixed = TRUE))
  recovered <- DBI::dbGetQuery(con, "SELECT len(sassy_crispr_matches('ACGTNGG', 'ACGTAGG', 0)) AS hits")
  stopifnot(as.numeric(recovered$hits) == 1)
  cat(length(tests), "SQL families and error recovery passed through R/DBI; engine", version$source_id, "\n")
}

main()
