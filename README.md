
<!-- README.md is generated from README.Rmd with duckknit. -->

# ducksassy

Approximate string matching inside DuckDB.

[DuckHTS](https://github.com/RGenomicsETL/duckhts) exposes FASTA and FASTQ records
as DuckDB relations. [Sassy](https://github.com/RagnarGrootKoerkamp/sassy) supplies
the approximate matching kernel. ducksassy connects them: file searches return
matches with edit cost, coordinates, strand and CIGAR alongside the input
record’s columns. Scalar functions search sequence values from any relation.
They also search ordinary ASCII text columns, so fuzzy grep can be a SQL query.

This follows DuckHTS’s [composability model](https://github.com/RGenomicsETL/duckhts/blob/develop/ARCHITECTURE.md):
the file reader and native matcher handle their respective mechanics; DuckDB
handles the join, filtering and aggregation. For example, give each guide its
own PAM length and search a FASTA relation:

``` sql
WITH guides(guide_id, guide, pam_length) AS (
    VALUES ('g1', 'ACGTNGG', 3), ('g2', 'ACGTAGG', 2)
)
SELECT r.name AS reference_name, g.guide_id,
       hit.text_start, hit.text_end, hit.strand
FROM guides AS g
CROSS JOIN read_fasta('test/data/references.fasta', scan_mode := 'sequential') AS r
CROSS JOIN LATERAL unnest(sassy_crispr_matches(g.guide, r.sequence, 0,
    pam_length := g.pam_length)) AS matches(hit)
ORDER BY reference_name, guide_id, hit.text_start, hit.text_end, hit.strand;
```

| reference_name | guide_id | text_start | text_end | strand |
|----------------|----------|-----------:|---------:|--------|
| forward        | g1       |          2 |        9 | \+     |
| forward        | g2       |          2 |        9 | \+     |
| masked         | g1       |          2 |        9 | \+     |
| masked         | g2       |          2 |        9 | \+     |
| reverse        | g1       |          2 |        9 | \-     |
| reverse        | g2       |          2 |        9 | \-     |

`pam_length` comes from each guide row. The lateral join expands its matches;
the output can be joined to other annotations or grouped by guide without
another file format. Use `LEFT JOIN LATERAL ... ON true` to retain rows with no
hit.

## What it does

- Search with up to `k` substitutions, insertions or deletions. IUPAC ambiguity
  codes work in patterns and targets; reverse-complement search is on by default.
- Search one pattern, a panel, or a guide with a PAM. CRISPR search applies
  Sassy’s exact PAM endpoint filter and excludes targets above the configured
  N fraction. The CRISPR semantics below spell out the filter.
- Search files through DuckHTS, or call the scalar functions on any sequence
  column. Results stay in DuckDB for joins, counts and downstream queries.

The [library and adapter comparison](benchmarks/adapter_overhead.md) measures
direct upstream Sassy calls, the Rust C ABI and SQL over identical resident
inputs, checking the complete hit multisets.
The [buffer reuse measurements](benchmarks/buffer_reuse.md) report the current
SQL overhead and the effect of reusing native result storage.

The [measured workloads](benchmarks/sequence_search.md) include eight 23-base
guides against a 4.6 Mb *E. coli* reference and 262,144 sequence rows. The timed
comparison includes Ducksassy’s `scalar` and AVX2 backends and an upstream
Sassy CLI baseline for the same CRISPR workload. The report records startup,
threading, output work and cache conditions: persistent SQL aggregates hits,
while the upstream CLI starts a process and writes TSV.
The 4.6 Mb input is one bacterial record; these results do not establish
whole-human-genome throughput or peak memory use.

## Quick start

ducksassy targets the DuckDB C API v2 preview (DuckDB 1.x cannot load it).
`make setup` fetches the matching CLI and checks the bundled SDK. On Linux x86-64 you need C/C++
compilers, CMake ≥ 3.20, Python ≥ 3.11, Git, R ≥ 4.1 and rustup.

``` sh
make setup JOBS=4
make release
.deps/duckdb-build/duckdb -unsigned -no-init
```

Then, in the DuckDB CLI:

``` sql
SET GLOBAL lambda_syntax='ENABLE_SINGLE_ARROW';
INSTALL '.deps/duckhts.duckdb_extension';
INSTALL 'build/ducksassy.duckdb_extension';
.read sql/ducksassy.sql
```

The lambda setting is required by DuckHTS 1.5.2 and applies to the whole
database instance, so use a dedicated one. The macros are connection-scoped.
Supported host versions are pinned in
[ducksassy-package.json](ducksassy-package.json). When upgrading, move an
outdated `.deps/sassy-source` checkout aside before rerunning `make setup`.

### R package

[`Rducksassy`](r/Rducksassy/README.md) builds the extension from bundled sources
and provides `rducksassy_connect()` and `rducksassy_load()`. It requires
a DuckDB host with C API v2 support and the extension bundled by `Rduckhts`.
Its examples include searching BAM read sequences while retaining alignment
identifiers for SQL joins and summaries.

``` r
install.packages("Rducksassy", repos = c(
  "https://rgenomicsetl.r-universe.dev",
  "https://duckdb.r-universe.dev",
  "https://cloud.r-project.org"
))
# One available C API v2 host; other compatible drivers can be supplied.
install.packages("duckdb.2.0.dev", repos = "https://duckdb.r-universe.dev")
con <- Rducksassy::rducksassy_connect(driver = duckdb.2.0.dev::duckdb)
DBI::dbGetQuery(con, "SELECT * FROM sassy_grep('timeout', 'request timedout', 1)")
DBI::dbDisconnect(con, shutdown = TRUE)
```

`make vendor-rust` refreshes the shared Rust source archive using the committed
lockfile. Native and R package builds use it offline. `make r-package` stages
the R package’s sources and builds its source tarball.

## Examples

Every example below runs against the bundled
[test fixtures](test/data/README.md) and is rendered live from this README.

### Fuzzy grep over text rows

Search a text column with one allowed edit. ASCII mode requires `rc := false`;
matches return byte offsets within each value.

``` sql
WITH lines(line_id, message) AS (
    VALUES (1, 'error: disk full'),
           (2, 'errot: disk full'),
           (3, 'ready')
)
SELECT line_id, message, hit.text_start, hit.text_end, hit.cost
FROM lines
CROSS JOIN LATERAL unnest(sassy_matches('error', message, 1,
    alphabet := 'ascii', rc := false)) AS matches(hit)
ORDER BY line_id, hit.text_start;
```

| line_id | message          | text_start | text_end | cost |
|--------:|------------------|-----------:|---------:|-----:|
|       1 | error: disk full |          0 |        5 |    0 |
|       2 | errot: disk full |          0 |        5 |    1 |

The input can also be a CSV, Parquet file or any other DuckDB relation with a
text column. ASCII matching is case-insensitive; it is not Unicode text search.

For one long ASCII value, `sassy_grep` returns rows from a stateful scan. It
searches overlapping 1 KiB regions and gives each match endpoint to one region.
DuckDB can stop requesting regions once an outer `LIMIT` is satisfied:

``` sql
SELECT text_start, text_end, cost, cigar
FROM sassy_grep('error', 'error: ' || repeat('ready ', 100000), 1)
LIMIT 1;
```

This table function accepts constant expressions, as DuckDB requires for table
function arguments. It returns **all qualifying endpoints**, including nearby
alternative alignments; `sassy_matches` defaults to rightmost local minima.
The scalar function above still accepts a different text value on every row.
DuckDB constructs the constant text argument before the scan starts, so
`LIMIT` saves search work but does not avoid holding that argument in memory.

### Search a FASTA reference

Find a pattern in each FASTA record, with coordinates, strand and CIGAR:

``` sql
SELECT name AS reference_name, hit.text_start, hit.text_end, hit.strand, hit.cigar
FROM sassy_search_fasta('test/data/references.fasta', 'ACGTAGG', 0,
                       alphabet := 'iupac', rc := false)
ORDER BY name, hit.text_start, hit.text_end;
```

| reference_name | text_start | text_end | strand | cigar |
|----------------|-----------:|---------:|--------|-------|
| ambiguous      |          2 |        9 | \+     | 7=    |
| forward        |          2 |        9 | \+     | 7=    |
| masked         |          2 |        9 | \+     | 7=    |

With `alphabet := 'iupac'`, ambiguous bases in the reference (including N) match
any base they could stand for. `sassy_panel_search_fasta()` takes a list of
patterns instead. Both stream the file sequentially and need no index.

### Search for CRISPR sites

Allow one edit over the full guide and apply the exact PAM endpoint filter.
This synthetic sequence illustrates the API; it is not an experimental guide.

``` sql
SELECT name AS reference_name, hit.text_start, hit.text_end, hit.cost, hit.strand, hit.cigar
FROM sassy_crispr_search_fasta('test/data/references.fasta', 'ACGTNGG', 1)
ORDER BY name, hit.text_start, hit.text_end, hit.strand;
```

| reference_name | text_start | text_end | cost | strand | cigar  |
|----------------|-----------:|---------:|-----:|--------|--------|
| deletion       |          2 |        8 |    1 | \+     | 1=1I5= |
| forward        |          2 |        9 |    0 | \+     | 7=     |
| insertion      |          2 |       10 |    1 | \+     | 2=1D5= |
| masked         |          2 |        9 |    0 | \+     | 7=     |
| reverse        |          2 |        9 |    0 | \-     | 7=     |

Use `sassy_crispr_panel_search_fasta()` for a guide panel, or
`sassy_crispr_matches()` / `sassy_crispr_matches_many()` on sequence values, as in
the join at the top.

### Search FASTQ reads

``` sql
SELECT name AS read_name, hit.text_start, hit.text_end, hit.cost, hit.strand, hit.cigar
FROM sassy_search_fastq('test/data/reads.fastq', 'ACGA', 0, rc := false)
ORDER BY name, hit.text_start, hit.text_end;
```

| read_name | text_start | text_end | cost | strand | cigar |
|-----------|-----------:|---------:|-----:|--------|-------|
| r1        |          2 |        6 |    0 | \+     | 4=    |
| r3        |          0 |        4 |    0 | \+     | 4=    |

Count hits for a whole panel at once. Hits carry the zero-based `pattern_idx`,
so duplicate patterns remain distinct:

``` sql
SELECT hit.pattern_idx, count(*) AS observations
FROM sassy_panel_search_fastq('test/data/reads.fastq', ['ACGA', 'TTGC'], 0, rc := false)
GROUP BY hit.pattern_idx
ORDER BY hit.pattern_idx;
```

| pattern_idx | observations |
|------------:|-------------:|
|           0 |            2 |

### Search a table or view

Anything with a `sequence` column works, including views:

``` sql
CREATE TEMP VIEW reads AS
SELECT * FROM read_fastq('test/data/reads.fastq', scan_mode := 'sequential');
```

``` sql
SELECT name AS read_name, hit.text_start, hit.text_end, hit.cigar
FROM sassy_search_table('reads', 'ACGA', 0, rc := false)
ORDER BY name, hit.text_start, hit.text_end;
```

| read_name | text_start | text_end | cigar |
|-----------|-----------:|---------:|-------|
| r1        |          2 |        6 | 4=    |
| r3        |          0 |        4 | 4=    |

For other column names or computed sequences, use the scalar functions directly:

``` sql
SELECT r.name AS read_name, hit.text_start, hit.text_end, hit.cigar
FROM reads AS r
CROSS JOIN LATERAL unnest(sassy_matches('ACGA', r.sequence, 0,
    rc := false)) AS matches(hit)
ORDER BY read_name, hit.text_start, hit.text_end;
```

| read_name | text_start | text_end | cigar |
|-----------|-----------:|---------:|-------|
| r1        |          2 |        6 | 4=    |
| r3        |          0 |        4 | 4=    |

### Search sequence values

``` sql
SELECT sassy_contains('ACGA', 'TTACGATT', 0, rc := false) AS contains;
```

| contains |
|----------|
| true     |

``` sql
SELECT unnest(sassy_matches('ACGA', 'TTACGATT', 0, rc := false), recursive := true);
```

| pattern_idx | text_start | text_end | pattern_start | pattern_end | cost | strand | cigar |
|------------:|-----------:|---------:|--------------:|------------:|-----:|--------|-------|
|           0 |          2 |        6 |             0 |           4 |    0 | \+     | 4=    |

## Function cheat sheet

| Input          | One pattern                                      | A panel of patterns                                             |
|----------------|--------------------------------------------------|-----------------------------------------------------------------|
| FASTA file     | `sassy_search_fasta`                             | `sassy_panel_search_fasta`                                      |
| FASTQ file     | `sassy_search_fastq`                             | `sassy_panel_search_fastq`                                      |
| Table / view   | `sassy_search_table`                             | —                                                               |
| Values         | `sassy_matches`, `sassy_count`, `sassy_contains` | `sassy_matches_many`, `sassy_count_many`, `sassy_contains_many` |
| CRISPR, FASTA  | `sassy_crispr_search_fasta`                      | `sassy_crispr_panel_search_fasta`                               |
| CRISPR, table  | `sassy_crispr_search_table`                      | `sassy_crispr_panel_search_table`                               |
| CRISPR, values | `sassy_crispr_matches`                           | `sassy_crispr_matches_many`                                     |

Value functions accept `VARCHAR` or `BLOB` (panels: `VARCHAR[]` or `BLOB[]`);
pattern and text must use the same type. BLOBs hold plain sequence bytes, so
decode DuckHTS nt16/nt4 packed symbols first. `sassy_count` and `sassy_contains`
skip building CIGAR strings.

### Packed CIGAR

Use `sassy_matches_packed` (or `sassy_matches_many_packed`) for typed
`cigar_ops UINTEGER[]`; these leave `cigar` NULL. Use `sassy_matches_both`
(or `sassy_matches_many_both`) to receive the existing text CIGAR and packed
ops together. The arguments and defaults match `sassy_matches`. Packed-only
materialization skips string formatting but allocates a typed list for each hit;
no before/after timing has been measured.

``` sql
SELECT hit.text_start, hit.cigar_ops
FROM UNNEST(sassy_matches_packed('ACGTTGCA', 'GGTGCAAACGTCC', 1,
    alphabet := 'dna')) AS matches(hit)
WHERE hit.strand = '-';
```

When a DuckHTS build provides `cigar_aligned_blocks(cigar, pos)`, the typed
result can be passed directly (this snippet is not an executed example):

``` sql
SELECT cigar_aligned_blocks(hit.cigar_ops, hit.text_start)
FROM UNNEST(sassy_matches_packed('ACGTTGCA', 'GGTGCAAACGTCC', 1,
    alphabet := 'dna')) AS matches(hit)
WHERE hit.strand = '-';
```

## The fine print

<details>
<summary>
<b>Matching semantics</b>: coordinates, strands, alphabets, defaults
</summary>

Matching uses Sassy 0.2.6. Coordinates are **zero-based, half-open**
in the input text. `+` and `-` identify the pattern’s strand; reverse-strand
CIGAR follows the pattern direction, not SAM direction. Packed `cigar_ops`
follow SAM’s forward-reference order: query = pattern, reference = text,
POS = `text_start` (zero-based). A reverse hit reverses the structured Sassy
operation list, retaining I (pattern-only) and D (text-only). The codes are
BAM’s `I=1`, `D=2`, `S=4`, `=7`, `X=8`; Sassy emits explicit `=`/`X`, not `M`.
Unaligned query ends are soft-clipped, with clips swapped on reverse hits;
`pattern_start`/`pattern_end` describe the aligned segment in the original
pattern. Excluding soft clips, the packed query span is
`pattern_end - pattern_start`; its reference span is `text_end - text_start`.
Each run is limited to the BAM 28-bit length field; larger runs fail with a
limit error. Text CIGAR retains Sassy’s pattern-oriented notation without
clips, including on reverse hits.

General searches default to `alphabet := 'iupac'`, `rc := true` and
`all_endpoints := false` (Sassy’s rightmost local minima). Set
`all_endpoints := true` to report every qualifying endpoint; this still does not
enumerate every alignment. For literal ASCII searches, use
`alphabet := 'ascii', rc := false`.

DNA accepts A/C/G/T; IUPAC also accepts R/Y/S/W/K/M/B/D/H/V/N. Both match
case-insensitively. FASTA wrappers default to DNA and preserve the reader’s
sequence representation: DuckHTS 1.5.2 uppercases FASTA sequences and may return
NULL descriptions.

Patterns contain 1–4096 bytes, panels at most 4096 patterns, and `k` must be
smaller than every pattern length. NULL arguments produce NULL; empty text or an
empty panel produces no hits. Empty patterns and NULL panel entries are errors.
Use `ORDER BY` when result order matters. Reference-region offsets must be added
by the caller using the sequence’s coordinate map.

</details>
<details>
<summary>
<b>CRISPR semantics</b>: what a guide hit means
</summary>

- IUPAC matching on both strands, with `pam_length := 3` by default.
- Unit edit distance `k` over the full guide, including PAM. Insertions and
  deletions count as edits and appear in the CIGAR.
- `allow_pam_edits := false`: Sassy’s exact IUPAC PAM endpoint filter, not a
  separately constrained PAM alignment or Cas-specific score.
- `max_n_frac := 0.2`: N/n content over the whole target match, including PAM,
  compared using Sassy’s float32 rule.
- All qualifying endpoints are reported. Guides in one panel must share
  identical PAM suffix bytes; separate guide rows can use different PAMs and PAM
  lengths.

Strand identifies a guide occurrence, not an assigned biological binding strand.
Independent DNA/RNA-bulge limits and positional penalties are not provided.

</details>
<details>
<summary>
<b>Large inputs and SQL LIMIT</b>: current execution model
</summary>

DuckHTS streams *records*, but Sassy receives each whole sequence or text value
and can allocate RAM for search state and matches. DuckDB’s `memory_limit` does
not fully count that RAM or move it to disk. A long input is still one large
search, and parallel searches can use more RAM at once. Input length and hit
count have no user-set caps; peak memory is unbounded.

An outer SQL `LIMIT` limits rows returned by a query. The scalar functions first
compute all matches for one text value as a LIST, then DuckDB expands that LIST
into rows. `LIMIT` may avoid work on later input rows, but it cannot stop the
native search or bound its memory within one value. `sassy_grep` is a separate
ASCII table scan that searches one bounded region at a time; its output batches
can stop after `LIMIT`. Table function arguments are constant expressions, so
it cannot take a column from `read_fasta` or a general relation.

The scalar adapter borrows DuckDB’s input string bytes for each synchronous
search call. DuckHTS’s `read_fasta` currently copies each parsed sequence into a
DuckDB VARCHAR vector before this adapter sees it. Avoiding that materialization
would require a reader/search scan that passes a record buffer directly to the
matcher while keeping it alive through the search.

Each worker’s searcher reuses one result allocation, retaining hit and CIGAR
buffer capacity between calls until the searcher is destroyed. Successful calls
do not allocate an error string. C callers can return consumed results with
`sassy_c_result_recycle()` or release them with `sassy_c_result_free()`.

The DuckDB adapter caps LIST output at 1,048,576 hits across a
chunk and raises an error if it cannot materialize them. `sassy_count` and
`sassy_contains` avoid LIST output and CIGAR strings, but currently still run the
full native match. Splitting a long reference into regions can reduce memory per
search, but the caller must restore reference coordinates and reconcile hits in
overlapping regions. `sassy_grep` does this for its ASCII all-endpoints scan.

</details>
<details>
<summary>
<b>SIMD backends</b>: inspecting and forcing a kernel
</summary>

The native library selects the best available backend automatically:

``` sql
SELECT * FROM sassy_backend_info() ORDER BY name;
```

| name    | compiled | supported | selected |
|---------|----------|-----------|----------|
| avx2    | true     | true      | true     |
| avx512  | true     | false     | false    |
| neon    | false    | false     | false    |
| scalar  | true     | true      | false    |
| wasm128 | false    | false     | false    |

Set `SASSY_C_BACKEND` to `auto`, `scalar`, `avx2`, `avx512`, `neon` or `wasm128`
before the first search to force one. The choice is fixed for the loaded
library; an unavailable request returns an error, and changing it requires a
fresh process.
`scalar` follows Sassy’s baseline and includes SSE2 on x86-64; SSE4.1 has no
separate tier. Linux x86-64 baseline and AVX2 are tested; AVX-512 is compiled
but unexecuted, and aarch64/NEON is unverified. Emscripten builds select
`wasm128` at compile time. CI typechecks the Rust wasm target; a linked
DuckDB-Wasm extension has not been validated.

</details>
<details>
<summary>
<b>Using the C library directly</b>
</summary>

The build also produces `build/libsassy_c.a`.
[include/sassy_c.h](include/sassy_c.h) defines its ABI, ownership rules and
limits; [test/c/test_abi.c](test/c/test_abi.c) is a working example.

</details>

## Development

``` sh
make test sql-test oracle-test readme
```

`oracle-test` compares complete CRISPR hit multisets against the Sassy
0.2.6 CLI across 36 profiles and 864 guide/record pairs.
`make r-test` runs DBI integration against the R preview host pinned in
`ducksassy-package.json`, installed separately under `.deps/Rlib/`.
`make benchmarks` re-renders the [benchmark report](benchmarks/sequence_search.md).

## Credits

[Sassy](https://github.com/RagnarGrootKoerkamp/sassy) is by Rick Beeloo and
Ragnar Groot Koerkamp ([MIT](third_party/sassy/LICENSE)). File reading comes
from [DuckHTS](https://github.com/RGenomicsETL/duckhts).
