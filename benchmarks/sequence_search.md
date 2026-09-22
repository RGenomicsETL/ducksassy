Ducksassy sequence-search benchmarks
================

## Results

Sassy **0.2.1**, Ducksassy
**43cb9d8497dcda58345eb78932c77d36635bed1a**, Intel Core i5-13500.
Medians of seven measured queries after one warm-up; lower times are better.

| workload   | threads | baseline_seconds | avx2_seconds | baseline_over_avx2 |
|:-----------|--------:|-----------------:|-------------:|-------------------:|
| crispr     |       1 |            0.156 |        0.097 |              1.608 |
| crispr     |       4 |            0.154 |        0.098 |              1.571 |
| fasta      |       1 |            0.096 |        0.091 |              1.055 |
| fasta      |       4 |            0.097 |        0.092 |              1.054 |
| relational |       1 |            0.969 |        0.933 |              1.039 |
| relational |       4 |            0.456 |        0.446 |              1.022 |

The baseline backend is named `scalar` by Sassy and includes SSE2 on x86-64.
These are SQL end-to-end measurements, not isolated kernel timings.

## Workloads

Input: RefSeq *E. coli* K-12 MG1655 **NC_000913.3**, **4,641,652 bases**,
assembly GCF_000005845.2_ASM584v2. Eight 23-base patterns are selected at evenly
distributed NGG sites. CRISPR guides replace the PAM’s first base with N.
These are computational workloads, not evaluated experimental guides.

- **FASTA:** read the complete FASTA and search eight DNA patterns with `k=2`,
  reverse complements and rightmost-local-minimum reporting.
- **CRISPR:** read the same FASTA and search eight IUPAC guides with `k=2`, a
  three-base exact PAM endpoint filter, reverse complements and `max_n_frac=0.2`.
- **Relational:** scan 262,144 materialized rows containing deterministic
  256-base reference windows. Each row has a 23-base guide copied from position
  64 of its window (zero-based); search with `k=2` and reverse complements.
  Overlapping/repeated source windows remain separate physical rows.

| workload   | input_records | patterns_per_record | input_bases | searched_pair_bases | output_hits | aggregate_rows |
|:-----------|--------------:|--------------------:|------------:|--------------------:|:------------|---------------:|
| fasta      |             1 |                   8 |     4641652 |            37133216 | 8           |              1 |
| crispr     |             1 |                   8 |     4641652 |            37133216 | 10          |              1 |
| relational |        262144 |                   1 |    67108864 |            67108864 | 262676      |              1 |

Every returned hit contributes to a count, edit-cost sum and fingerprint that
includes its input-row and pattern indices. Each query returns one aggregate row;
that is distinct from the output-hit denominator. Whole-reference searches set
`max_text_bytes=8388608`, exceeding the current 1 MiB default.

## Measurement conditions

Queries execute through persistent duckknit CLI sessions. Wall time includes SQL
parsing, planning, execution, full-hit aggregation, CLI/R communication and JSON
parsing. FASTA/CRISPR include file reading; relational input construction is
excluded. Session startup, extension loading, staging and validation are excluded.
Filesystem caches are warm. RSS and cold-start latency are not measured.

Each backend/thread combination starts a fresh process under `taskset`.
DuckDB is configured for one thread on CPU **19**, or four threads on CPUs
**16–19**. All observed OS threads’ affinity sets are verified; their count is
reported separately from DuckDB’s query-thread setting. A single-record FASTA
does not supply four independent search tasks.

