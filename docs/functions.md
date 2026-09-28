# Function reference

Generated from `functions.yaml` by `scripts/render_function_catalog.py`.

Scalar options are positional: the stable C extension API has no named scalar arguments, so `alphabet := 'dna'` does not bind. Pass options in the order shown and omit trailing ones to use their defaults, for example `sassy_matches('ACGT', text, 1, 'dna', false)`.

## Search

| Function | Kind | Description |
| --- | --- | --- |
| [`sassy_matches`](#sassy_matches) | scalar | Return every approximate match of one pattern in a text with at most k edits. `alphabet` is 'dna', 'iupac' or 'ascii'; `rc` also searches the reverse complement; `all_endpoints` reports every qualifying endpoint instead of Sassy's rightmost local minima; `cigar_format` is 'text', 'packed' or 'both'. |
| [`sassy_matches_many`](#sassy_matches_many) | scalar | Search a panel of up to 4096 patterns in one text. Each hit carries the zero-based `pattern_idx` of the panel entry that produced it, so duplicate patterns stay distinct. |
| [`sassy_count`](#sassy_count) | scalar | Count the matches `sassy_matches` would return, without building CIGAR strings. |
| [`sassy_count_many`](#sassy_count_many) | scalar | Count the matches of every pattern in a panel, without building CIGAR strings. |
| [`sassy_contains`](#sassy_contains) | scalar | Return whether the text contains at least one match of the pattern with at most k edits. |
| [`sassy_contains_many`](#sassy_contains_many) | scalar | Return whether any pattern in the panel matches the text with at most k edits. |
| [`sassy_grep`](#sassy_grep) | table | Stream the matches of an ASCII pattern in one long text value, scanning overlapping 1 KiB regions and returning all qualifying endpoints. An outer `LIMIT` stops the scan once enough rows are produced. |

## CRISPR

| Function | Kind | Description |
| --- | --- | --- |
| [`sassy_crispr_matches`](#sassy_crispr_matches) | scalar | Find guide occurrences with at most k edits over the whole guide, including its trailing PAM. Hits must end in an exact IUPAC PAM match unless `allow_pam_edits` is true, and targets whose N fraction exceeds `max_n_frac` are dropped. Both strands are searched by default. |
| [`sassy_crispr_matches_many`](#sassy_crispr_matches_many) | scalar | Search a guide panel sharing the same PAM suffix; each hit carries the guide's zero-based `pattern_idx`. Guides with different PAMs belong in separate rows or calls. |

## Diagnostics

| Function | Kind | Description |
| --- | --- | --- |
| [`sassy_backend_info`](#sassy_backend_info) | table | Report each SIMD backend (scalar, avx2, avx512, neon, wasm128): whether it is compiled into this build, supported by the running CPU, and selected. Selection happens on the first search. |

<a id="sassy_matches"></a>

### sassy_matches

Return every approximate match of one pattern in a text with at most k edits. `alphabet` is 'dna', 'iupac' or 'ascii'; `rc` also searches the reverse complement; `all_endpoints` reports every qualifying endpoint instead of Sassy's rightmost local minima; `cigar_format` is 'text', 'packed' or 'both'.

Signature:

```sql
sassy_matches(pattern, text, k[, alphabet[, rc[, all_endpoints[, cigar_format]]]])
-- Optional arguments are positional; defaults: alphabet = 'iupac', rc = true, all_endpoints = false, cigar_format = 'text'
```

Returns:

```
STRUCT(pattern_idx UBIGINT, text_start UBIGINT, text_end UBIGINT, pattern_start UBIGINT, pattern_end UBIGINT, cost INTEGER, strand VARCHAR, cigar VARCHAR, cigar_ops UINTEGER[])[]
```

Examples:

```sql
SELECT unnest(sassy_matches('ACGTAGG', 'TTACGTTGGAA', 1), recursive := true);
```

```sql
SELECT unnest(sassy_matches('error', 'errot: disk full', 1, 'ascii', false), recursive := true);
```

```sql
SELECT hit.text_start, hit.cigar, hit.cigar_ops
FROM (SELECT unnest(sassy_matches('ACGTAGG', 'TTACGTTGGAA', 1, 'dna', false, false, 'both')) AS hit);
```

<a id="sassy_matches_many"></a>

### sassy_matches_many

Search a panel of up to 4096 patterns in one text. Each hit carries the zero-based `pattern_idx` of the panel entry that produced it, so duplicate patterns stay distinct.

Signature:

```sql
sassy_matches_many(patterns, text, k[, alphabet[, rc[, all_endpoints[, cigar_format]]]])
-- Optional arguments are positional; defaults: alphabet = 'iupac', rc = true, all_endpoints = false, cigar_format = 'text'
```

Returns:

```
STRUCT(pattern_idx UBIGINT, text_start UBIGINT, text_end UBIGINT, pattern_start UBIGINT, pattern_end UBIGINT, cost INTEGER, strand VARCHAR, cigar VARCHAR, cigar_ops UINTEGER[])[]
```

Examples:

```sql
SELECT hit.pattern_idx, hit.text_start
FROM (SELECT unnest(sassy_matches_many(['ACGT', 'TTGC'], 'ACGTTTGCACGT', 0, 'dna', false)) AS hit);
```

<a id="sassy_count"></a>

### sassy_count

Count the matches `sassy_matches` would return, without building CIGAR strings.

Signature:

```sql
sassy_count(pattern, text, k[, alphabet[, rc[, all_endpoints]]])
-- Optional arguments are positional; defaults: alphabet = 'iupac', rc = true, all_endpoints = false
```

Returns:

```
UBIGINT
```

Examples:

```sql
SELECT sassy_count('ACGT', 'ACGTNNACGT', 0, 'iupac', false);
```

<a id="sassy_count_many"></a>

### sassy_count_many

Count the matches of every pattern in a panel, without building CIGAR strings.

Signature:

```sql
sassy_count_many(patterns, text, k[, alphabet[, rc[, all_endpoints]]])
-- Optional arguments are positional; defaults: alphabet = 'iupac', rc = true, all_endpoints = false
```

Returns:

```
UBIGINT
```

Examples:

```sql
SELECT sassy_count_many(['ACGT', 'TTGC'], 'ACGTTTGCACGT', 0, 'dna', false);
```

<a id="sassy_contains"></a>

### sassy_contains

Return whether the text contains at least one match of the pattern with at most k edits.

Signature:

```sql
sassy_contains(pattern, text, k[, alphabet[, rc[, all_endpoints]]])
-- Optional arguments are positional; defaults: alphabet = 'iupac', rc = true, all_endpoints = false
```

Returns:

```
BOOLEAN
```

Examples:

```sql
SELECT sassy_contains('ACGT', 'TTACGTT', 0), sassy_contains('ACGT', 'TTTT', 0);
```

<a id="sassy_contains_many"></a>

### sassy_contains_many

Return whether any pattern in the panel matches the text with at most k edits.

Signature:

```sql
sassy_contains_many(patterns, text, k[, alphabet[, rc[, all_endpoints]]])
-- Optional arguments are positional; defaults: alphabet = 'iupac', rc = true, all_endpoints = false
```

Returns:

```
BOOLEAN
```

Examples:

```sql
SELECT sassy_contains_many(['ACGT', 'GGGG'], 'TTACGT', 0, 'dna', false);
```

<a id="sassy_grep"></a>

### sassy_grep

Stream the matches of an ASCII pattern in one long text value, scanning overlapping 1 KiB regions and returning all qualifying endpoints. An outer `LIMIT` stops the scan once enough rows are produced.

Signature:

```sql
sassy_grep(pattern VARCHAR, text VARCHAR, k BIGINT)
```

Returns:

```
TABLE(text_start UBIGINT, text_end UBIGINT, cost INTEGER, cigar VARCHAR)
```

Examples:

```sql
SELECT * FROM sassy_grep('timeout', 'request timedout; retry timeout', 1);
```

```sql
SELECT text_start FROM sassy_grep('error', 'error: ' || repeat('ready ', 100000), 1) LIMIT 1;
```

<a id="sassy_crispr_matches"></a>

### sassy_crispr_matches

Find guide occurrences with at most k edits over the whole guide, including its trailing PAM. Hits must end in an exact IUPAC PAM match unless `allow_pam_edits` is true, and targets whose N fraction exceeds `max_n_frac` are dropped. Both strands are searched by default.

Signature:

```sql
sassy_crispr_matches(guide, text, k[, pam_length[, allow_pam_edits[, max_n_frac[, rc]]]])
-- Optional arguments are positional; defaults: pam_length = 3, allow_pam_edits = false, max_n_frac = 0.2, rc = true
```

Returns:

```
STRUCT(pattern_idx UBIGINT, text_start UBIGINT, text_end UBIGINT, pattern_start UBIGINT, pattern_end UBIGINT, cost INTEGER, strand VARCHAR, cigar VARCHAR)[]
```

Examples:

```sql
SELECT unnest(sassy_crispr_matches('ACGTNGG', 'TTACGTAGGTT', 1), recursive := true);
```

<a id="sassy_crispr_matches_many"></a>

### sassy_crispr_matches_many

Search a guide panel sharing the same PAM suffix; each hit carries the guide's zero-based `pattern_idx`. Guides with different PAMs belong in separate rows or calls.

Signature:

```sql
sassy_crispr_matches_many(guides, text, k[, pam_length[, allow_pam_edits[, max_n_frac[, rc]]]])
-- Optional arguments are positional; defaults: pam_length = 3, allow_pam_edits = false, max_n_frac = 0.2, rc = true
```

Returns:

```
STRUCT(pattern_idx UBIGINT, text_start UBIGINT, text_end UBIGINT, pattern_start UBIGINT, pattern_end UBIGINT, cost INTEGER, strand VARCHAR, cigar VARCHAR)[]
```

Examples:

```sql
SELECT hit.pattern_idx, hit.text_start, hit.strand
FROM (SELECT unnest(sassy_crispr_matches_many(['ACGTNGG', 'TTTTNGG'], 'TTACGTAGGTT', 0)) AS hit);
```

<a id="sassy_backend_info"></a>

### sassy_backend_info

Report each SIMD backend (scalar, avx2, avx512, neon, wasm128): whether it is compiled into this build, supported by the running CPU, and selected. Selection happens on the first search.

Signature:

```sql
sassy_backend_info()
```

Returns:

```
TABLE(name VARCHAR, compiled BOOLEAN, supported BOOLEAN, selected BOOLEAN)
```

Examples:

```sql
SELECT * FROM sassy_backend_info();
```
