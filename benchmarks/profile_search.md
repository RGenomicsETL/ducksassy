Ducksassy CPU profiles and parallel scaling
================

## Scope

Profiled commit **92d49294692d3f64709927d89706cfa9c752c3c3**, after pushing it
to `main`. The extension and search implementation were unchanged during this
investigation. Sassy 0.2.6, AVX2, Intel Core i5-13500. The thread counts use
one, two, four or eight distinct efficiency cores, avoiding mixed core types
and shared SMT siblings.

The inputs are resident DuckDB tables. Timings include SQL execution, hit
aggregation and persistent CLI/R exchange. Each query returns one summary row.
R/DBI bulk result conversion and FASTA decompression are outside this experiment.

The [buffer reuse measurements](buffer_reuse.md) evaluate result reuse and
successful-call bookkeeping following this profile.

## Parallelism: enough balanced scan tasks matter

| table    | threads | seconds | speedup |
|:---------|--------:|--------:|--------:|
| balanced |       1 |   3.040 |   1.000 |
| balanced |       2 |   1.525 |   1.993 |
| balanced |       4 |   0.769 |   3.953 |
| balanced |       8 |   0.385 |   7.896 |
| large    |       1 |   6.483 |   1.000 |
| large    |       2 |   3.375 |   1.921 |
| large    |       4 |   1.887 |   3.436 |
| large    |       8 |   1.129 |   5.742 |
| small    |       1 |   0.809 |   1.000 |
| small    |       2 |   0.429 |   1.886 |
| small    |       4 |   0.382 |   2.118 |
| small    |       8 |   0.382 |   2.118 |

- **small:** 262,144 records in three row groups, including a short final group.
- **large:** 2,097,152 records in 18 row groups, made by repeating the small
  workload eight times.
- **balanced:** 983,040 records in eight full groups of 122,880 rows. The driver
  checks these sizes with `pragma_storage_info()` before timing.

The small workload has too few scan tasks to use four or eight workers well.
The balanced control gives each worker a full group. DuckDB already runs the
scalar callback concurrently with a separate Sassy searcher per worker.
The measured balanced speedup is **7.9×
on eight cores**.
Parallelism is across records; a single record/panel call searches its patterns
sequentially in the Rust adapter.

## CPU samples

Linux `perf` recorded user-space CPU stacks only during repeated warm queries.
Setup, input loading and the warm-up were excluded using a control FIFO. The
DNA profiles use the large table; ASCII uses 65,536 rows of 256 bytes, producing
8,388,608 hits per query. Samples were collected separately from the timing runs.

| Sample category                   | DNA, 1 thread (%) | DNA, 8 threads (%) | ASCII, 1 thread (%) |
|:----------------------------------|------------------:|-------------------:|--------------------:|
| Sassy search, traceback, encoding |             74.51 |              71.98 |               25.58 |
| Allocation / free                 |             10.08 |               9.01 |               26.39 |
| Alphabet validation               |              2.08 |               1.69 |                0.13 |
| Other                             |             10.87 |              12.15 |               21.97 |
| Copy / zero                       |              1.23 |               1.24 |               17.65 |
| CIGAR formatting                  |              0.95 |               0.97 |                7.73 |
| Dispatcher pthread_once           |              0.08 |               0.04 |                0.01 |
| Mutex lock / unlock               |              0.01 |               2.96 |                0.01 |

These are sums of **self** samples for named symbols, so nested call stacks
are not counted twice. Sassy’s search category includes traceback and profile
encoding, including inlined operations. The allocator category covers named
malloc/free/realloc routines; it is not an attribution of all allocation cost
to the adapter. Percentages are rounded and tiny R-driver activity is excluded
from the symbol table. The saved profiles contain about 13,000 DNA samples per
run and 8,000 ASCII samples, with no lost samples reported by perf.

### Mutex costs

The eight-thread profile spends about **3% of sampled CPU time** in mutex
lock/unlock routines. The [caller stacks](data/profile_search_92d4929/eight-locks.txt)
place almost all of this under DuckDB’s CLI result consumer:

``` text
QueryResultStream::Fetch
  BufferedData::ReplenishBuffer
    BufferedData::Participate
      BufferSaturated / UnblockSinks / Executor task polling
        pthread_mutex_lock / pthread_mutex_unlock
```

