
<!-- README.md is generated from README.Rmd. -->

# Rducksassy

Approximate text and sequence search inside DuckDB. Matches remain ordinary SQL
values and rows that can be joined to annotations, filtered and summarized in
the same query.

## Install

``` r
install.packages("Rducksassy")
```

Source installation builds the bundled Ducksassy extension with Rust and Cargo
\>= 1.91, CMake \>= 3.20, Python \>= 3.8 and a C11 compiler. Rust dependency
resolution is locked and offline. The package uses the stable DuckDB C extension
API provided by `duckdb` \>= 1.5.5.

`rducksassy_connect()` creates an isolated DuckDB handle and loads the packaged
extension. `rducksassy_load(con)` loads it into an existing compatible DuckDB
DBI connection.

## Fuzzy grep in SQL

Find `timeout` with one edit allowed. The inserted `d` in `timedout` is reported
in the CIGAR; coordinates are zero-based, half-open byte offsets.

``` r
con <- Rducksassy::rducksassy_connect()
DBI::dbGetQuery(con, "
  SELECT text_start, text_end, cost, cigar
  FROM sassy_grep('timeout', 'request timedout', 1)
")
#>   text_start text_end cost  cigar
#> 1          8       16    1 4=1D3=
```

Search a text column and group matching rows without exporting them to a
separate grep process. Stable C API scalar arguments are positional, with
trailing defaults.

``` r
DBI::dbGetQuery(con, "
  WITH logs(service, message) AS (
    VALUES ('api', 'request timedout'),
           ('api', 'connection timeout'),
           ('worker', 'job completed')
  )
  SELECT service, count(*) AS matching_messages
  FROM logs
  WHERE sassy_contains('timeout', message, 1, 'ascii', false)
  GROUP BY service
  ORDER BY service
")
#>   service matching_messages
#> 1     api                 2
```

## Search CRISPR guides

Search guide and PAM together on both strands, then expand each result struct
into rows.

``` r
DBI::dbGetQuery(con, "
  SELECT target, hit.*
  FROM (VALUES
    ('exact', 'TTACGTAGGTT'),
    ('one_edit', 'TTACCTAGGTT')
  ) AS targets(target, sequence)
  CROSS JOIN LATERAL unnest(
    sassy_crispr_matches('ACGTNGG', sequence, 1)
  ) AS matches(hit)
  ORDER BY target, hit.text_start
")
#>     target pattern_idx text_start text_end pattern_start pattern_end cost
#> 1    exact           0          2        9             0           7    0
#> 2 one_edit           0          2        9             0           7    1
#> 3 one_edit           0          3       10             0           7    1
#>   strand  cigar
#> 1      +     7=
#> 2      + 2=1X4=
#> 3      - 2=1X4=
```

DuckHTS can supply FASTA, FASTQ and BAM rows directly. Install its signed
community extension once, load it into the connection, and pass its sequence
columns to the scalar functions.

``` r
DBI::dbExecute(con, "INSTALL duckhts FROM community")
DBI::dbExecute(con, "LOAD duckhts")
DBI::dbGetQuery(con, "
  SELECT record.name, hit.*
  FROM read_fasta('reference.fa') AS record
  CROSS JOIN LATERAL UNNEST(
    sassy_matches('ACGT', record.sequence, 1)
  ) AS matches(hit)
")
```

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
`rust/Cargo.lock`; `make r-package` stages the canonical C/Rust sources and
builds the R source tarball. The staged source tree under `src/extension` is
generated; edit the repository sources and stage again. Retain the lockfile
during cleanup.

Install the package, then run `make r-readme` to regenerate this page. Its search
examples execute against the installed package.
