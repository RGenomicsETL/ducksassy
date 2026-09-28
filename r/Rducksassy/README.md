
<!-- README.md is generated from README.Rmd. -->

# Rducksassy

Approximate text and sequence search inside DuckDB, with DuckHTS readers for
FASTA, FASTQ and BAM. Matches remain ordinary SQL rows: join them to annotations,
filter them and summarize them in the same query.

## Install

``` r
install.packages(c("Rducksassy", "Rduckhts"), repos = c(
  "https://rgenomicsetl.r-universe.dev",
  "https://duckdb.r-universe.dev",
  "https://cloud.r-project.org"
))
```

Loading the extension requires a **DuckDB host with C API v2 support**.
The connection helpers also require the suggested `Rduckhts` package for its
installed extension files; they do not load its R namespace.
The package builds against bundled headers and does not link to a particular
R DuckDB driver. `rducksassy_load(con)` accepts an existing compatible DBI
connection; `rducksassy_connect()` uses `duckdb::duckdb` by default and also
accepts a driver constructor.

The examples below use `duckdb.2.0.dev`, an optional host available from
DuckDB’s R-universe. The tested `duckdb` 1.5.5 host supports only C API v1
and cannot load this extension.

``` r
install.packages("duckdb.2.0.dev", repos = "https://duckdb.r-universe.dev")
```

Source installation builds the extension from bundled sources with Rust \>= 1.91,
Cargo, CMake \>= 3.20, Python 3 and a C11 compiler. Rust dependency resolution is
locked and offline. Linux is tested; macOS uses the native build path. Windows
and webR packaging are not implemented. CRAN readiness still depends on a
released host supporting C API v2.

## Fuzzy grep in SQL

Find `timeout` with one edit allowed. The inserted `d` in `timedout` is reported
in the CIGAR; coordinates are zero-based, half-open byte offsets.

``` r
con <- Rducksassy::rducksassy_connect(driver = duckdb.2.0.dev::duckdb)
DBI::dbGetQuery(con, "
  SELECT text_start, text_end, cost, cigar
  FROM sassy_grep('timeout', 'request timedout', 1)
")
#>   text_start text_end cost  cigar
#> 1          8       16    1 4=1D3=
```

Search a text column and group the matching rows without exporting them to a
separate grep process:

``` r
DBI::dbGetQuery(con, "
  WITH logs(service, message) AS (
    VALUES ('api', 'request timedout'),
           ('api', 'connection timeout'),
           ('worker', 'job completed')
  )
  SELECT service, count(*) AS matching_messages
  FROM logs
  WHERE sassy_contains('timeout', message, 1, alphabet := 'ascii', rc := false)
  GROUP BY service
  ORDER BY service
")
#>   service matching_messages
#> 1     api                 2
```

## Search BAM read sequences

The included synthetic BAM contains a forward read, a reverse read and a
secondary alignment. This query excludes secondary and supplementary alignments
and searches the stored read sequence on both strands:

``` r
bam <- system.file("extdata", "crispr_reads.bam", package = "Rducksassy",
                   mustWork = TRUE)
sql <- paste0(
  "SELECT r.QNAME, r.RNAME, r.POS, r.FLAG, ",
  "hit.text_start, hit.text_end, hit.strand, hit.cigar FROM read_bam(",
  DBI::dbQuoteString(con, bam), ") AS r CROSS JOIN LATERAL ",
  "UNNEST(sassy_crispr_matches('ACGTNGG', r.SEQ, 0)) AS matches(hit) ",
  "WHERE (r.FLAG & 2304) = 0 ORDER BY r.QNAME"
)
DBI::dbGetQuery(con, sql)
#>     QNAME     RNAME POS FLAG text_start text_end strand cigar
#> 1 forward reference   1    0          0        7      +    7=
#> 2 reverse reference  20   16          0        7      -    7=
```

`SEQ` is the text sequence column from `read_bam()`. `hit.text_start` and
`hit.text_end` describe a zero-based half-open interval in that stored sequence.
`hit.strand` is relative to it. Mapping hits back to reference coordinates requires
the BAM flag and alignment CIGAR, including clipping and indels. This example finds
guide-like sequences in reads; it does not estimate genomic off-target risk.

The SQL filter uses flag mask 2304 (`0x100 | 0x800`). Read identifiers and alignment
columns remain available for grouping by sample, read group or locus. A guide panel
can use `sassy_crispr_matches_many()` in the same query.

``` r
DBI::dbDisconnect(con, shutdown = TRUE)
```

## Citation and credits

Search uses Sassy by Rick Beeloo and Ragnar Groot Koerkamp:
[Sassy: fuzzy Searching DNA Sequences using SIMD](https://doi.org/10.1093/bioinformatics/btag244)
(*Bioinformatics*, 2026). Sassy and DuckDB copyright holders are credited in
`DESCRIPTION`; bundled dependency authors and licenses are listed in
`inst/LICENCE.note` and the vendored sources.

## Develop

From the repository root, `make vendor-rust` refreshes the shared bundle from
`rust/Cargo.lock`; `make r-package` stages the canonical C/Rust sources and builds
the R source tarball. The staged source tree under `src/extension` is generated;
edit the repository sources and stage again. Retain the lockfile during cleanup.

Install the package, then run `make r-readme` to regenerate this page. Its search
examples execute against the installed package, including the bundled BAM.