This points to the host’s result polling and task scheduling. The extension’s
`pthread_once` dispatcher accounts for about 0.04–0.08% of DNA samples. Searcher
state is local to each worker. CPU sampling measures running time; it does not
by itself measure blocked lock-wait duration. The timing CSV also records total
process CPU time and voluntary/involuntary context switches.

### Conversion and allocation costs

Input sequence bytes are already borrowed from DuckDB vectors. The output path is:

``` text
Sassy Match/CIGAR values
  → temporary CIGAR String
  → Rust hit vector and CIGAR byte buffer
  → DuckDB struct child vectors and string storage
```

Dense ASCII spends roughly **26%** in allocator routines and **8%** in CIGAR
formatting. Copying/zeroing contributes another **18%**. Of that, about 13.6%
is `memset`; its [caller stack](data/profile_search_92d4929/ascii-memset.txt)
places it inside Sassy’s search path. Removing the adapter’s temporary strings
will address only part of these costs.

Code inspection also finds an avoidable allocation in the Rust FFI:
[`guard()`](../rust/src/lib.rs#L129)
replaces the thread-local error value with a newly allocated empty `CString`
on every fallible call, including search and result-view calls. Its contribution
is mixed into allocator samples and is not separately measured here.

## Count and contains still do substantial work

| operation | threads | seconds |
|:----------|--------:|--------:|
| contains  |       1 |   6.192 |
| count     |       1 |   6.235 |
| hits      |       1 |   6.483 |
| contains  |       2 |   3.250 |
| count     |       2 |   3.269 |
| hits      |       2 |   3.375 |
| contains  |       4 |   1.806 |
| count     |       4 |   1.812 |
| hits      |       4 |   1.887 |
| contains  |       8 |   1.085 |
| count     |       8 |   1.090 |
| hits      |       8 |   1.129 |

`count` and `contains` skip CIGAR string formatting, but the adapter still
requests upstream matches, builds hit structs and then counts them or tests
whether the result is empty. The timings show why dedicated result paths are
worth investigating. Any early exit or traceback avoidance must preserve the
existing endpoint and filtering semantics.

## Work suggested by the profile

1.  Serialize CIGARs directly into reusable result storage, avoiding the
    temporary `String` and its copy. Preserve the complete upstream hit comparison.
2.  Remove success-path error-string allocations; reuse result capacities per
    worker where the ownership contract permits it.
3.  Give count/contains dedicated output paths, then evaluate an upstream early
    exit for contains with equivalence tests.
4.  Keep record parallelism in DuckDB and benchmark sufficient, balanced scan
    tasks. Investigate the CLI’s polling loop separately with its host maintainers
    or compare a materialized-result client path.

## Reproduce and inspect

From the repository root after `make setup setup-data release`:

``` sh
R_LIBS=.deps/Rlib Rscript benchmarks/profile_search.R scaling /tmp/sassy-scaling
R_LIBS=.deps/Rlib Rscript benchmarks/profile_balanced.R /tmp/sassy-balanced

mkdir -p /tmp/sassy-perf
mkfifo /tmp/sassy-perf/control
perf record -o /tmp/sassy-perf/one.data -F 499 -e cpu-clock:u \
  --call-graph dwarf,16384 -D -1 --control=fifo:/tmp/sassy-perf/control -- \
  env DUCKSASSY_PERF_CONTROL=/tmp/sassy-perf/control R_LIBS=.deps/Rlib \
  Rscript benchmarks/profile_search.R worker /tmp/sassy-perf/one 1 4 hits
perf report -i /tmp/sassy-perf/one.data --stdio --no-children --comms duckdb \
  --sort dso,symbol --percent-limit 0 --call-graph none --show-nr-samples -t ';'
```

Set `DUCKHTS_CACHE_DIR` if the registered reference cache is elsewhere. Perf
requires permission to collect CPU events. For the eight-thread profile use
`8 8 hits`, 249 Hz and an 8192-byte stack; for ASCII use `1 6 ascii`, 499 Hz
and a 16384-byte stack. Give each run its own FIFO and output paths.

[Scaling timings](data/profile_search_92d4929/scaling.csv),
[balanced timings](data/profile_search_92d4929/balanced.csv),
[symbol samples](data/profile_search_92d4929/symbols.csv), and
[provenance](data/profile_search_92d4929/provenance.json) are retained. Raw perf
recordings remain in `/tmp/ducksassy-profiling/` on the profiling machine.
