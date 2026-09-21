/* Assertions must execute even in a Release build: they include the FFI calls. */
#ifdef NDEBUG
#undef NDEBUG
#endif
#include "sassy_c.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>
_Static_assert(sizeof(sassy_c_hit) == 64, "hit ABI layout");
_Static_assert(sizeof(sassy_c_options) == 32, "options ABI layout");
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
    sassy_c_options opts = {sizeof(opts), 0, 1, 0, 1000, 1048576};
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
    puts("C ABI tests passed");
    return 0;
}
