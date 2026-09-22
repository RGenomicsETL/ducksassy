Result buffer reuse and successful-call allocations
================

## Measurements

Sassy 0.2.6, AVX2, one thread pinned to CPU 19 on an Intel Core i5-13500.
Medians of seven runs after a warm-up, with inputs resident before timing.
The [adapter benchmark](adapter_overhead.md#what-each-path-measures) describes
the timing boundaries and workloads: 262,144 DNA records and 4,096 dense ASCII
records. The baseline includes cached DuckDB vector handles.

| Workload | Path     | Before (s) | After (s) | Elapsed time reduction (%) |
|:---------|:---------|-----------:|----------:|---------------------------:|
| ascii    | ffi      |      0.137 |     0.134 |                        2.3 |
| ascii    | sql      |      0.165 |     0.164 |                        0.6 |
| ascii    | upstream |      0.132 |     0.132 |                        0.0 |
| dna      | ffi      |      0.755 |     0.751 |                        0.5 |
| dna      | sql      |      0.811 |     0.773 |                        4.7 |
| dna      | upstream |      0.711 |     0.706 |                        0.7 |

DNA SQL elapsed time falls from 0.811 s to 0.773 s (4.7%). The direct upstream
median also falls by 0.7%; these sequential runs include run-to-run variation.
The native FFI DNA change is small, and the dense ASCII SQL change is 1 ms.
These measurements support a modest SQL improvement on the DNA workload;
they do not establish a general speedup across inputs or separate the effects
of buffer reuse from successful-call bookkeeping.

SQL takes about 9.5% longer than direct upstream calls for DNA and 24.1% longer
for dense ASCII in the after measurements. SQL includes database execution,
result materialization, aggregation and persistent CLI/R communication. The
FFI path excludes the C runtime dispatcher. Both native paths use the same
executable, dependency and compiler flags.

## Allocation and ownership

Each searcher can retain one consumed result, including its hit and CIGAR buffer
capacity. SQL returns each consumed result to its searcher; the native FFI
benchmark uses the same `sassy_c_result_recycle()` operation. Searcher destruction
releases that retained storage. Actual errors still allocate their diagnostic
strings; successful calls use a static empty error string.

Tests count allocations on the calling thread and verify zero allocations for:

- 100 successful error guards and error-string reads, including clearing an error;
- 100 empty search/view/recycle cycles after warm-up.

These checks cover adapter overhead. Searches with hits still allocate in
upstream Sassy and during per-hit CIGAR formatting. Packed CIGAR output remains
the subject of [issue \#6](https://github.com/RGenomicsETL/ducksassy/issues/6).

Lifecycle tests check that recycling clears lengths and retains capacity,
outstanding results survive other searches, and owned results remain valid after
their searcher is destroyed. A recycled result and its borrowed views must no
longer be used.

## Equivalence

| workload | records |    bytes |   hits | full_hit_multisets_equal |
|:---------|--------:|---------:|-------:|:-------------------------|
| dna      |  262144 | 67108864 | 262676 | TRUE                     |
| ascii    |    4096 |  1048576 | 524288 | TRUE                     |

Both native paths and SQL return identical full hit multisets, including
coordinates, cost, strand and CIGAR. Timed runs also check count, cost sum and
CIGAR bytes. The separate upstream CRISPR CLI oracle passes all 36 option
profiles, covering 864 guide/record comparisons.

## Reproduce

Build the AVX2 benchmark executable using the command in the
[adapter benchmark](adapter_overhead.md#reproduce), then run from the repository root:

``` sh
DUCKHTS_CACHE_DIR=/tmp/ducksassy-benchmark-cache R_LIBS=.deps/Rlib \
  Rscript benchmarks/adapter_overhead.R local
R_LIBS=.deps/Rlib Rscript tools/render_readme.R benchmarks/buffer_reuse.Rmd
```

Choose the cache directory for your installation. Raw
[before timings](data/adapter_overhead/buffer_reuse_before/timings.csv),
[after timings](data/adapter_overhead/buffer_reuse_after/timings.csv) and their
[before receipt](data/adapter_overhead/buffer_reuse_before/receipt.json) and
[after receipt](data/adapter_overhead/buffer_reuse_after/receipt.json) retain
artifact hashes, inputs and machine details. The baseline is commit
`ff0c363487d24eb13eb06d1cd3001d0cc49631d6`; the optimized build was measured
before commit and is identified by the artifact and source hashes in its receipt.
