Sassy library and Ducksassy adapter timings
================

## Results

The [CPU profiles and scaling study](profile_search.md) identify allocation,
CIGAR formatting and host polling costs, and test balanced parallel workloads.

Sassy 0.2.6, AVX2, one thread pinned to CPU 19 on an Intel Core i5-13500.
Medians of seven runs after a warm-up. All inputs are resident before timing.

| Workload | Path     | Before (s) | After (s) |
|:---------|:---------|-----------:|----------:|
| ascii    | ffi      |      0.137 |     0.140 |
| ascii    | sql      |      0.168 |     0.165 |
| ascii    | upstream |      0.133 |     0.132 |
| dna      | ffi      |      0.766 |     0.769 |
| dna      | sql      |      0.918 |     0.820 |
| dna      | upstream |      0.711 |     0.714 |

Caching DuckDB output-buffer handles per chunk reduces the DNA SQL median
from 0.918 s to 0.820 s: **10.7% less elapsed time**. The dense ASCII workload
changes little (0.168 s to 0.165 s). On these workloads, SQL takes approximately
15% longer than direct upstream calls for DNA and 25% longer for dense ASCII.
Those ratios include result materialization and SQL aggregation.

The adapter keeps borrowed output pointers only within one scalar callback.
It grows storage geometrically, reacquires pointers and the string arena after
each resize, and sets the final vector lengths to the number of initialized
hits. A regression test checks long CIGARs across growth, NULL and empty lists,
multiple input chunks and repeated invocations.

## What each path measures

| Path       | Timed work                                                                                                                        |
|------------|-----------------------------------------------------------------------------------------------------------------------------------|
| `upstream` | Direct Sassy Rust calls, CIGAR formatting and hit summaries                                                                       |
| `ffi`      | Rust C ABI backend calls, validation, result buffers, CIGAR formatting and the same summaries                                     |
| `sql`      | DuckDB scan of resident inputs, C dispatcher and Rust backend, output vectors, SQL aggregation and persistent CLI/R JSON exchange |

The two native paths use the same executable, Sassy dependency and compiler
flags. `ffi` calls the Rust backend function table directly; it excludes the C
runtime dispatcher. Timed summaries consume every hit’s cost and CIGAR length.
SQL adds database execution and communication, so its difference from `ffi`
cannot be attributed entirely to the C adapter. Native timings use Rust
`Instant`; SQL timings use R elapsed time around the persistent CLI call.

Input construction, TSV parsing, process startup, full-hit export and result
validation are outside the timers. This complements the
[upstream CLI comparison](sequence_search.md), which includes file I/O and startup.

## Workloads and correctness

| workload | records |    bytes |   hits | full_hit_multisets_equal |
|:---------|--------:|---------:|-------:|:-------------------------|
| dna      |  262144 | 67108864 | 262676 | TRUE                     |
| ascii    |    4096 |  1048576 | 524288 | TRUE                     |

- **DNA:** 262,144 windows of 256 bases from *E. coli* NC_000913.3. Each pattern
  is the 23 bases at offset 64 within its window; search allows two edits and
  both strands. This is the relational workload in the sequence benchmark.
- **ASCII:** 4,096 rows containing 128 repetitions of `ab`, searched for `ab`
  with zero edits and no reverse complement. Its 524,288 hits exercise dense
  output materialization.

Before timing SQL, the driver compares the complete hit multiset with both
native paths: input row, pattern index, text and pattern coordinates, cost,
strand and CIGAR. Each timed run also checks hit count, cost sum and CIGAR bytes.

## Reproduce

Run from the repository root after `make setup setup-data release`:

``` sh
env CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_RUSTFLAGS='-C relocation-model=pic -C target-feature=+avx2,+popcnt' \
  cargo --config build/rust-vendor.toml build --manifest-path rust/Cargo.toml \
  --frozen --release --target x86_64-unknown-linux-gnu --no-default-features \
  --features backend-avx2 --example adapter_bench -j 2
R_LIBS=.deps/Rlib Rscript benchmarks/adapter_overhead.R local
```

The driver currently requires an AVX2 x86-64 host and CPU 19 in its allowed CPU
set. Set `DUCKHTS_CACHE_DIR` if the registered input cache is elsewhere.

Raw [before](data/adapter_overhead/before/timings.csv) and
[after](data/adapter_overhead/after/timings.csv) timings are retained.
The [before receipt](data/adapter_overhead/before/receipt.json) and
[after receipt](data/adapter_overhead/after/receipt.json) record source and
artifact hashes, host identity, backend and machine information. The before
adapter is from commit `6b38cbf6c441eba46fd100a76a84508a47735215`; the after
adapter is identified by its source hash because measurement preceded commit.
