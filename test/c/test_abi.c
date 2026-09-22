/* Assertions must execute even in a Release build: they include the FFI calls. */
#ifdef NDEBUG
#undef NDEBUG
#endif
#include "sassy_c.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>
_Static_assert(sizeof(sassy_c_hit) == 64, "hit ABI layout");
_Static_assert(sizeof(sassy_c_options) == 16, "options ABI layout");
_Static_assert(sizeof(sassy_c_crispr_options) == 20, "CRISPR options ABI layout");
_Static_assert(offsetof(sassy_c_crispr_options, max_n_frac) == 16, "N fraction ABI offset");
_Static_assert(offsetof(sassy_c_hit, cost) == 40, "cost ABI offset");
_Static_assert(offsetof(sassy_c_hit, cigar_offset) == 48, "CIGAR ABI offset");
static sassy_c_slice span(const char *s) {
    sassy_c_slice result = {(const uint8_t *)s, strlen(s)};
    return result;
}
int main(void) {
    assert(sassy_c_abi_version() == SASSY_C_ABI_VERSION);
    sassy_c_searcher *searcher = NULL;
    assert(sassy_c_searcher_new(SASSY_C_DNA, 0, &searcher) == SASSY_C_OK);
    sassy_c_options opts = {sizeof(opts), 0, 1, 0};
    sassy_c_result *result = NULL;
    assert(sassy_c_search(searcher, span("ACGA"), span("TTACGATT"), 0, &opts, &result) == 0);
    const sassy_c_hit *hits = NULL;
    const uint8_t *cigars = NULL;
    size_t n = 0, nc = 0;
    assert(sassy_c_result_view(result, &hits, &n, &cigars, &nc) == 0);
    assert(n == 1 && hits[0].text_start == 2 && hits[0].text_end == 6);
    assert(nc == 2 && memcmp(cigars, "4=", 2) == 0);
    sassy_c_result *second = NULL;
    assert(sassy_c_search(searcher, span("ACGA"), span("TTTTTTTT"), 0, &opts, &second) == 0);
    assert(hits[0].text_start == 2 && memcmp(cigars, "4=", 2) == 0);
    sassy_c_result_free(second);
    sassy_c_result_free(result);
    result = NULL;
    sassy_c_slice invalid = {NULL, 4};
    assert(sassy_c_search(searcher, invalid, span("ACGA"), 0, &opts, &result) == SASSY_C_INVALID);
    assert(result == NULL && strlen(sassy_c_last_error()) > 0);
    sassy_c_result_free(NULL);
    sassy_c_searcher_free(searcher);
    sassy_c_searcher_free(NULL);

    assert(sassy_c_searcher_new(SASSY_C_IUPAC, 1, &searcher) == SASSY_C_OK);
    sassy_c_crispr_options crispr = {.struct_size = sizeof(crispr),
                                     .pam_length = 3,
                                     .allow_pam_edits = 0,
                                     .include_cigar = 1,
                                     .max_n_frac = 0.2f};
    sassy_c_slice guides[] = {span("ACGTNGG")};
    result = NULL;
    assert(sassy_c_crispr_search_many(searcher, guides, 1, span("TTCCTACGTAA"), 0, &crispr,
                                      &result) == SASSY_C_OK);
    assert(sassy_c_result_view(result, &hits, &n, &cigars, &nc) == SASSY_C_OK);
    assert(n == 1 && hits[0].strand == 1 && hits[0].text_start == 2 && hits[0].text_end == 9);
    assert(nc == 2 && memcmp(cigars, "7=", 2) == 0);
    sassy_c_result_free(result);
    result = NULL;
    crispr.pam_length = 8;
    assert(sassy_c_crispr_search_many(searcher, guides, 1, span("ACGTAGG"), 0, &crispr, &result) ==
           SASSY_C_INVALID);
    assert(result == NULL);
    crispr.pam_length = 3;
    assert(sassy_c_crispr_search_many(searcher, guides, 1, span("ACGTAGG"), 0, &crispr, &result) ==
           SASSY_C_OK);
    sassy_c_result_free(result);
    sassy_c_searcher_free(searcher);
    puts("C ABI tests passed");
    return 0;
}
