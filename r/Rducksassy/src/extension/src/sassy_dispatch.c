#include "sassy_backend.h"

#include <pthread.h>
#include <stdbool.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if defined(__linux__) && defined(__aarch64__)
#include <asm/hwcap.h>
#include <sys/auxv.h>
#endif

#define SASSY_C_DISPATCH_ERROR_BYTES 256

static pthread_once_t sassy_c_selection_once = PTHREAD_ONCE_INIT;
static const sassy_c_backend_table *sassy_c_selected_table;
static _Atomic(sassy_c_backend) sassy_c_selected_backend = SASSY_C_BACKEND_COUNT;
static char sassy_c_selection_error[SASSY_C_DISPATCH_ERROR_BYTES];
static _Thread_local const sassy_c_backend_table *sassy_c_thread_table;
static _Thread_local char sassy_c_dispatch_error[SASSY_C_DISPATCH_ERROR_BYTES];
static _Thread_local bool sassy_c_has_dispatch_error;

static void sassy_c_clear_dispatch_error(void) {
    sassy_c_dispatch_error[0] = '\0';
    sassy_c_has_dispatch_error = false;
}

static void sassy_c_set_dispatch_error(const char *message) {
    snprintf(sassy_c_dispatch_error, sizeof(sassy_c_dispatch_error), "%s", message);
    sassy_c_has_dispatch_error = true;
}

static bool sassy_c_backend_valid(sassy_c_backend backend) {
    return backend >= SASSY_C_BACKEND_SCALAR && backend < SASSY_C_BACKEND_COUNT;
}

const char *sassy_c_backend_name(sassy_c_backend backend) {
    switch (backend) {
    case SASSY_C_BACKEND_SCALAR:
        return "scalar";
    case SASSY_C_BACKEND_AVX2:
        return "avx2";
    case SASSY_C_BACKEND_AVX512:
        return "avx512";
    case SASSY_C_BACKEND_NEON:
        return "neon";
    case SASSY_C_BACKEND_WASM128:
        return "wasm128";
    default:
        return NULL;
    }
}

static bool sassy_c_cpu_has_avx2(void) {
#if (defined(__x86_64__) || defined(_M_X64)) && (defined(__GNUC__) || defined(__clang__))
    __builtin_cpu_init();
    return __builtin_cpu_supports("avx2") != 0 && __builtin_cpu_supports("popcnt") != 0;
#else
    return false;
#endif
}

static bool sassy_c_cpu_has_avx512(void) {
#if (defined(__x86_64__) || defined(_M_X64)) && (defined(__GNUC__) || defined(__clang__))
    __builtin_cpu_init();
    return __builtin_cpu_supports("avx2") != 0 && __builtin_cpu_supports("popcnt") != 0 &&
           __builtin_cpu_supports("avx512f") != 0 && __builtin_cpu_supports("avx512bw") != 0;
#else
    return false;
#endif
}

static bool sassy_c_cpu_has_neon(void) {
#if defined(__aarch64__) && defined(__linux__)
    return (getauxval(AT_HWCAP) & HWCAP_ASIMD) != 0;
#elif defined(__aarch64__) && defined(__APPLE__)
    return true;
#else
    return false;
#endif
}

/* WebAssembly SIMD is fixed when the module is validated; there is no runtime
 * ISA probe. CMake only defines SASSY_C_HAVE_WASM128 when it compiled this
 * translation unit with -msimd128. */
static bool sassy_c_cpu_has_wasm128(void) {
#if defined(__wasm_simd128__)
    return true;
#else
    return false;
#endif
}

static bool sassy_c_backend_compiled(sassy_c_backend backend) {
    switch (backend) {
    case SASSY_C_BACKEND_SCALAR:
        return SASSY_C_HAVE_SCALAR != 0;
    case SASSY_C_BACKEND_AVX2:
        return SASSY_C_HAVE_AVX2 != 0;
    case SASSY_C_BACKEND_AVX512:
        return SASSY_C_HAVE_AVX512 != 0;
    case SASSY_C_BACKEND_NEON:
        return SASSY_C_HAVE_NEON != 0;
    case SASSY_C_BACKEND_WASM128:
        return SASSY_C_HAVE_WASM128 != 0;
    default:
        return false;
    }
}

static bool sassy_c_backend_supported(sassy_c_backend backend) {
    switch (backend) {
    case SASSY_C_BACKEND_SCALAR:
        return true;
    case SASSY_C_BACKEND_AVX2:
        return sassy_c_cpu_has_avx2();
    case SASSY_C_BACKEND_AVX512:
        return sassy_c_cpu_has_avx512();
    case SASSY_C_BACKEND_NEON:
        return sassy_c_cpu_has_neon();
    case SASSY_C_BACKEND_WASM128:
        return sassy_c_cpu_has_wasm128();
    default:
        return false;
    }
}

