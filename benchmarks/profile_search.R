# Resident SQL workloads for scaling measurements and external perf attachment.
source("benchmarks/sequence_search.R")

args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 2L || !args[[1L]] %in% c("scaling", "worker")) {
  stop("Usage: Rscript benchmarks/profile_search.R scaling OUTPUT | worker OUTPUT THREADS REPEATS MODE")
}
mode <- args[[1L]]
output <- normalizePath(args[[2L]], mustWork = FALSE)
dir.create(output, recursive = TRUE, showWarnings = FALSE)
Sys.setenv(SASSY_C_BACKEND = "avx2")
input <- sequence_workload(output)
cli <- normalizePath(".deps/duckdb-build/duckdb")
extension <- normalizePath("build/ducksassy.duckdb_extension")
ticks <- as.numeric(system2("getconf", "CLK_TCK", stdout = TRUE))

cpu_seconds <- function(pid) {
  line <- readLines(sprintf("/proc/%d/stat", pid))
  fields <- strsplit(sub("^.*\\) ", "", line), " +")[[1L]]
  sum(as.numeric(fields[c(12L, 13L)])) / ticks
}

context_switches <- function(pid) {
  paths <- Sys.glob(sprintf("/proc/%d/task/*/status", pid))
  values <- lapply(paths, function(path) {
    lines <- grep("^(voluntary|nonvoluntary)_ctxt_switches:", readLines(path), value = TRUE)
    as.numeric(sub("^[^:]+:[[:space:]]*", "", lines))
  })
  colSums(do.call(rbind, values))
}

start_session <- function(threads) {
  cpus <- if (threads == 1L) "19" else paste0(20L - threads, "-19")
  session <- processx::process$new("taskset", c("-c", cpus, cli, "-unsigned", "-no-init", ":memory:"),
    stdin = "|", stdout = "|", stderr = "|", cleanup = TRUE)
  benchmark_query(session, paste(c(
    "SET autoinstall_known_extensions=false; SET autoload_known_extensions=false;",
    "SET GLOBAL lambda_syntax='ENABLE_SINGLE_ARROW';",
    paste0("LOAD ", sql_literal(normalizePath(".deps/duckhts.duckdb_extension")), ";"),
    paste0("LOAD ", sql_literal(extension), ";"), readLines("sql/ducksassy.sql"),
    sprintf("SET threads=%d;", threads),
    sprintf("CREATE TEMP TABLE reference AS SELECT sequence FROM read_fasta(%s, scan_mode := 'sequential');",
            sql_literal(input$fasta)),
    paste0("CREATE TEMP TABLE small AS SELECT i::UBIGINT AS row_id, ",
      "substring(sequence, 1+(i*131)%(length(sequence)-256), 256) AS sequence, ",
      "substring(sequence, 65+(i*131)%(length(sequence)-256), 23) AS pattern ",
      "FROM reference CROSS JOIN range(262144) AS r(i);"),
    "CREATE TEMP TABLE large AS SELECT row_id+i*262144 AS row_id, sequence, pattern FROM small CROSS JOIN range(8) AS r(i);",
    "CREATE TEMP TABLE ascii_targets AS SELECT i AS row_id, repeat('ab', 128) AS sequence FROM range(65536) AS r(i);"
  ), collapse = "\n"), result = FALSE)
  session
}

query_for <- function(table, operation) {
  switch(operation,
    ascii = paste0("SELECT count(*) AS hits, sum(hit.cost)::DOUBLE AS cost_sum, ",
      "sum(length(hit.cigar))::DOUBLE AS cigar_bytes FROM (",
      "SELECT UNNEST(sassy_matches('ab', sequence, 0, alphabet := 'ascii', rc := false)) AS hit FROM ascii_targets)"),
    hits = paste0("SELECT count(*) AS hits, sum(hit.cost)::DOUBLE AS cost_sum, ",
      "sum(length(hit.cigar))::DOUBLE AS cigar_bytes FROM (",
      "SELECT UNNEST(sassy_matches(pattern, sequence, 2, alphabet := 'dna')) AS hit FROM ", table, ")"),
    count = paste0("SELECT sum(sassy_count(pattern, sequence, 2, alphabet := 'dna'))::DOUBLE AS hits FROM ", table),
    contains = paste0("SELECT sum(sassy_contains(pattern, sequence, 2, alphabet := 'dna')::INTEGER)::DOUBLE AS hits FROM ", table),
    scan = paste0("SELECT sum(length(sequence))::DOUBLE AS bytes FROM ", table),
    stop("Unknown operation: ", operation)
  )
}

