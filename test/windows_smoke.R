#!/usr/bin/env Rscript
# Run with DBI and duckdb 1.5.5 installed, passing the MinGW/Rtools artifact path.
args <- commandArgs(trailingOnly = TRUE)
stopifnot(length(args) == 1L)

run_smoke <- function(extension) {
  con <- DBI::dbConnect(duckdb::duckdb(
    shared_home = FALSE, config = list(allow_unsigned_extensions = "true")
  ))
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  query <- function(sql) DBI::dbGetQuery(con, sql)
  print(query("PRAGMA version"))
  print(query("PRAGMA platform"))
  stopifnot(query("PRAGMA version")$library_version == "v1.5.5")
  DBI::dbExecute(con, paste("LOAD", DBI::dbQuoteString(con, normalizePath(extension, winslash = "/"))))
  stopifnot(query("SELECT count(DISTINCT function_name)::INTEGER AS n
    FROM duckdb_functions() WHERE starts_with(function_name, 'sassy_')")$n == 10L)
  for (type in c("VARCHAR", "BLOB")) {
    result <- query(sprintf("SELECT
      sassy_count('ACGT'::%1$s, 'TTACGTTT'::%1$s, 0, 'dna', false)::INTEGER AS n,
      sassy_count_many(['ACGT'::%1$s], 'TTACGTTT'::%1$s, 0, 'dna', false)::INTEGER AS panel_n,
      len(sassy_crispr_matches('ACGTNGG'::%1$s, 'TTACGTAGGTT'::%1$s, 0))::INTEGER AS crispr", type))
    stopifnot(result$n == 1L, result$panel_n == 1L, result$crispr == 1L)
  }
  stopifnot(inherits(tryCatch(query("SELECT sassy_matches('ACGT', 'ACGT', -1)"),
                             error = identity), "error"))
  stopifnot(is.na(query("SELECT sassy_count(NULL, 'ACGT', 0) AS n")$n))
  DBI::dbExecute(con, "SET threads=4")
  DBI::dbExecute(con, "CREATE TABLE targets AS SELECT i, CASE WHEN i%2=0 THEN 'ACGT' ELSE 'TTTT' END AS text FROM range(500000) t(i)")
  for (iteration in seq_len(3L)) {
    stopifnot(query("SELECT sum(sassy_count('ACGT', text, 0, 'dna', false))::INTEGER AS n FROM targets")$n == 250000L)
  }
  stopifnot(query("SELECT len(sassy_matches('ACGT', repeat('ACGT', 600), 0, 'dna', false))::INTEGER AS n")$n == 600L)
  stopifnot(query("SELECT text_start::INTEGER AS start FROM sassy_grep('error', 'error: disk full', 0) LIMIT 1")$start == 0L)
  print(query("SELECT * FROM sassy_backend_info()"))
}
run_smoke(args[[1L]])
