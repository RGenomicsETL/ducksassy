#ifndef SASSY_C_H
#define SASSY_C_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

#define SASSY_C_ABI_VERSION 1U
#define SASSY_C_OK 0
#define SASSY_C_INVALID 1
#define SASSY_C_LIMIT 2
#define SASSY_C_PANIC 3
#define SASSY_C_ASCII 0U
#define SASSY_C_DNA 1U
#define SASSY_C_IUPAC 2U

typedef struct sassy_c_searcher sassy_c_searcher;
typedef struct sassy_c_result sassy_c_result;
typedef struct { const uint8_t *data; size_t len; } sassy_c_slice;
typedef struct {
    uint32_t struct_size, all_endpoints, include_cigar, reserved;
    uint64_t max_hits, max_text_bytes;
} sassy_c_options;
typedef struct {
    uint64_t pattern_idx, text_start, text_end, pattern_start, pattern_end;
    int32_t cost;
    uint32_t strand;
    uint64_t cigar_offset, cigar_length;
} sassy_c_hit;

/* ABI 1: sizeof(options)=32, sizeof(hit)=64. Initialize reserved=0 and
 * struct_size=sizeof(sassy_c_options). Flags are 0/1, not ABI-dependent enums.
 * DNA/IUPAC inputs are uppercase; ASCII uses literal bytes <128 (NUL allowed).
 * Empty texts/panels produce an empty result. Empty/NULL panel elements error.
 * Patterns contain 1..4096 bytes, panels <=4096 patterns, k < every pattern length.
 * All text coordinates are zero-based, half-open in the original text.
 * strand 0=forward, 1=RC; RC CIGAR is in pattern direction, NOT SAM direction.
 * A result owns one hit array and one CIGAR byte slab. Strings are not terminated.
 * No matched-sequence copies. Inputs are borrowed only during synchronous calls.
 * Searchers must never be used concurrently. Separate searchers may run in parallel.
 * A SASSY_C_PANIC poisons that searcher; free and recreate it before another search.
 * max_text_bytes is checked before searching; max_hits is an OUTPUT limit checked
 * after each upstream pattern search, not a bound on upstream scratch allocations.
 * Every failure leaves a non-NULL out result slot set to NULL; no partial results.
 * NULL free is allowed. Free owned results/searchers exactly once via this library,
 * never via the caller's malloc/free. Results remain valid across subsequent searches.
 * Caller must supply aligned, valid allocations covering every nonzero pointer/length.
 * Like ordinary C APIs, this library cannot validate dangling or undersized allocations.
 */
uint32_t sassy_c_abi_version(void);
const char *sassy_c_last_error(void); /* thread-local; next fallible call invalidates */
int32_t sassy_c_searcher_new(uint32_t alphabet, uint32_t rc, sassy_c_searcher **out);
void sassy_c_searcher_free(sassy_c_searcher *searcher);
int32_t sassy_c_search(sassy_c_searcher *searcher, sassy_c_slice pattern,
    sassy_c_slice text, uint32_t k, const sassy_c_options *options, sassy_c_result **out);
int32_t sassy_c_search_many(sassy_c_searcher *searcher, const sassy_c_slice *patterns,
    size_t n_patterns, sassy_c_slice text, uint32_t k,
    const sassy_c_options *options, sassy_c_result **out);
int32_t sassy_c_result_view(const sassy_c_result *result, const sassy_c_hit **hits,
    size_t *count, const uint8_t **cigars, size_t *cigar_bytes);
void sassy_c_result_free(sassy_c_result *result);

#ifdef __cplusplus
}
#endif
#endif