if (mode == "worker") {
  stopifnot(length(args) == 5L)
  threads <- as.integer(args[[3L]])
  repetitions <- as.integer(args[[4L]])
  operation <- args[[5L]]
  session <- start_session(threads)
  query <- query_for("large", operation)
  expected <- benchmark_query(session, query)
  jsonlite::write_json(list(pid = session$get_pid(), threads = threads,
    operation = operation, expected = expected), file.path(output, "ready.json"), auto_unbox = TRUE)
  control <- Sys.getenv("DUCKSASSY_PERF_CONTROL")
  send_control <- function(command) {
    connection <- file(control, open = "w", raw = TRUE)
    on.exit(close(connection))
    writeLines(command, connection)
  }
  if (nzchar(control)) {
    send_control("enable")
  } else {
    deadline <- Sys.time() + 120
    while (!file.exists(file.path(output, "go"))) {
      if (Sys.time() > deadline) stop("Timed out waiting for profiler")
      Sys.sleep(0.1)
    }
  }
  started <- proc.time()[["elapsed"]]
  for (iteration in seq_len(repetitions)) {
    stopifnot(identical(benchmark_query(session, query), expected))
  }
  writeLines(as.character(proc.time()[["elapsed"]] - started), file.path(output, "elapsed.txt"))
  if (nzchar(control)) send_control("disable")
  session$kill()
} else {
  measurements <- list()
  expected <- list()
  for (threads in c(1L, 2L, 4L, 8L)) {
    session <- start_session(threads)
    for (table in c("small", "large")) {
      storage <- benchmark_query(session, sprintf("SELECT count(DISTINCT row_group_id) AS groups FROM pragma_storage_info('%s')", table))
      for (operation in c("hits", "count", "contains", "scan")) {
        query <- query_for(table, operation)
        result <- benchmark_query(session, query)
        key <- paste(table, operation, sep = "-")
        if (is.null(expected[[key]])) expected[[key]] <- result
        stopifnot(identical(expected[[key]], result))
        for (iteration in 1:5) {
          switches_start <- context_switches(session$get_pid())
          cpu_start <- cpu_seconds(session$get_pid())
          started <- proc.time()[["elapsed"]]
          result <- benchmark_query(session, query)
          elapsed <- proc.time()[["elapsed"]] - started
          cpu <- cpu_seconds(session$get_pid()) - cpu_start
          switches <- context_switches(session$get_pid()) - switches_start
          stopifnot(identical(expected[[key]], result))
          measurements[[length(measurements) + 1L]] <- data.frame(
            table = table, rows = if (table == "small") 262144L else 2097152L,
            row_groups = storage$groups, operation = operation, threads = threads,
            iteration = iteration, seconds = elapsed, cpu_seconds = cpu,
            voluntary_switches = switches[[1L]], involuntary_switches = switches[[2L]])
        }
        write.csv(do.call(rbind, measurements), file.path(output, "timings.csv"), row.names = FALSE)
        message(table, " ", operation, " threads=", threads, ": ",
                median(tail(do.call(rbind, measurements)$seconds, 5L)), " seconds")
      }
    }
    session$kill()
  }
  stopifnot(all(expected[["large-hits"]] == expected[["small-hits"]] * 8),
    expected[["large-count"]]$hits == expected[["large-hits"]]$hits,
    expected[["small-count"]]$hits == expected[["small-hits"]]$hits,
    expected[["large-contains"]]$hits == 2097152,
    expected[["small-contains"]]$hits == 262144)
  jsonlite::write_json(list(
    source_revision = system2("git", c("rev-parse", "HEAD"), stdout = TRUE),
    extension_sha256 = digest::digest(file = extension, algo = "sha256"),
    driver_sha256 = digest::digest(file = "benchmarks/profile_search.R", algo = "sha256"),
    cli_sha256 = digest::digest(file = cli, algo = "sha256"),
    results = expected, backend = "avx2", cpu_sets = c("19", "18-19", "16-19", "12-19"),
    measured_at_utc = format(Sys.time(), tz = "UTC", usetz = TRUE),
    timing = "Warm persistent SQL, resident tables, R elapsed including CLI exchange; CPU time from /proc/PID/stat. Five repetitions. Large repeats the verified small workload eight times."
  ), file.path(output, "receipt.json"), auto_unbox = TRUE, pretty = TRUE)
}
