/* Assertions exercise the dispatch ABI in every build configuration. */
#ifdef NDEBUG
#undef NDEBUG
#endif
#include "sassy_c.h"

#include <assert.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

_Static_assert(sizeof(sassy_c_backend) == sizeof(uint32_t), "backend ABI layout");
_Static_assert(sizeof(sassy_c_backend_status) == 20, "backend status ABI layout");

static sassy_c_slice span(const char *text) {
    return (sassy_c_slice){(const uint8_t *)text, strlen(text)};
}

static sassy_c_backend_status status(sassy_c_backend backend) {
    sassy_c_backend_status value = {.struct_size = sizeof(value)};
    assert(sassy_c_backend_status_get(backend, &value) == SASSY_C_OK);
    assert(value.backend == backend);
    assert(sassy_c_backend_name(backend) != NULL);
    return value;
}

static void select_backend(const char *backend) {
    assert(setenv("SASSY_C_BACKEND", backend, 1) == 0);
}

static void run_search(sassy_c_backend expected) {
    sassy_c_options options = {
        .struct_size = sizeof(options),
        .all_endpoints = 0,
        .include_cigar = 1,
        .reserved = 0,
    };
    sassy_c_searcher *searcher = NULL;
    sassy_c_result *result = NULL;
    const sassy_c_hit *hits = NULL;
    const uint8_t *cigars = NULL;
    size_t count = 0;
    size_t cigar_bytes = 0;

    assert(sassy_c_searcher_new(SASSY_C_DNA, 1, &searcher) == SASSY_C_OK);
    assert(searcher != NULL);
    assert(sassy_c_search(searcher, span("ACGA"), span("TTACGAAA"), 0, &options, &result) ==
           SASSY_C_OK);
    assert(result != NULL);
    assert(sassy_c_result_view(result, &hits, &count, &cigars, &cigar_bytes) == SASSY_C_OK);
    assert(count == 1 && hits[0].text_start == 2 && hits[0].text_end == 6);
    assert(cigar_bytes == 2);
    assert(memcmp(cigars, "4=", cigar_bytes) == 0);
    sassy_c_result_free(result);
    result = (sassy_c_result *)(uintptr_t)1;
    assert(sassy_c_search(searcher, span(""), span("ACGA"), 0, &options, &result) ==
           SASSY_C_INVALID);
    assert(result == NULL && strlen(sassy_c_last_error()) > 0);
    sassy_c_searcher_free(searcher);

    sassy_c_backend_status value = status(expected);
    assert(value.selected == 1);
}

static void *search_worker(void *argument) {
    run_search(*(const sassy_c_backend *)argument);
    return NULL;
}

static void run_concurrent_searches(sassy_c_backend expected) {
    pthread_t workers[8];
    for (size_t index = 0; index < sizeof(workers) / sizeof(workers[0]); ++index) {
        assert(pthread_create(&workers[index], NULL, search_worker, &expected) == 0);
    }
    for (size_t index = 0; index < sizeof(workers) / sizeof(workers[0]); ++index) {
        assert(pthread_join(workers[index], NULL) == 0);
    }
    select_backend("not-a-backend");
    run_search(expected);
}

static sassy_c_backend best_backend(void) {
    const sassy_c_backend order[] = {
        SASSY_C_BACKEND_AVX512,
        SASSY_C_BACKEND_AVX2,
        SASSY_C_BACKEND_NEON,
        SASSY_C_BACKEND_SCALAR,
    };
    for (size_t i = 0; i < sizeof(order) / sizeof(order[0]); ++i) {
        sassy_c_backend_status value = status(order[i]);
        if (value.compiled && value.supported) {
            return order[i];
        }
    }
    abort();
}

static int run_named_backend(const char *name) {
    for (int value = SASSY_C_BACKEND_SCALAR; value < SASSY_C_BACKEND_COUNT; ++value) {
        sassy_c_backend backend = (sassy_c_backend)value;
        if (strcmp(name, sassy_c_backend_name(backend)) == 0) {
            sassy_c_backend_status value = status(backend);
            if (!value.compiled || !value.supported) {
                return 77;
            }
            select_backend(name);
            run_concurrent_searches(backend);
            return 0;
        }
    }
    return 2;
}

static void test_unavailable(void) {
    const sassy_c_backend candidates[] = {
        SASSY_C_BACKEND_AVX512,
        SASSY_C_BACKEND_AVX2,
        SASSY_C_BACKEND_NEON,
    };
    for (size_t i = 0; i < sizeof(candidates) / sizeof(candidates[0]); ++i) {
        sassy_c_backend_status value = status(candidates[i]);
        if (!value.compiled || !value.supported) {
            sassy_c_searcher *searcher = (sassy_c_searcher *)(uintptr_t)1;
            sassy_c_result *result = (sassy_c_result *)(uintptr_t)1;
            select_backend(sassy_c_backend_name(candidates[i]));
            assert(sassy_c_searcher_new(SASSY_C_DNA, 0, &searcher) == SASSY_C_INVALID);
            assert(searcher == NULL);
            assert(strstr(sassy_c_last_error(), "requested SASSY_C_BACKEND") != NULL);
            assert(sassy_c_search(NULL, span("ACGT"), span("ACGT"), 0, NULL, &result) ==
                   SASSY_C_INVALID);
            assert(result == NULL);
            return;
        }
    }
    exit(77);
}

static void test_unknown(void) {
    sassy_c_searcher *searcher = (sassy_c_searcher *)(uintptr_t)1;
    select_backend("not-a-backend");
    assert(sassy_c_searcher_new(SASSY_C_DNA, 0, &searcher) == SASSY_C_INVALID);
    assert(searcher == NULL);
    assert(strstr(sassy_c_last_error(), "unknown SASSY_C_BACKEND") != NULL);
}

int main(int argc, char **argv) {
    assert(argc == 2);
    if (strcmp(argv[1], "auto") == 0) {
        sassy_c_backend expected = best_backend();
        select_backend("auto");
        run_concurrent_searches(expected);
    } else if (strcmp(argv[1], "unavailable") == 0) {
        test_unavailable();
    } else if (strcmp(argv[1], "unknown") == 0) {
        test_unknown();
    } else {
        return run_named_backend(argv[1]);
    }
    puts("C dispatch tests passed");
    return 0;
}
