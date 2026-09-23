#!/usr/bin/env Rscript
# Persistent CLI comparison, with identical inputs and complete sorted hits.
source("benchmarks/sequence_search.R")

run_host_comparison <- function(output = "benchmarks/data/host_comparison", repetitions = 9L) {
  dir.create(output, recursive = TRUE, showWarnings = FALSE)
  output <- normalizePath(output)
  sources <- c('src/ducksassy_core.c', 'src/ducksassy_core.h', 'src/host_v1.c', 'src/host_v2.c',
               'benchmarks/host_comparison.R', 'benchmarks/sequence_search.R', 'sql/ducksassy.sql',
               'CMakeLists.txt')
  source_hashes <- vapply(sources, function(path) digest::digest(file = path, algo = 'sha256'), character(1L))
  stopifnot(identical(digest::digest(file = 'build-v1/libsassy_c.a', algo = 'sha256'),
                      digest::digest(file = 'build-v2/libsassy_c.a', algo = 'sha256')))
  fixture <- tempfile("sassy-host-fixture-")
  dir.create(fixture)
  on.exit(unlink(fixture, recursive = TRUE), add = TRUE)
  set.seed(739L)
  reference <- paste0(sample(c("A", "C", "G", "T"), 4641652L, replace = TRUE), collapse = "")
  guides <- substring(reference, seq(1001L, by = 500000L, length.out = 8L),
                      seq(1023L, by = 500000L, length.out = 8L))
  crispr <- paste0(substr(guides, 1L, 20L), "NGG")
  fasta <- file.path(fixture, "reference.fasta")
  writeLines(c(">reference", reference), fasta)
  starts <- 1L + (seq_len(65536L) * 131L) %% (nchar(reference) - 150L)
  reads <- substring(reference, starts, starts + 149L)
  fastq <- file.path(fixture, "reads.fastq")
  writeLines(as.vector(rbind(paste0("@read", seq_along(reads)), reads, "+", strrep("I", 150L))), fastq)
  array_sql <- function(x) paste0('[', paste(sql_literal(x), collapse = ','), ']')
  panel <- array_sql(guides)
  queries <- list(
    fastq_rows = sprintf("SELECT substr(name,5)::UBIGINT AS row_id, unnest(sassy_matches(substr(sequence,65,23),sequence,1,rc:=false)) AS hit FROM read_fastq(%s)", sql_literal(fastq)),
    fasta_panel = sprintf("SELECT 0::UBIGINT AS row_id, hit FROM sassy_panel_search_fasta(%s,%s,2,rc:=false)", sql_literal(fasta), panel),
    crispr_panel = sprintf("SELECT 0::UBIGINT AS row_id, hit FROM sassy_crispr_panel_search_fasta(%s,%s,2,rc:=true)", sql_literal(fasta), array_sql(crispr)),
    dense_cigar = "SELECT i AS row_id, unnest(sassy_matches('abcdefghijklmno',repeat('ab!de!gh!jk!mn!#',128+(i%5)::INTEGER),5,alphabet:='ascii',rc:=false)) AS hit FROM range(2048) r(i)"
  )
  queries$dense_both <- sub("rc:=false", "rc:=false,cigar_format:='both'", queries$dense_cigar, fixed = TRUE)
  native_queries <- list(
    fastq_rows = sprintf("SELECT substr(name,5)::UBIGINT AS row_id, unnest(sassy_matches(substr(sequence,65,23),sequence,1,'iupac',false)) AS hit FROM read_fastq(%s)", sql_literal(fastq)),
    fasta_panel = sprintf("SELECT 0::UBIGINT AS row_id, hit FROM read_fasta(%s,scan_mode:='sequential') r CROSS JOIN LATERAL unnest(sassy_matches_many(%s,r.sequence,2,'dna',false)) m(hit)", sql_literal(fasta), panel),
    crispr_panel = sprintf("SELECT 0::UBIGINT AS row_id, hit FROM read_fasta(%s,scan_mode:='sequential') r CROSS JOIN LATERAL unnest(sassy_crispr_matches_many(%s,r.sequence,2)) m(hit)", sql_literal(fasta), array_sql(crispr)),
    dense_cigar = "SELECT i AS row_id, unnest(sassy_matches('abcdefghijklmno',repeat('ab!de!gh!jk!mn!#',128+(i%5)::INTEGER),5,'ascii',false)) AS hit FROM range(2048) r(i)"
  )
  native_queries$dense_both <- sub("'ascii',false", "'ascii',false,false,'both'", native_queries$dense_cigar, fixed = TRUE)
  host_query <- function(sql, name, workload) {
    if (name == 'released_v1') sub(queries[[workload]], native_queries[[workload]], sql, fixed = TRUE) else sql
  }
  specs <- list(
    baseline_v2 = c(cli = ".deps/duckdb-build/duckdb", extension = "build-baseline/ducksassy.duckdb_extension"),
    refactored_v2 = c(cli = ".deps/duckdb-build/duckdb", extension = "build-v2/ducksassy.duckdb_extension"),
    released_v1 = c(cli = ".deps-v1/cli/duckdb", extension = "build-v1/ducksassy.duckdb_extension")
  )
  cpus <- Sys.getenv("SASSY_BENCH_CPUS", "16-19")
  sessions <- list()
  on.exit(lapply(sessions, function(session) if (session$is_alive()) session$kill()), add = TRUE)
  receipts <- list()
  for (name in names(specs)) {
    spec <- vapply(specs[[name]], normalizePath, character(1L), mustWork = TRUE)
    session <- processx::process$new(Sys.which("taskset"),
      c("-c", cpus, spec[["cli"]], "-unsigned", "-batch", "-bail", "-json", "-no-init", ":memory:"),
      env = c(SASSY_C_BACKEND = "avx2"), stdin = "|", stdout = "|", stderr = "|",
      cleanup = TRUE, cleanup_tree = TRUE)
    sessions[[name]] <- session
    bootstrap <- if (name == "released_v1") character() else
      readLines(if (name == "baseline_v2") "build-baseline/bootstrap.sql" else "sql/ducksassy.sql")
    benchmark_query(session, paste(c(
      "SET autoload_known_extensions=false; SET autoinstall_known_extensions=false;",
      if (name != "released_v1") "SET GLOBAL lambda_syntax='ENABLE_SINGLE_ARROW';",
      sprintf("LOAD %s; LOAD %s;", sql_literal(normalizePath(".deps/duckhts.duckdb_extension")), sql_literal(spec[["extension"]])),
      bootstrap,
      if (name == "released_v1") "SELECT sassy_count('ACGT','ACGT',0,'dna',false);" else
        "SELECT sassy_count('ACGT','ACGT',0,rc:=false);"
    ), collapse = "\n"), result = FALSE)
    backend <- benchmark_query(session, 'SELECT * FROM sassy_backend_info() ORDER BY name;')
    stopifnot(identical(backend$name[backend$selected], "avx2"))
    receipts[[name]] <- list(cli = spec[["cli"]],
      version = benchmark_query(session, "SELECT * FROM pragma_version();"),
      cli_sha256 = digest::digest(file = spec[["cli"]], algo = "sha256"),
      extension_sha256 = digest::digest(file = spec[["extension"]], algo = "sha256"), backend = backend)
  }
  raw <- checks <- list()
  aggregates <- lapply(queries, function(query) paste0(
    "SELECT count(*)::DOUBLE AS hits, sum(hit.pattern_idx)::DOUBLE AS patterns, ",
    "sum(hit.text_start)::DOUBLE AS starts, sum(hit.text_end)::DOUBLE AS ends, ",
    "sum(hit.cost)::DOUBLE AS costs, sum(length(hit.cigar))::DOUBLE AS cigar_bytes, ",
    "sum((hit.strand='-')::INTEGER)::DOUBLE AS reverse_hits FROM (", query, ");"))
  for (threads in c(1L, 4L)) {
    for (session in sessions) benchmark_query(session, sprintf("SET threads=%d;", threads), result = FALSE)
    for (workload in names(queries)) {
      expected <- expected_hash <- NULL
      for (name in names(sessions)) {
        session <- sessions[[name]]
        observed <- benchmark_query(session, host_query(aggregates[[workload]], name, workload))
        if (is.null(expected)) expected <- observed
        stopifnot(identical(expected, observed))
        hits_file <- file.path(fixture, paste0(name, ".csv"))
        full_query <- sprintf("COPY (SELECT row_id,hit.pattern_idx,hit.text_start,hit.text_end,hit.pattern_start,hit.pattern_end,hit.cost,hit.strand,hit.cigar%s FROM (%s) ORDER BY ALL) TO %s (FORMAT CSV,HEADER true);", if (workload == 'crispr_panel') '' else ',hit.cigar_ops', host_query(queries[[workload]], name, workload), sql_literal(hits_file))
        benchmark_query(session, full_query, result = FALSE)
        checksum <- digest::digest(file = hits_file, algo = "sha256")
        if (is.null(expected_hash)) expected_hash <- checksum
        stopifnot(identical(expected_hash, checksum))
        checks[[length(checks) + 1L]] <- data.frame(host = name, threads, workload,
          hits = observed$hits, sorted_hits_sha256 = checksum, exact_multiset = TRUE)
      }
      for (iteration in seq_len(repetitions)) {
        order <- if (iteration %% 2L) names(sessions) else rev(names(sessions))
        for (name in order) {
          elapsed <- unname(system.time(for (batch in seq_len(3L)) {
            observed <- benchmark_query(sessions[[name]], host_query(aggregates[[workload]], name, workload))
            stopifnot(identical(expected, observed))
          })[["elapsed"]])
          raw[[length(raw) + 1L]] <- data.frame(host = name, threads, workload, iteration,
            batch_calls = 3L, batch_seconds = elapsed, seconds = elapsed / 3, hits = observed$hits)
        }
      }
      cat(workload, threads, "threads: full hits agree\n")
    }
  }
  raw <- do.call(rbind, raw)
  checks <- do.call(rbind, checks)
  write.csv(raw, file.path(output, "timings.csv"), row.names = FALSE)
  write.csv(checks, file.path(output, "checks.csv"), row.names = FALSE)
  stopifnot(identical(source_hashes, vapply(sources, function(path) digest::digest(file = path, algo = 'sha256'), character(1L))))
  for (name in names(specs)) {
    stopifnot(identical(receipts[[name]]$extension_sha256,
      digest::digest(file = specs[[name]][['extension']], algo = 'sha256')))
  }
  receipt <- list(baseline_revision = "a841d8df52198c62beface151de445a6dc9e9387",
    measured_at_utc = format(Sys.time(), tz = "UTC", usetz = TRUE),
    sources = as.list(source_hashes),
    rust_archive_sha256 = digest::digest(file = 'build-v2/libsassy_c.a', algo = 'sha256'),
    build = list(type = 'Release (-O3 -DNDEBUG)',
                 c_flags = '-std=gnu11 -fPIC -fvisibility=hidden -Wall -Wextra -Werror=implicit-function-declaration -Werror=incompatible-pointer-types',
                 cc = system2('cc', '--version', stdout = TRUE),
                 rust = system2('rustc', '--version', stdout = TRUE)),
    hosts = receipts, duckhts_sha256 = digest::digest(file = ".deps/duckhts.duckdb_extension", algo = "sha256"),
    fasta_sha256 = digest::digest(file = fasta, algo = "sha256"), fastq_sha256 = digest::digest(file = fastq, algo = "sha256"),
    seed = 739L, fasta_bases = nchar(reference), fastq_rows = length(reads), fastq_read_length = 150L,
    guides = guides, crispr_guides = crispr, repetitions = repetitions, batch_calls = 3L, cpus = cpus,
    cpu = system2("lscpu", stdout = TRUE), session = capture.output(sessionInfo()),
    timing = "Warm persistent CLI wall time for batches of three calls, divided by three; includes parse/bind, local reader, search, hit aggregation and JSON parsing; startup and full-hit verification excluded. Host order alternates each repetition; identical AVX2 Rust archive.")
  jsonlite::write_json(receipt, file.path(output, "receipt.json"), auto_unbox = TRUE, pretty = TRUE)
  print(aggregate(seconds ~ host + threads + workload, raw, median), row.names = FALSE)
  invisible(raw)
}
if (sys.nframe() == 0L) run_host_comparison()
