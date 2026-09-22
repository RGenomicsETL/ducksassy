#ifndef SASSY_BACKEND_H
#define SASSY_BACKEND_H

#include "sassy_c.h"

#define SASSY_C_BACKEND_TABLE_VERSION 1U

#ifndef SASSY_C_HAVE_SCALAR
#define SASSY_C_HAVE_SCALAR 1
#endif
#ifndef SASSY_C_HAVE_AVX2
#define SASSY_C_HAVE_AVX2 0
#endif
#ifndef SASSY_C_HAVE_AVX512
#define SASSY_C_HAVE_AVX512 0
#endif
#ifndef SASSY_C_HAVE_NEON
#define SASSY_C_HAVE_NEON 0
#endif
#ifndef SASSY_C_HAVE_WASM128
#define SASSY_C_HAVE_WASM128 0
#endif

typedef struct {
    uint32_t version;
    uint32_t struct_size;
    const char *(*last_error)(void);
    int32_t (*searcher_new)(uint32_t alphabet, uint32_t reverse_complement, sassy_c_searcher **out);
    void (*searcher_free)(sassy_c_searcher *searcher);
    int32_t (*search)(sassy_c_searcher *searcher, sassy_c_slice pattern, sassy_c_slice text,
                      uint32_t k, const sassy_c_options *options, sassy_c_result **out);
    int32_t (*search_many)(sassy_c_searcher *searcher, const sassy_c_slice *patterns,
                           size_t n_patterns, sassy_c_slice text, uint32_t k,
                           const sassy_c_options *options, sassy_c_result **out);
    int32_t (*crispr_search_many)(sassy_c_searcher *searcher, const sassy_c_slice *guides,
                                  size_t guide_count, sassy_c_slice text, uint32_t k,
                                  const sassy_c_crispr_options *options, sassy_c_result **out);
    int32_t (*result_view)(const sassy_c_result *result, const sassy_c_hit **hits, size_t *count,
                           const uint8_t **cigars, size_t *cigar_bytes);
    void (*result_free)(sassy_c_result *result);
    void (*result_recycle)(sassy_c_searcher *searcher, sassy_c_result *result);
} sassy_c_backend_table;

typedef const sassy_c_backend_table *(*sassy_c_backend_getter)(void);

#if SASSY_C_HAVE_SCALAR
const sassy_c_backend_table *sassy_c_backend_scalar_get_table(void);
#endif
#if SASSY_C_HAVE_AVX2
const sassy_c_backend_table *sassy_c_backend_avx2_get_table(void);
#endif
#if SASSY_C_HAVE_AVX512
const sassy_c_backend_table *sassy_c_backend_avx512_get_table(void);
#endif
#if SASSY_C_HAVE_NEON
const sassy_c_backend_table *sassy_c_backend_neon_get_table(void);
#endif
#if SASSY_C_HAVE_WASM128
const sassy_c_backend_table *sassy_c_backend_wasm128_get_table(void);
#endif

#endif