static sassy_c_backend_getter sassy_c_backend_getter_for(sassy_c_backend backend) {
    switch (backend) {
#if SASSY_C_HAVE_SCALAR
    case SASSY_C_BACKEND_SCALAR:
        return sassy_c_backend_scalar_get_table;
#endif
#if SASSY_C_HAVE_AVX2
    case SASSY_C_BACKEND_AVX2:
        return sassy_c_backend_avx2_get_table;
#endif
#if SASSY_C_HAVE_AVX512
    case SASSY_C_BACKEND_AVX512:
        return sassy_c_backend_avx512_get_table;
#endif
#if SASSY_C_HAVE_NEON
    case SASSY_C_BACKEND_NEON:
        return sassy_c_backend_neon_get_table;
#endif
#if SASSY_C_HAVE_WASM128
    case SASSY_C_BACKEND_WASM128:
        return sassy_c_backend_wasm128_get_table;
#endif
    default:
        return NULL;
    }
}

static bool sassy_c_backend_table_valid(const sassy_c_backend_table *table) {
    return table != NULL && table->version == SASSY_C_BACKEND_TABLE_VERSION &&
           table->struct_size == sizeof(*table) && table->last_error != NULL &&
           table->searcher_new != NULL && table->searcher_free != NULL && table->search != NULL &&
           table->search_many != NULL && table->crispr_search_many != NULL &&
           table->result_view != NULL && table->result_free != NULL;
}

static bool sassy_c_backend_from_name(const char *name, sassy_c_backend *backend) {
    for (int value = SASSY_C_BACKEND_SCALAR; value < SASSY_C_BACKEND_COUNT; ++value) {
        sassy_c_backend candidate = (sassy_c_backend)value;
        if (strcmp(name, sassy_c_backend_name(candidate)) == 0) {
            *backend = candidate;
            return true;
        }
    }
    return false;
}

static sassy_c_backend sassy_c_best_backend(void) {
    const sassy_c_backend order[] = {
        SASSY_C_BACKEND_AVX512,
        SASSY_C_BACKEND_AVX2,
        SASSY_C_BACKEND_NEON,
        SASSY_C_BACKEND_WASM128,
        SASSY_C_BACKEND_SCALAR,
    };
    for (size_t i = 0; i < sizeof(order) / sizeof(order[0]); ++i) {
        if (sassy_c_backend_compiled(order[i]) && sassy_c_backend_supported(order[i])) {
            return order[i];
        }
    }
    return SASSY_C_BACKEND_SCALAR;
}

static void sassy_c_select_backend(void) {
    const char *requested = getenv("SASSY_C_BACKEND");
    sassy_c_backend backend;
    if (requested == NULL || requested[0] == '\0' || strcmp(requested, "auto") == 0) {
        backend = sassy_c_best_backend();
    } else if (!sassy_c_backend_from_name(requested, &backend)) {
        snprintf(sassy_c_selection_error, sizeof(sassy_c_selection_error),
                 "unknown SASSY_C_BACKEND '%s'", requested);
        return;
    }
    if (!sassy_c_backend_compiled(backend)) {
        snprintf(sassy_c_selection_error, sizeof(sassy_c_selection_error),
                 "requested SASSY_C_BACKEND '%s' was not compiled", sassy_c_backend_name(backend));
        return;
    }
    if (!sassy_c_backend_supported(backend)) {
        snprintf(sassy_c_selection_error, sizeof(sassy_c_selection_error),
                 "requested SASSY_C_BACKEND '%s' is not supported by this CPU/OS",
                 sassy_c_backend_name(backend));
        return;
    }
    sassy_c_backend_getter getter = sassy_c_backend_getter_for(backend);
    const sassy_c_backend_table *table = getter == NULL ? NULL : getter();
    if (!sassy_c_backend_table_valid(table)) {
        snprintf(sassy_c_selection_error, sizeof(sassy_c_selection_error),
                 "Sassy backend '%s' has an incompatible private table ABI",
                 sassy_c_backend_name(backend));
        return;
    }
    sassy_c_selected_table = table;
    atomic_store_explicit(&sassy_c_selected_backend, backend, memory_order_release);
}

static const sassy_c_backend_table *sassy_c_backend_for_call(void) {
    (void)pthread_once(&sassy_c_selection_once, sassy_c_select_backend);
    if (sassy_c_selected_table == NULL) {
        sassy_c_set_dispatch_error(sassy_c_selection_error);
        return NULL;
    }
    sassy_c_thread_table = sassy_c_selected_table;
    return sassy_c_selected_table;
}

static int32_t sassy_c_prepare_searcher_out(sassy_c_searcher **out) {
    if (out == NULL) {
        sassy_c_set_dispatch_error("out searcher is NULL");
        return SASSY_C_INVALID;
    }
    *out = NULL;
    return SASSY_C_OK;
}

