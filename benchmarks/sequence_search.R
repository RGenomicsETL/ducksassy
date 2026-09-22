sql_literal <- function(x) paste0("'", gsub("'", "''", x, fixed = TRUE), "'")

benchmark_query <- function(session, sql, result = TRUE) {
  response <- duckknit::duckknit_exec(session, paste(".mode json", sql, ";", sep = "\n"), timeout = 300000L)
  if (nzchar(response$stderr)) stop(response$stderr, call. = FALSE)
  if (result) jsonlite::fromJSON(response$stdout) else invisible(NULL)
}

sequence_workload <- function(directory) {
  paths <- duckhtsbench::duckhts_bench_stage_genbank(fetch = FALSE)
  lines <- readLines(paths[["gbff"]], warn = FALSE)
  origin <- grep("^ORIGIN[[:space:]]*$", lines)
  end <- which(lines == "//")
  stopifnot(length(origin) == 1L, length(end) == 1L, end > origin)
  sequence <- toupper(gsub("[[:space:]0-9]", "", paste(lines[seq.int(origin + 1L, end - 1L)], collapse = "")))
  stopifnot(nchar(sequence) == 4641652L, grepl("^[ACGT]+$", sequence))
  reference_id <- "NC_000913.3"
  version <- grep("^VERSION +", lines, value = TRUE)
  stopifnot(length(version) == 1L, strsplit(version, " +")[[1L]][[2L]] == reference_id)
  fasta <- file.path(directory, "reference.fasta")
  starts <- seq.int(1L, nchar(sequence), by = 80L)
  writeLines(c(paste0(">", reference_id), substring(sequence, starts, pmin(starts + 79L, nchar(sequence)))), fasta)

  pam <- gregexpr("(?=GG)", sequence, perl = TRUE)[[1L]]
  pam <- pam[pam >= 22L]
  positions <- pam[round(seq.int(1L, length(pam), length.out = 8L))] - 21L
  patterns <- substring(sequence, positions, positions + 22L)
  guides <- paste0(substring(sequence, positions, positions + 19L), "NGG")
  stopifnot(length(unique(patterns)) == 8L, all(nchar(guides) == 23L))
  guide_file <- file.path(directory, "guides.txt")
  writeLines(guides, guide_file)
  list(fasta = fasta, guide_file = guide_file, patterns = patterns, guides = guides,
       guide_positions = positions - 1L, reference_id = reference_id, bases = nchar(sequence),
       raw_id = "genbank_ecoli_k12_gbff", raw_sha256 = digest::digest(file = paths[["gbff"]], algo = "sha256"),
       fasta_sha256 = digest::digest(file = fasta, algo = "sha256"), fasta_bytes = file.info(fasta)$size)
}

measure_workload <- function(session, query, series, repetitions, reference) {
  observed <- benchmark_query(session, query)
  if (!is.null(reference) && !identical(observed, reference)) {
    stop("Backend/thread result mismatch: ", series$workload, call. = FALSE)
  }
  measurements <- lapply(seq_len(repetitions), function(iteration) {
    started <- proc.time()[["elapsed"]]
    result <- benchmark_query(session, query)
    elapsed <- proc.time()[["elapsed"]] - started
    if (!identical(result, observed)) stop("Timed result mismatch: ", series$workload, call. = FALSE)
    cbind(series, iteration = iteration, elapsed_seconds = elapsed, output_hits = result$output_hits,
          aggregate_rows = 1L, fingerprint = result$fingerprint)
  })
  list(observed = observed, measurements = do.call(rbind, measurements))
}

