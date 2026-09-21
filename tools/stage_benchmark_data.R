#!/usr/bin/env Rscript

paths <- duckhtsbench::duckhts_bench_stage_genbank(fetch = TRUE)
cat("Staged registry artifact genbank_ecoli_k12_gbff:", basename(paths[["gbff"]]), "\n")
