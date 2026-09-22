# Rducksassy

Approximate text and sequence search inside DuckDB, with DuckHTS readers for
FASTA, FASTQ and BAM. Query results remain ordinary tables for joins and summaries.

```r
install.packages("Rducksassy", repos = c(
  "https://rgenomicsetl.r-universe.dev",
  "https://duckdb.r-universe.dev",
  "https://cloud.r-project.org"
))

con <- Rducksassy::rducksassy_connect()
DBI::dbGetQuery(con, "
  SELECT * FROM sassy_grep('timeout', 'request timedout', 1)
")
DBI::dbDisconnect(con, shutdown = TRUE)
```

This development package uses `duckdb.2.0.dev`, the DuckDB v2 preview host.
Source installation builds the extension from bundled sources with Rust >= 1.91,
Cargo, CMake >= 3.20, Python 3 and a C11 compiler. Rust dependency resolution is
locked and offline. Linux is tested; macOS uses the native build path. Windows
and webR packaging are not implemented. The preview host dependency currently
prevents a CRAN release.

## Search BAM read sequences

The included synthetic BAM contains a forward read, a reverse read and a
secondary alignment. This query excludes secondary and supplementary alignments
and searches the stored read sequence on both strands:

```r
con <- Rducksassy::rducksassy_connect()
bam <- system.file("extdata", "crispr_reads.bam", package = "Rducksassy")
sql <- paste0(
  "SELECT r.QNAME, r.RNAME, r.POS, r.FLAG, hit.* FROM read_bam(",
  DBI::dbQuoteString(con, bam), ") AS r CROSS JOIN LATERAL ",
  "UNNEST(sassy_crispr_matches('ACGTNGG', r.SEQ, 0)) AS matches(hit) ",
  "WHERE (r.FLAG & 2304) = 0 ORDER BY r.QNAME"
)
DBI::dbGetQuery(con, sql)
DBI::dbDisconnect(con, shutdown = TRUE)
```

`SEQ` is the text sequence column from `read_bam()`. `hit.text_start` and
`hit.text_end` describe a zero-based half-open interval in that stored sequence.
`hit.strand` is relative to it. Mapping hits back to reference coordinates requires
the BAM flag and alignment CIGAR, including clipping and indels. This example finds
guide-like sequences in reads; it does not estimate genomic off-target risk.

The SQL filter uses flag mask 2304 (`0x100 | 0x800`). Read identifiers and alignment
columns remain available for grouping by sample, read group or locus. A guide panel
can use `sassy_crispr_matches_many()` in the same query.

## Develop

From the repository root, `make vendor-rust` refreshes the shared bundle from
`rust/Cargo.lock`; `make r-package` stages the canonical C/Rust sources and builds
the R source tarball. The staged source tree under `src/extension` is generated;
edit the repository sources and stage again. Retain the lockfile during cleanup.
