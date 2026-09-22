Ducksassy sequence-search benchmarks
================

## Results

Sassy **0.2.6**, Ducksassy
**87653fda17a28498414b621bb1bd7a8aaea75ba4**, Intel Core i5-13500.
Medians of seven measured queries after one warm-up; lower times are better.

| workload   | threads | scalar_seconds | avx2_seconds | scalar_over_avx2 |
|:-----------|--------:|---------------:|-------------:|-----------------:|
| crispr     |       1 |          0.155 |        0.099 |            1.566 |
| crispr     |       4 |          0.156 |        0.095 |            1.642 |
| fasta      |       1 |          0.097 |        0.090 |            1.078 |
| fasta      |       4 |          0.097 |        0.089 |            1.090 |
| relational |       1 |          0.967 |        0.908 |            1.065 |
| relational |       4 |          0.463 |        0.431 |            1.074 |

The `scalar` backend includes SSE2 on x86-64.
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
that is distinct from the output-hit denominator.

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
filtered out. The upstream CLI is a correctness oracle here, not a timed
performance baseline. It starts a process and writes TSV; the timed DuckDB
queries use persistent sessions and aggregate all hits. No cross-tool speed
ratio is claimed.

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

- [Raw timings](data/sequence_search_0.2.6/timings.csv)
- [Backend observations](data/sequence_search_0.2.6/backends.csv)
- [Validation counts](data/sequence_search_0.2.6/oracle.csv)
- [Artifact, input, compiler and runtime receipt](data/sequence_search_0.2.6/receipt.json)
- [Query templates](data/sequence_search_0.2.6/queries.sql)
- [Driver](sequence_search.R)

Extension SHA-256: 7ae010f8547e09630d8c361b41df5d0e9e4610597def93fe3671b0a627394214.

FASTA SHA-256: a0ca3984234be9bd174e1f4691f062cc2a1a7dc24fb5c76b7d2f523f79f0c27c;
4699686 bytes.
