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
/* SCALAR follows Sassy's baseline-build feature, including SSE2 on x86-64. */
typedef enum {
    SASSY_C_BACKEND_SCALAR,
    SASSY_C_BACKEND_AVX2,
    SASSY_C_BACKEND_AVX512,
    SASSY_C_BACKEND_NEON,
    SASSY_C_BACKEND_COUNT
} sassy_c_backend;
typedef struct {
    const uint8_t *data;
    size_t len;
} sassy_c_slice;
typedef struct {
    uint32_t struct_size, all_endpoints, include_cigar, reserved;
} sassy_c_options;
typedef struct {
    uint32_t struct_size;
    uint32_t pam_length;
    uint32_t allow_pam_edits;
    uint32_t include_cigar;
    float max_n_frac;
} sassy_c_crispr_options;
typedef struct {
    uint64_t pattern_idx, text_start, text_end, pattern_start, pattern_end;
    int32_t cost;
    uint32_t strand;
    uint64_t cigar_offset, cigar_length;
} sassy_c_hit;
typedef struct {
    uint32_t struct_size;
    sassy_c_backend backend;
    uint32_t compiled;
    uint32_t supported;
    uint32_t selected;
} sassy_c_backend_status;

/* ABI 1: sizeof(options)=16, sizeof(hit)=64. Initialize reserved=0 and
 * struct_size=sizeof(sassy_c_options). Flags are 0/1, not ABI-dependent enums.
 * DNA/IUPAC inputs accept either case; ASCII uses literal bytes <128 (NUL allowed).
 * Empty texts/panels produce an empty result. Empty/NULL panel elements error.
 * Patterns contain 1..4096 bytes, panels <=4096 patterns, k < every pattern length.
 * All text coordinates are zero-based, half-open in the original text.
 * strand 0=forward, 1=RC; RC CIGAR is in pattern direction, NOT SAM direction.
 * A result owns one hit array and one CIGAR byte slab. Strings are not terminated.
 * No matched-sequence copies. Inputs are borrowed only during synchronous calls.
 * Searchers must never be used concurrently. Separate searchers may run in parallel.
 * A SASSY_C_PANIC poisons that searcher; free and recreate it before another search.
 * Every failure leaves a non-NULL out result slot set to NULL; no partial results.
 * NULL free is allowed. Free owned results/searchers exactly once via this library,
 * never via the caller's malloc/free. Results remain valid across subsequent searches.
 * Caller must supply aligned, valid allocations covering every nonzero pointer/length.
 * Like ordinary C APIs, this library cannot validate dangling or undersized allocations.
 */
uint32_t sassy_c_abi_version(void);
const char *sassy_c_last_error(void); /* thread-local; next fallible call invalidates */
const char *sassy_c_backend_name(sassy_c_backend backend); /* NULL for an unknown value. */
/* Set SASSY_C_BACKEND=auto|scalar|avx2|avx512|neon before the first search call.
 * Selection (including an unavailable/unknown selection error) is fixed for the
 * loaded library. Each result and searcher uses that same backend throughout
 * its lifetime. Set out->struct_size=sizeof(*out); status queries do not select. */
int32_t sassy_c_backend_status_get(sassy_c_backend backend, sassy_c_backend_status *out);
int32_t sassy_c_searcher_new(uint32_t alphabet, uint32_t rc, sassy_c_searcher **out);
void sassy_c_searcher_free(sassy_c_searcher *searcher);
int32_t sassy_c_search(sassy_c_searcher *searcher, sassy_c_slice pattern, sassy_c_slice text,
                       uint32_t k, const sassy_c_options *options, sassy_c_result **out);
int32_t sassy_c_search_many(sassy_c_searcher *searcher, const sassy_c_slice *patterns,
                            size_t n_patterns, sassy_c_slice text, uint32_t k,
                            const sassy_c_options *options, sassy_c_result **out);
/* CRISPR uses an IUPAC searcher and Sassy 0.2.6 CLI endpoint-filter semantics.
 * Guides include a trailing PAM of pam_length >= 1; a panel shares identical
 * PAM suffix bytes. All qualifying endpoints are searched, with unit edit costs
 * over the complete guide including PAM. allow_pam_edits=0 applies the exact
 * IUPAC PAM endpoint filter, not a separate constrained-alignment scoring model.
 * N/n content is filtered over the full target match, including PAM, with a
 * float32 fraction in [0,1]. sizeof(crispr_options)=20; struct_size and flags
 * follow the rules above. */
int32_t sassy_c_crispr_search_many(sassy_c_searcher *searcher, const sassy_c_slice *guides,
                                   size_t n_guides, sassy_c_slice text, uint32_t k,
                                   const sassy_c_crispr_options *options, sassy_c_result **out);
int32_t sassy_c_result_view(const sassy_c_result *result, const sassy_c_hit **hits, size_t *count,
                            const uint8_t **cigars, size_t *cigar_bytes);
void sassy_c_result_free(sassy_c_result *result);

#ifdef __cplusplus
}
#endif
#endif