static int32_t sassy_c_prepare_result_out(sassy_c_result **out) {
    if (out == NULL) {
        sassy_c_set_dispatch_error("out result is NULL");
        return SASSY_C_INVALID;
    }
    *out = NULL;
    return SASSY_C_OK;
}

uint32_t sassy_c_abi_version(void) {
    return SASSY_C_ABI_VERSION;
}

const char *sassy_c_last_error(void) {
    if (sassy_c_has_dispatch_error) {
        return sassy_c_dispatch_error;
    }
    if (sassy_c_thread_table != NULL) {
        return sassy_c_thread_table->last_error();
    }
    return sassy_c_dispatch_error;
}

int32_t sassy_c_backend_status_get(sassy_c_backend backend, sassy_c_backend_status *out) {
    if (out == NULL) {
        sassy_c_set_dispatch_error("backend status output is NULL");
        return SASSY_C_INVALID;
    }
    if (out->struct_size != sizeof(*out)) {
        sassy_c_set_dispatch_error("backend status has an incompatible structure size");
        return SASSY_C_INVALID;
    }
    if (!sassy_c_backend_valid(backend)) {
        sassy_c_set_dispatch_error("unknown Sassy backend");
        return SASSY_C_INVALID;
    }
    *out = (sassy_c_backend_status){
        .struct_size = sizeof(*out),
        .backend = backend,
        .compiled = sassy_c_backend_compiled(backend),
        .supported = sassy_c_backend_supported(backend),
        .selected =
            atomic_load_explicit(&sassy_c_selected_backend, memory_order_acquire) == backend,
    };
    sassy_c_clear_dispatch_error();
    return SASSY_C_OK;
}

int32_t sassy_c_searcher_new(uint32_t alphabet, uint32_t reverse_complement,
                             sassy_c_searcher **out) {
    int32_t status = sassy_c_prepare_searcher_out(out);
    if (status != SASSY_C_OK) {
        return status;
    }
    const sassy_c_backend_table *table = sassy_c_backend_for_call();
    if (table == NULL) {
        return SASSY_C_INVALID;
    }
    sassy_c_clear_dispatch_error();
    return table->searcher_new(alphabet, reverse_complement, out);
}

void sassy_c_searcher_free(sassy_c_searcher *searcher) {
    if (searcher == NULL) {
        return;
    }
    const sassy_c_backend_table *table = sassy_c_backend_for_call();
    if (table != NULL) {
        table->searcher_free(searcher);
    }
}

int32_t sassy_c_search(sassy_c_searcher *searcher, sassy_c_slice pattern, sassy_c_slice text,
                       uint32_t k, const sassy_c_options *options, sassy_c_result **out) {
    int32_t status = sassy_c_prepare_result_out(out);
    if (status != SASSY_C_OK) {
        return status;
    }
    const sassy_c_backend_table *table = sassy_c_backend_for_call();
    if (table == NULL) {
        return SASSY_C_INVALID;
    }
    sassy_c_clear_dispatch_error();
    return table->search(searcher, pattern, text, k, options, out);
}

int32_t sassy_c_search_many(sassy_c_searcher *searcher, const sassy_c_slice *patterns,
                            size_t n_patterns, sassy_c_slice text, uint32_t k,
                            const sassy_c_options *options, sassy_c_result **out) {
    int32_t status = sassy_c_prepare_result_out(out);
    if (status != SASSY_C_OK) {
        return status;
    }
    const sassy_c_backend_table *table = sassy_c_backend_for_call();
    if (table == NULL) {
        return SASSY_C_INVALID;
    }
    sassy_c_clear_dispatch_error();
    return table->search_many(searcher, patterns, n_patterns, text, k, options, out);
}

int32_t sassy_c_crispr_search_many(sassy_c_searcher *searcher, const sassy_c_slice *guides,
                                   size_t guide_count, sassy_c_slice text, uint32_t k,
                                   const sassy_c_crispr_options *options, sassy_c_result **out) {
    int32_t status = sassy_c_prepare_result_out(out);
    if (status != SASSY_C_OK) {
        return status;
    }
    const sassy_c_backend_table *table = sassy_c_backend_for_call();
    if (table == NULL) {
        return SASSY_C_INVALID;
    }
    sassy_c_clear_dispatch_error();
    return table->crispr_search_many(searcher, guides, guide_count, text, k, options, out);
}

int32_t sassy_c_result_view(const sassy_c_result *result, const sassy_c_hit **hits, size_t *count,
                            const uint8_t **cigars, size_t *cigar_bytes) {
    const sassy_c_backend_table *table = sassy_c_backend_for_call();
    if (table == NULL) {
        return SASSY_C_INVALID;
    }
    sassy_c_clear_dispatch_error();
    return table->result_view(result, hits, count, cigars, cigar_bytes);
}

void sassy_c_result_free(sassy_c_result *result) {
    if (result == NULL) {
        return;
    }
    const sassy_c_backend_table *table = sassy_c_backend_for_call();
    if (table != NULL) {
        table->result_free(result);
    }
}
