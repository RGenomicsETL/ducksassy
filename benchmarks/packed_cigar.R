#!/usr/bin/env Rscript
# Measure full SQL materialization over the packed-CIGAR fixture sequences.
host <- jsonlite::fromJSON("ducksassy-package.json")$r_integration_host
extension <- normalizePath("build/ducksassy.duckdb_extension", mustWork = TRUE)
duckhts <- normalizePath(".deps/duckhts.duckdb_extension", mustWork = TRUE)
driver <- getExportedValue(host$package, "duckdb")(
  config = list(allow_unsigned_extensions = "true"), shared_home = FALSE
)
con <- DBI::dbConnect(driver)
on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
invisible(DBI::dbExecute(con, "SET autoinstall_known_extensions=false"))
invisible(DBI::dbExecute(con, "SET autoload_known_extensions=false"))
invisible(DBI::dbExecute(con, "SET GLOBAL lambda_syntax='ENABLE_SINGLE_ARROW'"))
for (path in c(duckhts, extension)) {
  invisible(DBI::dbExecute(con, paste("LOAD", DBI::dbQuoteString(con, path))))
}
invisible(DBI::dbExecute(con, paste(readLines("sql/ducksassy.sql"), collapse = "\n")))

for (format in c("text", "packed", "both")) {
  query <- sprintf("WITH inputs AS (
    SELECT i, (CASE WHEN i %% 2 = 0 THEN 'GGACGTTTGCACC'
                    ELSE 'GGTGCAAACGTCC' END) || repeat('G', i %% 32) AS sequence
    FROM range(1048576) t(i)
  ) SELECT count(*) AS hits, sum(hit.cost) AS cost,
           sum(length(hit.cigar)) AS chars, sum(length(hit.cigar_ops)) AS ops
    FROM inputs, unnest(sassy_matches('ACGTTGCA', sequence, 1,
      alphabet := 'dna', cigar_format := '%s')) t(hit)", format)
  DBI::dbGetQuery(con, query)
  elapsed <- vapply(seq_len(7L), function(i) {
    system.time(DBI::dbGetQuery(con, query))[["elapsed"]]
  }, numeric(1L))
  result <- DBI::dbGetQuery(con, query)
  cat(format, "median_s", median(elapsed), "range_s",
      paste(range(elapsed), collapse = "-"), "hits", result$hits,
      "cost", result$cost, "chars", result$chars, "ops", result$ops, "\n")
}
