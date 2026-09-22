#!/usr/bin/env Rscript
# Compare complete CRISPR hit multisets with the pinned upstream CLI.

main <- function() {
  manifest <- jsonlite::fromJSON("ducksassy-package.json")
  cli <- normalizePath(Sys.getenv("DUCKDB_CLI", ".deps/duckdb-build/duckdb"), mustWork = TRUE)
  oracle <- normalizePath(Sys.getenv("SASSY_CLI", ".deps/sassy-target/release/sassy"), mustWork = TRUE)
  source <- normalizePath(Sys.getenv("SASSY_SOURCE", ".deps/sassy-source"), mustWork = TRUE)
  source_revision <- system2("git", c("-C", shQuote(source), "rev-parse", "HEAD"), stdout = TRUE)
  stopifnot(identical(source_revision, manifest$sassy_source_revision))
  stopifnot(system2("git", c("-C", shQuote(source), "diff", "--quiet", "HEAD")) == 0L)
  version <- system2(cli, "--version", stdout = TRUE)
  stopifnot(any(grepl(substr(manifest$duckdb_sdk_revision, 1L, 10L), version, fixed = TRUE)))
  stopifnot(identical(system2(oracle, "--version", stdout = TRUE), paste("sassy", manifest$sassy_crate)))

  artifacts <- normalizePath(c(
    Sys.getenv("DUCKHTS_EXTENSION", ".deps/duckhts.duckdb_extension"),
    Sys.getenv("DUCKSASSY_EXTENSION", "build/ducksassy.duckdb_extension")
  ), mustWork = TRUE)
  fixture <- normalizePath("test/data/references.fasta", mustWork = TRUE)
  headers <- readLines(fixture)
  headers <- substring(headers[startsWith(headers, ">")], 2L)
  record_ids <- sub("[[:space:]].*$", "", headers)
  stopifnot(length(record_ids) == 8L, !anyDuplicated(record_ids))
  # The CLI keeps full headers; DuckHTS NAME is the first whitespace-delimited token.
  id_map <- setNames(record_ids, headers)
  guides <- c("ACGTNGG", "TTTTNGG", "ACGTNGG")
  requested_backend <- Sys.getenv("SASSY_C_BACKEND", "auto")
  if (!nzchar(requested_backend)) requested_backend <- "auto"
  stopifnot(requested_backend %in% c("auto", "scalar", "avx2", "avx512", "neon", "wasm128"))
  output <- file.path("build/crispr-oracle", requested_backend)
  dir.create(output, recursive = TRUE, showWarnings = FALSE)
  guide_file <- file.path(output, "guides.txt")
  writeLines(guides, guide_file)
  quote_sql <- function(x) paste0("'", gsub("'", "''", x, fixed = TRUE), "'")
  panel <- paste0("[", paste(quote_sql(guides), collapse = ","), "]")
  bootstrap <- c(
    "SET autoinstall_known_extensions=false;",
    "SET autoload_known_extensions=false;",
    "SET GLOBAL lambda_syntax='ENABLE_SINGLE_ARROW';",
    sprintf("LOAD %s;", quote_sql(artifacts)),
    readLines(manifest$public_bindings)
  )
  backend_file <- file.path(output, "backend.json")
  backend_log <- file.path(output, "backend.log")
  status <- system2(cli, c("-unsigned", "-no-init", "-batch", "-bail", "-json", ":memory:"),
    input = c(bootstrap,
      "CREATE TEMP TABLE backend_probe AS SELECT sassy_count('ACGA', 'TTACGATT', 0, rc := false);",
      "SELECT * FROM sassy_backend_info() ORDER BY name;"),
    stdout = backend_file, stderr = backend_log)
  if (status != 0L) stop("Backend inspection failed; see ", backend_log, call. = FALSE)
  backends <- jsonlite::fromJSON(backend_file)
  stopifnot(
    setequal(backends$name, c("scalar", "avx2", "avx512", "neon", "wasm128")),
    !anyDuplicated(backends$name),
    sum(backends$selected) == 1L
  )
  selected_backend <- backends$name[backends$selected]
  if (requested_backend != "auto") stopifnot(identical(selected_backend, requested_backend))
  keys <- c("guide", "text_id", "cost", "strand", "start", "end", "cigar")
  canonical <- function(x) {
    x <- x[, keys, drop = FALSE]
    # DuckDB emits UBIGINT coordinates as JSON strings; preserve exact integers.
    x[] <- lapply(x, as.character)
    x <- x[do.call(order, x), , drop = FALSE]
    rownames(x) <- NULL
    x
  }
  profiles <- expand.grid(k = 0:2, rc = c(FALSE, TRUE), allow_pam_edits = c(FALSE, TRUE),
                          max_n_frac = c(0, 0.2, 1))
  profiles$output_hits <- NA_integer_
  for (i in seq_len(nrow(profiles))) {
    profile <- profiles[i, ]
    stem <- file.path(output, sprintf("profile-%02d", i))
    expected_file <- paste0(stem, "-upstream.tsv")
    log <- paste0(stem, "-upstream.log")
    args <- c("crispr", "--threads", "1", "--guide", shQuote(guide_file), "--k", profile$k,
              "--pam-length", "3", "--max-n-frac", profile$max_n_frac,
              "--output", shQuote(expected_file))
    if (!profile$rc) args <- c(args, "--no-rc")
    if (profile$allow_pam_edits) args <- c(args, "--allow-pam-edits")
    status <- system2(oracle, c(args, shQuote(fixture)), stdout = log, stderr = log)
    if (status != 0L) stop("Upstream failed; see ", log, call. = FALSE)
    expected <- read.delim(expected_file, check.names = FALSE, quote = "", comment.char = "", colClasses = "character")
    stopifnot(all(expected$text_id %in% names(id_map)))
    expected$text_id <- unname(id_map[expected$text_id])
    sql <- sprintf(
      paste0("SELECT %s[hit.pattern_idx::BIGINT+1] AS guide, name AS text_id, hit.cost, hit.strand, ",
             "hit.text_start AS start, hit.text_end AS end, hit.cigar ",
             "FROM sassy_crispr_panel_search_fasta(%s, %s, %d, rc := %s, ",
             "allow_pam_edits := %s, max_n_frac := %.17g);"),
      panel, quote_sql(fixture), panel, profile$k, tolower(profile$rc),
      tolower(profile$allow_pam_edits), profile$max_n_frac
    )
    observed_file <- paste0(stem, "-ducksassy.json")
    log <- paste0(stem, "-ducksassy.log")
    status <- system2(cli, c("-unsigned", "-no-init", "-batch", "-bail", "-json", ":memory:"),
                      input = c(bootstrap, sql), stdout = observed_file, stderr = log)
    if (status != 0L) stop("Ducksassy failed; see ", log, call. = FALSE)
    observed <- jsonlite::fromJSON(observed_file)
    if (is.list(observed) && length(observed) == 0L) observed <- expected[FALSE, keys, drop = FALSE]
    if (!identical(canonical(observed), canonical(expected))) {
      stop("CRISPR multiset disagreement in profile ", i, "; artifacts: ", stem, call. = FALSE)
    }
    profiles$output_hits[i] <- nrow(observed)
  }
  hash_files <- c(duckdb = cli, sassy = oracle, ducksassy = artifacts[2L], duckhts = artifacts[1L], fixture = fixture)
  receipt <- list(
    sassy_source_revision = source_revision,
    duckdb_sdk_revision = manifest$duckdb_sdk_revision,
    input_records = length(record_ids), guides = guides,
    guide_record_comparisons = nrow(profiles) * length(record_ids) * length(guides),
    profiles = profiles,
    requested_backend = requested_backend, backends = backends,
    artifact_sha256 = vapply(hash_files, digest::digest, character(1), file = TRUE, algo = "sha256")
  )
  jsonlite::write_json(receipt, file.path(output, "receipt.json"), auto_unbox = TRUE, pretty = TRUE)
  cat(nrow(profiles), "profiles;", receipt$guide_record_comparisons,
      "guide/record comparisons;", sum(profiles$output_hits), "output hits:", selected_backend,
      "exact upstream agreement\n")
}

main()
