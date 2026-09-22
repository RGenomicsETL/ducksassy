# Control for table-scan task imbalance: eight complete DuckDB row groups.
source("benchmarks/sequence_search.R")
args <- commandArgs(trailingOnly = TRUE)
if (length(args) != 1L) stop("Usage: Rscript benchmarks/profile_balanced.R OUTPUT")
output <- normalizePath(args[[1L]], mustWork = FALSE)
dir.create(output, recursive = TRUE, showWarnings = FALSE)
input <- sequence_workload(output)
Sys.setenv(SASSY_C_BACKEND = "avx2")
rows <- 8L * 122880L
measurements <- list()
expected <- NULL
for (threads in c(1L, 2L, 4L, 8L)) {
  cpus <- if (threads == 1L) "19" else paste0(20L - threads, "-19")
  session <- processx::process$new("taskset", c("-c", cpus,
    normalizePath(".deps/duckdb-build/duckdb"), "-unsigned", "-no-init", ":memory:"),
    stdin = "|", stdout = "|", stderr = "|", cleanup = TRUE)
  benchmark_query(session, paste(c(
    "SET GLOBAL lambda_syntax='ENABLE_SINGLE_ARROW';",
    paste0("LOAD ", sql_literal(normalizePath(".deps/duckhts.duckdb_extension")), ";"),
    paste0("LOAD ", sql_literal(normalizePath("build/ducksassy.duckdb_extension")), ";"),
    readLines("sql/ducksassy.sql"), sprintf("SET threads=%d;", threads),
    sprintf("CREATE TEMP TABLE reference AS SELECT sequence FROM read_fasta(%s, scan_mode := 'sequential');", sql_literal(input$fasta)),
    sprintf(paste0("CREATE TEMP TABLE targets AS SELECT i::UBIGINT AS row_id, ",
      "substring(sequence, 1+(i*131)%%(length(sequence)-256), 256) AS sequence, ",
      "substring(sequence, 65+(i*131)%%(length(sequence)-256), 23) AS pattern ",
      "FROM reference CROSS JOIN range(%d) AS r(i);"), rows)
  ), collapse = "\n"), result = FALSE)
  groups <- benchmark_query(session, "SELECT row_group_id, max(start + count) - min(start) AS rows FROM pragma_storage_info('targets') GROUP BY row_group_id ORDER BY row_group_id")
  stopifnot(nrow(groups) == 8L, all(groups$rows == 122880))
  query <- paste0("SELECT count(*) AS hits, sum(hit.cost)::DOUBLE AS cost_sum, ",
    "sum(length(hit.cigar))::DOUBLE AS cigar_bytes FROM (",
    "SELECT UNNEST(sassy_matches(pattern, sequence, 2, alphabet := 'dna')) AS hit FROM targets)")
  result <- benchmark_query(session, query)
  if (is.null(expected)) expected <- result
  stopifnot(identical(result, expected))
  for (iteration in 1:5) {
    started <- proc.time()[["elapsed"]]
    result <- benchmark_query(session, query)
    elapsed <- proc.time()[["elapsed"]] - started
    stopifnot(identical(result, expected))
    measurements[[length(measurements) + 1L]] <- data.frame(
      rows = rows, row_groups = 8L, threads = threads, iteration = iteration, seconds = elapsed)
  }
  write.csv(do.call(rbind, measurements), file.path(output, "timings.csv"), row.names = FALSE)
  message("Balanced rows threads=", threads, ": ", median(tail(do.call(rbind, measurements)$seconds, 5L)))
  session$kill()
}
jsonlite::write_json(list(
  source_revision = system2("git", c("rev-parse", "HEAD"), stdout = TRUE),
  driver_sha256 = digest::digest(file = "benchmarks/profile_balanced.R", algo = "sha256"),
  extension_sha256 = digest::digest(file = "build/ducksassy.duckdb_extension", algo = "sha256"),
  cli_sha256 = digest::digest(file = ".deps/duckdb-build/duckdb", algo = "sha256"),
  expected = expected, backend = "avx2", cpu_sets = c("19", "18-19", "16-19", "12-19"),
  measured_at_utc = format(Sys.time(), tz = "UTC", usetz = TRUE)
), file.path(output, "receipt.json"), auto_unbox = TRUE, pretty = TRUE)