sequence_benchmark <- function(repetitions = 7L) {
  directory <- tempfile("ducksassy-sequence-workload-")
  dir.create(directory)
  on.exit(unlink(directory, recursive = TRUE), add = TRUE)
  input <- sequence_workload(directory)
  manifest <- jsonlite::fromJSON("ducksassy-package.json")
  output <- file.path("benchmarks/data", paste0("sequence_search_", manifest$sassy_crate))
  extension <- normalizePath("build/ducksassy.duckdb_extension")
  extension_sha256 <- digest::digest(file = extension, algo = "sha256")
  driver_sha256 <- digest::digest(file = "benchmarks/sequence_search.R", algo = "sha256")
  duckhts <- normalizePath(".deps/duckhts.duckdb_extension")
  cli <- normalizePath(".deps/duckdb-build/duckdb")
  upstream <- normalizePath(".deps/sassy-target/release/sassy")
  source_revision <- system2("git", "rev-parse HEAD", stdout = TRUE)
  native_dirty <- system2("git", c("diff", "--name-only", "HEAD", "--", "src", "include", "rust", "CMakeLists.txt", "ducksassy-package.json"), stdout = TRUE)
  stopifnot(length(native_dirty) == 0L)
  dir.create(output, recursive = TRUE, showWarnings = FALSE)
  old_backend <- Sys.getenv("SASSY_C_BACKEND", unset = NA_character_)
  on.exit(if (is.na(old_backend)) Sys.unsetenv("SASSY_C_BACKEND") else Sys.setenv(SASSY_C_BACKEND = old_backend), add = TRUE)
  sessions <- list()
  on.exit(for (session in sessions) if (session$is_alive()) session$kill(), add = TRUE)

  array_sql <- function(x) paste0("[", paste(sql_literal(x), collapse = ","), "]")
  ordinary <- sprintf("SELECT 0::UBIGINT AS row_id, hit FROM sassy_panel_search_fasta(%s, %s, 2, alphabet := 'dna', max_text_bytes := 8388608)",
                      sql_literal(input$fasta), array_sql(input$patterns))
  crispr <- sprintf("SELECT 0::UBIGINT AS row_id, hit FROM sassy_crispr_panel_search_fasta(%s, %s, 2, max_text_bytes := 8388608)",
                   sql_literal(input$fasta), array_sql(input$guides))
  relational <- "SELECT row_id, UNNEST(sassy_matches(guide, sequence, 2, alphabet := 'dna')) AS hit FROM targets"
  hit_summary <- function(sql) paste0(
    "SELECT count(*)::VARCHAR AS output_hits, sum(hit.cost)::VARCHAR AS edit_cost_sum, ",
    "sum(hash(row_id, hit.pattern_idx, hit.text_start, hit.text_end, hit.pattern_start, hit.pattern_end, ",
    "hit.cost, hit.strand, hit.cigar)::HUGEINT)::VARCHAR AS fingerprint FROM (", sql, ")")
  queries <- lapply(list(fasta = ordinary, crispr = crispr, relational = relational), hit_summary)
  query_templates <- lapply(queries, function(query) {
    gsub(sql_literal(input$fasta), sql_literal("reference.fasta"), query, fixed = TRUE)
  })
  writeLines(c("-- reference.fasta is produced by sequence_workload() from the registered GenBank input.",
    unlist(Map(function(name, query) c(paste0("-- ", name), paste0(query, ";")), names(queries), query_templates))),
    file.path(output, "queries.sql"))
  raw <- list()
  diagnostics <- list()
  checks <- list()
  expected <- list()
  keys <- c("guide", "text_id", "cost", "strand", "start", "end", "cigar")
  oracle <- file.path(output, "crispr-upstream.tsv")
  upstream_version <- system2(upstream, "--version", stdout = TRUE)
  stopifnot(identical(upstream_version, paste("sassy", manifest$sassy_crate)))
  upstream_source <- system2("git", c("-C", ".deps/sassy-source", "rev-parse", "HEAD"), stdout = TRUE)
  stopifnot(identical(upstream_source, manifest$sassy_source_revision))
  stopifnot(system2("git", c("-C", ".deps/sassy-source", "diff", "--quiet", "HEAD")) == 0L)
  upstream_log <- file.path(output, "crispr-upstream.log")
  status <- system2(upstream, c("crispr", "--guide", shQuote(input$guide_file),
    "--output", shQuote(oracle), "--threads", "1", "--k", "2", "--pam-length", "3", "--max-n-frac", "0.2",
    shQuote(input$fasta)),
    stdout = upstream_log, stderr = upstream_log)
  if (status != 0L) stop("Upstream CRISPR failed: ", upstream_log, call. = FALSE)
  upstream_hits <- utils::read.delim(oracle, colClasses = "character", check.names = FALSE)
  stopifnot(all(keys %in% names(upstream_hits)))
  normalize_hits <- function(x) {
    x <- data.frame(lapply(x[keys], as.character), stringsAsFactors = FALSE)
    x <- x[do.call(order, x), , drop = FALSE]
    rownames(x) <- NULL
    x
  }
  upstream_hits <- normalize_hits(upstream_hits)
  workload_sizes <- data.frame(
    workload = c("fasta", "crispr", "relational"),
    input_records = c(1L, 1L, 262144L), patterns_per_record = c(8L, 8L, 1L),
    input_bases = c(input$bases, input$bases, 67108864),
    searched_pair_bases = c(8 * input$bases, 8 * input$bases, 67108864))

  for (backend in c("scalar", "avx2")) for (threads in c(1L, 4L)) {
    name <- paste("sequence-benchmark", backend, threads, sep = "-")
    Sys.setenv(SASSY_C_BACKEND = backend)
    cpus <- if (threads == 1L) "19" else "16-19"
    session <- processx::process$new("taskset",
      c("-c", cpus, cli, "-unsigned", "-no-init", ":memory:"),
      stdin = "|", stdout = "|", stderr = "|", cleanup = TRUE, cleanup_tree = TRUE)
    sessions[[name]] <- session
    host <- benchmark_query(session, "SELECT source_id FROM pragma_version();")
    stopifnot(identical(host$source_id, substr(manifest$duckdb_sdk_revision, 1L, 10L)))
    benchmark_query(session, paste(c(
      "SET autoinstall_known_extensions=false; SET autoload_known_extensions=false;",
      "SET GLOBAL lambda_syntax='ENABLE_SINGLE_ARROW';",
      sprintf("LOAD %s; LOAD %s;", sql_literal(duckhts), sql_literal(extension)),
      readLines(manifest$public_bindings), sprintf("SET threads=%d;", threads),
      sprintf("CREATE TEMP TABLE reference AS SELECT sequence FROM read_fasta(%s, scan_mode := 'sequential');", sql_literal(input$fasta)),
      "CREATE TEMP TABLE targets AS SELECT i::UBIGINT AS row_id, substring(reference.sequence, 1+(i*131)%(length(reference.sequence)-256), 256) AS sequence, substring(reference.sequence, 65+(i*131)%(length(reference.sequence)-256), 23) AS guide FROM reference CROSS JOIN range(262144) AS r(i);",
      "CREATE TEMP TABLE backend_probe AS SELECT sassy_count('ACGA','TTACGATT',0,rc:=false);"
    ), collapse = "\n"), result = FALSE)
    info <- benchmark_query(session, "SELECT * FROM sassy_backend_info() ORDER BY name;")
    stopifnot(identical(info$name[info$selected], backend))
    thread_status <- Sys.glob(sprintf("/proc/%d/task/*/status", session$get_pid()))
    observed_cpus <- vapply(thread_status, function(path) {
      sub("^Cpus_allowed_list:[[:space:]]*", "", grep("^Cpus_allowed_list:", readLines(path), value = TRUE))
    }, character(1L))
    stopifnot(length(observed_cpus) > 0L, all(observed_cpus == cpus))
    diagnostics[[name]] <- cbind(requested = backend, threads = threads, cpus = cpus,
                                 observed_thread_count = length(observed_cpus),
                                 all_thread_affinities_match = TRUE, info)
    denominator <- benchmark_query(session,
      "SELECT count(*)::INTEGER AS input_rows, sum(length(sequence))::DOUBLE AS input_bases FROM targets;")
    stopifnot(denominator$input_rows == 262144L, denominator$input_bases == 67108864)
    fasta_check <- benchmark_query(session, "SELECT count(*)::INTEGER AS records, sum(length(sequence))::DOUBLE AS bases FROM reference;")
    stopifnot(fasta_check$records == 1L, fasta_check$bases == input$bases)

    biological <- benchmark_query(session, sprintf(
      "SELECT %s[hit.pattern_idx::BIGINT+1] AS guide, %s AS text_id, hit.cost, hit.strand, hit.text_start::VARCHAR AS start, hit.text_end::VARCHAR AS end, hit.cigar FROM (%s) ORDER BY guide,hit.text_start,hit.text_end,hit.strand,hit.cost,hit.cigar;",
      array_sql(input$guides), sql_literal(input$reference_id), crispr))
    utils::write.table(biological, file.path(output, paste0(name, "-crispr.tsv")), sep = "\t", quote = FALSE, row.names = FALSE)
    if (!identical(normalize_hits(biological), upstream_hits)) stop("Full CRISPR oracle mismatch: ", name, call. = FALSE)
    constructed <- benchmark_query(session, paste(
      "SELECT count(DISTINCT row_id)::INTEGER AS verified_rows FROM (",
      "SELECT row_id, UNNEST(sassy_matches(guide, sequence, 0, alphabet := 'dna', rc := false)) AS hit FROM targets)",
      "WHERE hit.text_start=64 AND hit.text_end=87 AND hit.cost=0 AND hit.strand='+' AND hit.cigar='23=';"))
    stopifnot(constructed$verified_rows == 262144L)
    checks[[name]] <- data.frame(backend = backend, threads = threads, guide_record_pairs = length(input$guides),
                                 compared_hits = nrow(biological), exact_multiset = TRUE,
                                 constructed_exact_rows = constructed$verified_rows)
    for (workload in names(queries)) {
      series <- cbind(workload_sizes[workload_sizes$workload == workload, ],
                      backend = backend, threads = threads, cpus = cpus)
      measured <- measure_workload(session, queries[[workload]], series, repetitions, expected[[workload]])
      expected[[workload]] <- measured$observed
      raw[[length(raw) + 1L]] <- measured$measurements
    }
    session$kill()
    sessions[[name]] <- NULL
  }
  raw <- do.call(rbind, raw)
  diagnostics <- do.call(rbind, diagnostics)
  checks <- do.call(rbind, checks)
  utils::write.csv(raw, file.path(output, "timings.csv"), row.names = FALSE)
  utils::write.csv(diagnostics, file.path(output, "backends.csv"), row.names = FALSE)
  utils::write.csv(checks, file.path(output, "oracle.csv"), row.names = FALSE)
  stopifnot(identical(extension_sha256, digest::digest(file = extension, algo = "sha256")),
            identical(driver_sha256, digest::digest(file = "benchmarks/sequence_search.R", algo = "sha256")))
  receipts <- list(source_revision = source_revision, native_tree_clean = TRUE,
    sassy_version = manifest$sassy_crate, sassy_revision = manifest$sassy_source_revision,
    sdk_revision = manifest$duckdb_sdk_revision,
    extension_sha256 = extension_sha256,
    duckhts_sha256 = digest::digest(file = duckhts, algo = "sha256"),
    cli_sha256 = digest::digest(file = cli, algo = "sha256"),
    upstream_cli_sha256 = digest::digest(file = upstream, algo = "sha256"),
    driver_sha256 = driver_sha256,
    measured_at_utc = format(Sys.time(), tz = "UTC", usetz = TRUE),
    cpu = system2("lscpu", stdout = TRUE), os = as.list(Sys.info()[c("sysname", "release", "version", "machine")]),
    rust = system2("rustc", "--version", stdout = TRUE), cc = system2("cc", "--version", stdout = TRUE),
    session = capture.output(sessionInfo()), input = input[setdiff(names(input), c("fasta", "guide_file"))],
    repetitions = repetitions, warmups = 1L,
    timing = "R elapsed around persistent duckknit SQL call plus JSON result parsing; per-query whole-hit aggregate included")
  jsonlite::write_json(receipts, file.path(output, "receipt.json"), auto_unbox = TRUE, pretty = TRUE)
  list(raw = raw, diagnostics = diagnostics, checks = checks, receipt = receipts, queries = queries)
}
