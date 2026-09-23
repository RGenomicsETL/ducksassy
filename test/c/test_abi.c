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
_Static_assert(sizeof(sassy_c_op_span) == 16, "operation span ABI layout");
_Static_assert(sizeof(sassy_c_crispr_options) == 20, "CRISPR options ABI layout");
_Static_assert(offsetof(sassy_c_crispr_options, max_n_frac) == 16, "N fraction ABI offset");
_Static_assert(offsetof(sassy_c_hit, cost) == 40, "cost ABI offset");
_Static_assert(offsetof(sassy_c_hit, cigar_offset) == 48, "CIGAR ABI offset");
static sassy_c_slice span(const char *s) {
    sassy_c_slice result = {(const uint8_t *)s, strlen(s)};
    return result;
}
static void check_packed(sassy_c_searcher *searcher, const char *text,
                         uint8_t strand, const char *cigar, const uint32_t *expected, size_t length) {
    sassy_c_options opts = {sizeof(opts), 0, 1, SASSY_C_PACKED_CIGAR};
    sassy_c_result *result = NULL;
    assert(sassy_c_search(searcher, span("ACGTTGCA"), span(text), 1, &opts, &result) == SASSY_C_OK);
    const sassy_c_hit *hits = NULL;
    const uint8_t *cigars = NULL;
    const sassy_c_op_span *spans = NULL;
    const uint32_t *ops = NULL;
    size_t n = 0, bytes = 0, count = 0;
    assert(sassy_c_result_view(result, &hits, &n, &cigars, &bytes) == SASSY_C_OK);
    assert(sassy_c_result_ops_view(result, &spans, &ops, &count) == SASSY_C_OK);
    size_t index = 0;
    while (index < n && (hits[index].strand != strand || hits[index].text_start != 2)) ++index;
    assert(index < n && hits[index].pattern_start == 0 && hits[index].text_end > 2);
    assert(hits[index].cigar_length == strlen(cigar));
    assert(memcmp(cigars + hits[index].cigar_offset, cigar, strlen(cigar)) == 0);
    assert(spans[index].length == length && spans[index].offset + length <= count);
    size_t query = 0, reference = 0;
    for (size_t i = 0; i < length; ++i) {
        uint32_t op = ops[spans[index].offset + i];
        assert(op == expected[i]);
        uint32_t code = op & 15, run = op >> 4;
        if (code == 7 || code == 8 || code == 1) query += run;
        if (code == 7 || code == 8 || code == 2) reference += run;
    }
    assert(query == hits[index].pattern_end - hits[index].pattern_start);
    assert(reference == hits[index].text_end - hits[index].text_start);
    sassy_c_result_recycle(searcher, result);
    result = NULL;
    opts.include_cigar = 0;
    assert(sassy_c_search(searcher, span("ACGTTGCA"), span(text), 1, &opts, &result) == SASSY_C_OK);
    assert(sassy_c_result_view(result, &hits, &n, &cigars, &bytes) == SASSY_C_OK);
    assert(bytes == 0 && cigars == NULL);
    assert(sassy_c_result_ops_view(result, &spans, &ops, &count) == SASSY_C_OK);
    assert(spans != NULL && ops != NULL);
    sassy_c_result_free(result);
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
    const sassy_c_op_span *empty_spans = NULL;
    const uint32_t *empty_ops = NULL;
    size_t empty_count = 1;
    assert(sassy_c_result_ops_view(result, &empty_spans, &empty_ops, &empty_count) == SASSY_C_OK);
    assert(empty_spans == NULL && empty_ops == NULL && empty_count == 0);
    sassy_c_result *second = NULL;
    assert(sassy_c_search(searcher, span("ACGA"), span("TTTTTTTT"), 0, &opts, &second) == 0);
    assert(hits[0].text_start == 2 && memcmp(cigars, "4=", 2) == 0);
    sassy_c_result_recycle(searcher, second);
    assert(sassy_c_search(searcher, span("ACGA"), span("ACGA"), 0, &opts, &second) == 0);
    assert(hits[0].text_start == 2 && memcmp(cigars, "4=", 2) == 0);
    sassy_c_result_recycle(searcher, second);
    sassy_c_result_free(result);
    result = NULL;
    opts.reserved = 2;
    assert(sassy_c_search(searcher, span("ACGA"), span("ACGA"), 0, &opts, &result) == SASSY_C_INVALID);
    assert(result == NULL);
    opts.reserved = 0;
    sassy_c_slice invalid = {NULL, 4};
    assert(sassy_c_search(searcher, invalid, span("ACGA"), 0, &opts, &result) == SASSY_C_INVALID);
    assert(result == NULL && strlen(sassy_c_last_error()) > 0);
    assert(sassy_c_search(searcher, span("ACGA"), span("ACGA"), 0, &opts, &result) == 0);
    assert(strlen(sassy_c_last_error()) == 0);
    sassy_c_result_recycle(searcher, NULL);
    sassy_c_result_free(NULL);
    sassy_c_searcher_free(searcher);
    assert(sassy_c_result_view(result, &hits, &n, &cigars, &nc) == 0);
    assert(n == 1 && hits[0].text_start == 0 && nc == 2);
    sassy_c_result_free(result);
    sassy_c_searcher_free(NULL);

    assert(sassy_c_searcher_new(SASSY_C_DNA, 0, &searcher) == SASSY_C_OK);
    const uint32_t exact[] = {(8U << 4) | 7U};
    const uint32_t fwd_del[] = {(3U << 4) | 7U, (1U << 4) | 2U, (5U << 4) | 7U};
    const uint32_t fwd_ins[] = {(3U << 4) | 7U, (1U << 4) | 1U, (4U << 4) | 7U};
    check_packed(searcher, "GGACGTTGCACC", 0, "8=", exact, 1);
    check_packed(searcher, "GGACGTTTGCACC", 0, "3=1D5=", fwd_del, 3);
    check_packed(searcher, "GGACGTGCACC", 0, "3=1I4=", fwd_ins, 3);
    sassy_c_searcher_free(searcher);
    assert(sassy_c_searcher_new(SASSY_C_DNA, 1, &searcher) == SASSY_C_OK);
    const uint32_t rc_del[] = {(5U << 4) | 7U, (1U << 4) | 2U, (3U << 4) | 7U};
    const uint32_t rc_ins[] = {(4U << 4) | 7U, (1U << 4) | 1U, (3U << 4) | 7U};
    check_packed(searcher, "GGTGCAACGTCC", 1, "8=", exact, 1);
    check_packed(searcher, "GGTGCAAACGTCC", 1, "3=1D5=", rc_del, 3);
    check_packed(searcher, "GGTGCACGTCC", 1, "3=1I4=", rc_ins, 3);
    sassy_c_searcher_free(searcher);

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
    sassy_c_result_recycle(searcher, result);
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