| requested | threads | cpus  | observed_thread_count | all_thread_affinities_match | name   | compiled | supported | selected |
|:----------|--------:|:------|----------------------:|:----------------------------|:-------|:---------|:----------|:---------|
| scalar    |       1 | 19    |                    81 | TRUE                        | avx2   | TRUE     | TRUE      | FALSE    |
| scalar    |       1 | 19    |                    81 | TRUE                        | avx512 | TRUE     | FALSE     | FALSE    |
| scalar    |       1 | 19    |                    81 | TRUE                        | neon   | FALSE    | FALSE     | FALSE    |
| scalar    |       1 | 19    |                    81 | TRUE                        | scalar | TRUE     | TRUE      | TRUE     |
| scalar    |       4 | 16-19 |                    84 | TRUE                        | avx2   | TRUE     | TRUE      | FALSE    |
| scalar    |       4 | 16-19 |                    84 | TRUE                        | avx512 | TRUE     | FALSE     | FALSE    |
| scalar    |       4 | 16-19 |                    84 | TRUE                        | neon   | FALSE    | FALSE     | FALSE    |
| scalar    |       4 | 16-19 |                    84 | TRUE                        | scalar | TRUE     | TRUE      | TRUE     |
| avx2      |       1 | 19    |                    81 | TRUE                        | avx2   | TRUE     | TRUE      | TRUE     |
| avx2      |       1 | 19    |                    81 | TRUE                        | avx512 | TRUE     | FALSE     | FALSE    |
| avx2      |       1 | 19    |                    81 | TRUE                        | neon   | FALSE    | FALSE     | FALSE    |
| avx2      |       1 | 19    |                    81 | TRUE                        | scalar | TRUE     | TRUE      | FALSE    |
| avx2      |       4 | 16-19 |                    84 | TRUE                        | avx2   | TRUE     | TRUE      | TRUE     |
| avx2      |       4 | 16-19 |                    84 | TRUE                        | avx512 | TRUE     | FALSE     | FALSE    |
| avx2      |       4 | 16-19 |                    84 | TRUE                        | neon   | FALSE    | FALSE     | FALSE    |
| avx2      |       4 | 16-19 |                    84 | TRUE                        | scalar | TRUE     | TRUE      | FALSE    |

## Correctness checks

| backend | threads | guide_record_pairs | compared_hits | exact_multiset | constructed_exact_rows |
|:--------|--------:|-------------------:|--------------:|:---------------|-----------------------:|
| scalar  |       1 |                  8 |            10 | TRUE           |                 262144 |
| scalar  |       4 |                  8 |            10 | TRUE           |                 262144 |
| avx2    |       1 |                  8 |            10 | TRUE           |                 262144 |
| avx2    |       4 |                  8 |            10 | TRUE           |                 262144 |

CRISPR results match the separately built upstream CLI as complete multisets of
guide, record, cost, strand, start, end and CIGAR. Every constructed relational
row also contains the independently known exact hit `[64,87)`, `+`, `23=`;
that is checked at `k=0` before timing. The `k=2` fingerprints detect backend/thread
inconsistencies, not independent biological correctness. No disagreements are
filtered out.

## Input preparation and reproduction

The driver resolves `genbank_ecoli_k12_gbff` through `duckhtsbench`’s registry,
extracts its single ORIGIN sequence, verifies accession/alphabet/base count,
and writes a temporary 80-column FASTA. The intermediate is regenerated for
each render. Source acquisition stays with the existing registry.

``` sh
make setup JOBS=4
make setup-data
make benchmarks
```

Requires Linux `taskset`, CPUs 16–19 in the allowed affinity set, and AVX2/POPCNT.
The measured release is 0.2.1; Sassy 0.2.6 is not measured by this report.

- [Raw timings](data/sequence_search_0.2.1/timings.csv)
- [Backend observations](data/sequence_search_0.2.1/backends.csv)
- [Validation counts](data/sequence_search_0.2.1/oracle.csv)
- [Artifact, input, compiler and runtime receipt](data/sequence_search_0.2.1/receipt.json)
- [Query templates](data/sequence_search_0.2.1/queries.sql)
- [Driver](sequence_search.R)

Extension SHA-256: 9d9f294f4298859ffafc655cce1a9446953455dac7aa1faef73049afca537d3f.

FASTA SHA-256: a0ca3984234be9bd174e1f4691f062cc2a1a7dc24fb5c76b7d2f523f79f0c27c;
4699686 bytes.
