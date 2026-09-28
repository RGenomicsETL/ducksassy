# Run from the repository root after building rust/examples/adapter_bench.rs.
source("benchmarks/sequence_search.R")

adapter_benchmark <- function(label, repetitions = 7L) {
  directory <- tempfile("adapter-input-")
  dir.create(directory)
  on.exit(unlink(directory, recursive = TRUE), add = TRUE)
  output <- file.path("benchmarks/data/adapter_overhead", label)
  dir.create(output, recursive = TRUE, showWarnings = FALSE)
  input <- sequence_workload(directory)
  sequence <- paste(readLines(input$fasta)[-1L], collapse = "")
  starts <- 1L + ((0:262143) * 131) %% (nchar(sequence) - 256L)
  workloads <- list(
    dna = list(k = 2L, data = data.frame(row_id = 0:262143,
      pattern = substring(sequence, starts + 64L, starts + 86L),
      sequence = substring(sequence, starts, starts + 255L))),
    ascii = list(k = 0L, data = data.frame(row_id = 0:4095,
      pattern = "ab", sequence = strrep("ab", 128L)))
  )
  binary <- normalizePath("rust/target/x86_64-unknown-linux-gnu/release/examples/adapter_bench")
  extension <- normalizePath("build/ducksassy.duckdb_extension")
  cli <- normalizePath(".deps/duckdb-build/duckdb")
  previous <- Sys.getenv("SASSY_C_BACKEND", unset = NA_character_)
  Sys.setenv(SASSY_C_BACKEND = "avx2")
  on.exit(if (is.na(previous)) Sys.unsetenv("SASSY_C_BACKEND") else
    Sys.setenv(SASSY_C_BACKEND = previous), add = TRUE)
  session <- processx::process$new("taskset", c("-c", "19", cli, "-unsigned", "-no-init", ":memory:"),
    stdin = "|", stdout = "|", stderr = "|", cleanup = TRUE)
  on.exit(session$kill(), add = TRUE)
  benchmark_query(session, paste0("SET threads=1; SET GLOBAL lambda_syntax='ENABLE_SINGLE_ARROW'; LOAD ",
    sql_literal(normalizePath(".deps/duckhts.duckdb_extension")), "; LOAD ", sql_literal(extension), ";\n",
    paste(readLines("sql/ducksassy.sql"), collapse = "\n")), result = FALSE)
  normalize_hits <- function(path) {
    hits <- read.delim(path, colClasses = "character", check.names = FALSE)
    hits <- hits[do.call(order, hits), , drop = FALSE]
    rownames(hits) <- NULL
    hits
  }
  timings <- list()
  checks <- list()
  for (alphabet in names(workloads)) {
    workload <- workloads[[alphabet]]
    path <- file.path(directory, paste0(alphabet, ".tsv"))
    write.table(workload$data, path, sep = "\t", quote = FALSE, row.names = FALSE, col.names = FALSE)
    expected <- NULL
    for (mode in c("upstream", "ffi")) {
      hits_path <- file.path(directory, paste0(alphabet, "-", mode, "-hits.tsv"))
      result <- processx::run("taskset", c("-c", "19", binary, path, alphabet, mode,
        as.character(workload$k), as.character(repetitions), hits_path), timeout = 300000)
      measured <- read.delim(text = result$stdout)
      timings[[length(timings) + 1L]] <- cbind(workload = alphabet, mode = mode, measured)
      observed <- normalize_hits(hits_path)
      if (is.null(expected)) expected <- observed else stopifnot(identical(expected, observed))
    }
    benchmark_query(session, paste0("CREATE OR REPLACE TEMP TABLE targets AS SELECT * FROM read_csv(",
      sql_literal(path), ", header=false, delim='\t', columns={'row_id':'UBIGINT', ",
      "'pattern':'VARCHAR', 'sequence':'VARCHAR'});"), result = FALSE)
    query <- sprintf(paste0("SELECT row_id, UNNEST(sassy_matches(pattern, sequence, %d, ",
      "alphabet := '%s', rc := %s)) AS hit FROM targets"),
      workload$k, alphabet, if (alphabet == "dna") "true" else "false")
    hits_path <- file.path(directory, paste0(alphabet, "-sql-hits.tsv"))
    benchmark_query(session, paste0("COPY (SELECT row_id, hit.* FROM (", query, ")) TO ",
      sql_literal(hits_path), " (FORMAT CSV, HEADER, DELIMITER '\t');"), result = FALSE)
    observed <- normalize_hits(hits_path)
    stopifnot(identical(expected, observed))
    summary_query <- paste0("SELECT count(*) AS hits, sum(hit.cost)::DOUBLE AS cost_sum, ",
      "sum(length(hit.cigar))::DOUBLE AS cigar_bytes FROM (", query, ")")
    expected_summary <- benchmark_query(session, summary_query)
    stopifnot(expected_summary$hits == nrow(expected),
      expected_summary$cost_sum == sum(as.numeric(expected$cost)),
      expected_summary$cigar_bytes == sum(nchar(expected$cigar, type = "bytes")))
    for (iteration in seq_len(repetitions)) {
      started <- proc.time()[["elapsed"]]
      observed <- benchmark_query(session, summary_query)
      elapsed <- proc.time()[["elapsed"]] - started
      stopifnot(identical(expected_summary, observed))
      timings[[length(timings) + 1L]] <- cbind(workload = alphabet, mode = "sql",
        iteration = iteration, elapsed_seconds = elapsed, observed)
    }
    checks[[alphabet]] <- data.frame(workload = alphabet, records = nrow(workload$data),
      bytes = sum(nchar(workload$data$sequence, type = "bytes")), hits = nrow(expected),
      full_hit_multisets_equal = TRUE, input_sha256 = digest::digest(file = path, algo = "sha256"))
  }
  timings <- do.call(rbind, timings)
  write.csv(timings, file.path(output, "timings.csv"), row.names = FALSE)
  write.csv(do.call(rbind, checks), file.path(output, "checks.csv"), row.names = FALSE)
  jsonlite::write_json(list(
    source_revision = system2("git", c("rev-parse", "HEAD"), stdout = TRUE),
    adapter_source_sha256 = digest::digest(file = "src/host_v2.c", algo = "sha256"),
    core_source_sha256 = digest::digest(file = "src/ducksassy_core.c", algo = "sha256"),
    extension_sha256 = digest::digest(file = extension, algo = "sha256"),
    benchmark_binary_sha256 = digest::digest(file = binary, algo = "sha256"),
    rust_driver_sha256 = digest::digest(file = "rust/examples/adapter_bench.rs", algo = "sha256"),
    r_driver_sha256 = digest::digest(file = "benchmarks/adapter_overhead.R", algo = "sha256"),
    cli_sha256 = digest::digest(file = cli, algo = "sha256"),
    host = benchmark_query(session, "PRAGMA version"),
    backends = benchmark_query(session, "SELECT * FROM sassy_backend_info()"),
    cpu = system2("lscpu", stdout = TRUE),
    measured_at_utc = format(Sys.time(), tz = "UTC", usetz = TRUE),
    reference_sha256 = input$fasta_sha256, repetitions = repetitions, warmups = 1L,
    cpus = "19", threads = 1L, backend = "avx2",
    rust_flags = "-C relocation-model=pic -C target-feature=+avx2,+popcnt",
    timing = "Resident inputs. Native Instant includes search, CIGAR formatting and summary; FFI adds Rust C ABI buffers but excludes C dispatcher. SQL includes dispatcher, vector materialization, aggregation and persistent CLI JSON exchange. Parsing, full-hit export and equality checks are outside timers."
  ), file.path(output, "receipt.json"), auto_unbox = TRUE, pretty = TRUE)
  print(aggregate(elapsed_seconds ~ workload + mode, timings, median))
  invisible(timings)
}

args <- commandArgs(trailingOnly = TRUE)
if (length(args) != 1L) stop("Usage: Rscript benchmarks/adapter_overhead.R LABEL")
adapter_benchmark(args[[1L]])
