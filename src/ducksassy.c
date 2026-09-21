/* DuckDB C API v2 adapter for the Sassy C library. */
#define DUCKDB_EXTENSION_NAME ducksassy
#define DUCKDB_V2_API_ALLOW_UNSTABLE 0
#define DUCKDB_V2_API_ALLOW_DEPRECATED 0
#include "duckdb_extension_v2.h"
#include "sassy_c.h"
#include <ctype.h>
#include <limits.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if DUCKDB_EXTENSION_HEADER_VERSION != 2 || DUCKDB_V2_API_VERSION_MAJOR != 2
#error "ducksassy requires the DuckDB C API v2 SDK"
#endif

DUCKDB_EXTENSION_EXTERN

#define CHUNK_HIT_LIMIT UINT64_C(1048576)
#define PANEL_LIMIT 4096
#define ALPHABET_COUNT (SASSY_C_IUPAC + 1)
#define ORIENTATION_COUNT 2

typedef enum {
    ARG_PATTERN,
    ARG_TEXT,
    ARG_MAX_EDITS,
    ARG_ALPHABET,
    ARG_PAM_LENGTH = ARG_ALPHABET,
    ARG_REVERSE_COMPLEMENT,
    ARG_ALL_ENDPOINTS,
    ARG_ALLOW_PAM_EDITS = ARG_ALL_ENDPOINTS,
    ARG_MAX_HITS,
    ARG_MAX_TEXT_BYTES,
    ARG_MAX_N_FRACTION,
    CRISPR_ARGUMENT_COUNT,
    SEARCH_ARGUMENT_COUNT = ARG_MAX_N_FRACTION
} search_argument;

typedef enum {
    HIT_PATTERN_INDEX,
    HIT_TEXT_START,
    HIT_TEXT_END,
    HIT_PATTERN_START,
    HIT_PATTERN_END,
    HIT_COST,
    HIT_STRAND,
    HIT_CIGAR,
    HIT_FIELD_COUNT
} hit_field;

typedef enum {
    OP_MATCHES,
    OP_COUNT,
    OP_CONTAINS,
    OP_CRISPR
} operation_kind;

typedef struct {
    const char *name;
    operation_kind kind;
    bool panel;
} search_operation;

static const search_operation operations[] = {
    {.name = "__sassy_matches", .kind = OP_MATCHES, .panel = false},
    {.name = "__sassy_matches_many", .kind = OP_MATCHES, .panel = true},
    {.name = "__sassy_count", .kind = OP_COUNT, .panel = false},
    {.name = "__sassy_count_many", .kind = OP_COUNT, .panel = true},
    {.name = "__sassy_contains", .kind = OP_CONTAINS, .panel = false},
    {.name = "__sassy_contains_many", .kind = OP_CONTAINS, .panel = true},
    {.name = "__sassy_crispr_matches", .kind = OP_CRISPR, .panel = false},
    {.name = "__sassy_crispr_matches_many", .kind = OP_CRISPR, .panel = true}};

typedef struct {
    sassy_c_searcher *searchers[ALPHABET_COUNT][ORIENTATION_COUNT];
    sassy_c_slice *patterns;
    size_t pattern_capacity;
} search_worker;

/* Both buffers are borrowed from one sassy_c_result. */
typedef struct {
    const sassy_c_hit *hits;
    size_t hit_count;
    const uint8_t *cigars;
    size_t cigar_bytes;
} hit_batch_view;

static duckdb_v2_str string_view(const char *text) {
    duckdb_v2_str view = {text, (idx_t)strlen(text)};
    return view;
}

/* Callback error handles are borrowed. Each fallible API call receives a
 * separate owned error slot; its detail is copied into the callback handle. */
static void set_error(duckdb_v2_error_info_handle target, DUCKDB_V2_ERROR code, const char *text) {
    (void)duckdb_v2_error_info_set_code(target, code);
    (void)duckdb_v2_error_info_set_text(target, string_view(text));
}

static void copy_duckdb_error(duckdb_v2_error_info_handle target, DUCKDB_V2_ERROR code,
                              duckdb_v2_error_info_handle source) {
    duckdb_v2_str text = string_view("ducksassy: DuckDB C API v2 call failed");
    if (source) {
        (void)duckdb_v2_error_info_get_text(source, &text);
    }
    (void)duckdb_v2_error_info_set_code(target, code);
    (void)duckdb_v2_error_info_set_text(target, text);
}

#define DUCKDB_CALL(expression)                                                                    \
    do {                                                                                           \
        DUCKDB_V2_ERROR call_status = (expression);                                                \
        if (call_status != DUCKDB_V2_ERROR_NONE) {                                                 \
            copy_duckdb_error(*error, call_status, detail);                                        \
            goto cleanup;                                                                          \
        }                                                                                          \
    } while (0)

#define INPUT_ERROR(text)                                                                          \
    do {                                                                                           \
        set_error(*error, DUCKDB_V2_ERROR_INPUT_INVALID, text);                                    \
        goto cleanup;                                                                              \
    } while (0)

static idx_t physical_row(const duckdb_v2_vector_view *view, idx_t row) {
    return view->sel ? view->sel[row] : row;
}

static bool row_is_valid(const duckdb_v2_vector_view *view, idx_t row) {
    idx_t position = physical_row(view, row);
    return !view->validity ||
           (view->validity[position >> 6] & (UINT64_C(1) << (position & 63))) != 0;
}

static void mark_valid(uint64_t *mask, idx_t row) {
    mask[row >> 6] |= UINT64_C(1) << (row & 63);
}

static sassy_c_slice byte_span(const duckdb_v2_vector_view *view, idx_t row) {
    const duckdb_v2_bytes *bytes = &((const duckdb_v2_bytes *)view->data)[physical_row(view, row)];
    sassy_c_slice span;
    span.len = bytes->value.inlined.length;
    if (span.len <= sizeof(bytes->value.inlined.inlined)) {
        span.data = (const uint8_t *)bytes->value.inlined.inlined;
    } else {
        span.data = (const uint8_t *)bytes->value.pointer.ptr;
    }
    return span;
}

static bool equal_label(sassy_c_slice value, const char *label) {
    size_t length = strlen(label);
    if (value.len != length) {
        return false;
    }
    for (size_t index = 0; index < length; ++index) {
        if (tolower((unsigned char)value.data[index]) != (unsigned char)label[index]) {
            return false;
        }
    }
    return true;
}

static int64_t integer_at(const duckdb_v2_vector_view *view, idx_t row) {
    return ((const int64_t *)view->data)[physical_row(view, row)];
}

static bool boolean_at(const duckdb_v2_vector_view *view, idx_t row) {
    return ((const bool *)view->data)[physical_row(view, row)];
}

static DUCKDB_V2_ERROR write_bytes(duckdb_v2_arena_handle arena, duckdb_v2_bytes *output,
                                   const uint8_t *bytes, size_t length,
                                   duckdb_v2_error_info_handle *detail) {
    memset(output, 0, sizeof(*output));
    if (length > UINT32_MAX) {
        return DUCKDB_V2_ERROR_INPUT_INVALID;
    }
    output->value.inlined.length = (uint32_t)length;
    if (length <= sizeof(output->value.inlined.inlined)) {
        if (length > 0) {
            memcpy(output->value.inlined.inlined, bytes, length);
        }
        return DUCKDB_V2_ERROR_NONE;
    }
    uint8_t *target = NULL;
    DUCKDB_V2_ERROR status = duckdb_v2_arena_allocate(arena, (idx_t)length, &target, detail);
    if (status != DUCKDB_V2_ERROR_NONE) {
        return status;
    }
    memcpy(target, bytes, length);
    memcpy(output->value.pointer.prefix, bytes, sizeof(output->value.pointer.prefix));
    output->value.pointer.ptr = (char *)target;
    return DUCKDB_V2_ERROR_NONE;
}

static void worker_destroy(void *pointer) {
    search_worker *worker = (search_worker *)pointer;
    if (!worker) {
        return;
    }
    for (uint32_t alphabet = 0; alphabet < ALPHABET_COUNT; ++alphabet) {
        for (uint32_t orientation = 0; orientation < ORIENTATION_COUNT; ++orientation) {
            sassy_c_searcher_free(worker->searchers[alphabet][orientation]);
        }
    }
    free(worker->patterns);
    free(worker);
}

static void scalar_init(duckdb_v2_scalar_function_init_info_handle info,
                        duckdb_v2_context_handle context, duckdb_v2_error_info_handle *error) {
    (void)context;
    search_worker *worker = (search_worker *)calloc(1, sizeof(*worker));
    if (!worker) {
        set_error(*error, DUCKDB_V2_ERROR_INPUT_INVALID, "ducksassy: worker allocation failed");
        return;
    }
    duckdb_v2_opaque state = {worker, worker_destroy, NULL};
    duckdb_v2_error_info_handle detail = NULL;
    DUCKDB_V2_ERROR status = duckdb_v2_scalar_function_init_set_init_data(info, &state, &detail);
    if (status != DUCKDB_V2_ERROR_NONE) {
        copy_duckdb_error(*error, status, detail);
        worker_destroy(worker);
    }
    (void)duckdb_v2_error_info_destroy(&detail);
}

static bool append_hits(duckdb_v2_vector_handle output, const hit_batch_view *batch, idx_t offset,
                        duckdb_v2_error_info_handle *error) {
    duckdb_v2_error_info_handle detail = NULL;
    bool success = false;
    if ((uint64_t)batch->hit_count > CHUNK_HIT_LIMIT - offset) {
        INPUT_ERROR("ducksassy: chunk exceeds 1048576 output hits; reduce the search scope or use "
                    "count/contains");
    }
    idx_t new_size = offset + batch->hit_count;
    DUCKDB_CALL(duckdb_v2_vector_set_size(output, new_size, &detail));
    uint64_t *struct_validity = NULL;
    DUCKDB_CALL(duckdb_v2_vector_flat_get_validity_mutable(output, &struct_validity, &detail));
    duckdb_v2_vector_handle fields[HIT_FIELD_COUNT] = {0};
    void *field_data[HIT_FIELD_COUNT] = {0};
    uint64_t *field_validity[HIT_FIELD_COUNT] = {0};
    for (idx_t field = 0; field < HIT_FIELD_COUNT; ++field) {
        DUCKDB_CALL(duckdb_v2_vector_get_child(output, field, &fields[field], &detail));
        DUCKDB_CALL(duckdb_v2_vector_set_size(fields[field], new_size, &detail));
        DUCKDB_CALL(duckdb_v2_vector_get_data_mutable(fields[field], &field_data[field], &detail));
        DUCKDB_CALL(duckdb_v2_vector_flat_get_validity_mutable(fields[field],
                                                               &field_validity[field], &detail));
    }
    duckdb_v2_arena_handle cigar_arena = NULL;
    DUCKDB_CALL(duckdb_v2_vector_get_arena(fields[HIT_CIGAR], &cigar_arena, &detail));
    for (size_t index = 0; index < batch->hit_count; ++index) {
        idx_t position = offset + index;
        const sassy_c_hit *hit = &batch->hits[index];
        ((uint64_t *)field_data[HIT_PATTERN_INDEX])[position] = hit->pattern_idx;
        ((uint64_t *)field_data[HIT_TEXT_START])[position] = hit->text_start;
        ((uint64_t *)field_data[HIT_TEXT_END])[position] = hit->text_end;
        ((uint64_t *)field_data[HIT_PATTERN_START])[position] = hit->pattern_start;
        ((uint64_t *)field_data[HIT_PATTERN_END])[position] = hit->pattern_end;
        ((int32_t *)field_data[HIT_COST])[position] = hit->cost;
        const uint8_t strand = hit->strand ? '-' : '+';
        duckdb_v2_bytes *strand_output = &((duckdb_v2_bytes *)field_data[HIT_STRAND])[position];
        DUCKDB_CALL(write_bytes(NULL, strand_output, &strand, 1, &detail));
        if (hit->cigar_offset > batch->cigar_bytes ||
            hit->cigar_length > batch->cigar_bytes - hit->cigar_offset) {
            INPUT_ERROR("ducksassy: invalid CIGAR slab bounds returned by Rust");
        }
        const uint8_t *cigar = hit->cigar_length ? batch->cigars + hit->cigar_offset : NULL;
        duckdb_v2_bytes *cigar_output = &((duckdb_v2_bytes *)field_data[HIT_CIGAR])[position];
        DUCKDB_CALL(
            write_bytes(cigar_arena, cigar_output, cigar, (size_t)hit->cigar_length, &detail));
        mark_valid(struct_validity, position);
        for (idx_t field = 0; field < HIT_FIELD_COUNT; ++field) {
            mark_valid(field_validity[field], position);
        }
    }
    success = true;
cleanup:
    (void)duckdb_v2_error_info_destroy(&detail);
    return success;
}

static void scalar_exec(duckdb_v2_scalar_function_exec_info_handle info,
                        duckdb_v2_context_handle context, duckdb_v2_error_info_handle *error) {
    (void)context;
    duckdb_v2_error_info_handle detail = NULL;
    duckdb_v2_vector_handle arguments[CRISPR_ARGUMENT_COUNT] = {0};
    duckdb_v2_vector_handle output = NULL;
    duckdb_v2_vector_handle pattern_child = NULL;
    duckdb_v2_vector_handle hit_struct = NULL;
    duckdb_v2_vector_view views[CRISPR_ARGUMENT_COUNT];
    duckdb_v2_vector_view pattern_view;
    sassy_c_result *result = NULL;
    search_worker *worker = NULL;
    void *user_data = NULL;
    void *init_data = NULL;
    void *output_data = NULL;
    uint64_t *output_validity = NULL;
    idx_t row_count = 0;
    idx_t total_hits = 0;

    DUCKDB_CALL(duckdb_v2_scalar_function_exec_get_user_data(info, &user_data, &detail));
    const search_operation *operation = (const search_operation *)user_data;
    DUCKDB_CALL(duckdb_v2_scalar_function_exec_get_init_data(info, &init_data, &detail));
    worker = (search_worker *)init_data;
    if (!operation || !worker) {
        INPUT_ERROR("ducksassy: missing function/worker state");
    }
    bool crispr = operation->kind == OP_CRISPR;
    bool output_hits = operation->kind == OP_MATCHES || crispr;
    uint32_t argument_count = crispr ? CRISPR_ARGUMENT_COUNT : SEARCH_ARGUMENT_COUNT;
    DUCKDB_CALL(duckdb_v2_scalar_function_exec_get_row_count(info, &row_count, &detail));

    /* Flatten all inputs before borrowing views: a later aliased dictionary
     * must not invalidate an earlier view. String payloads remain borrowed. */
    for (uint32_t argument = 0; argument < argument_count; ++argument) {
        DUCKDB_CALL(
            duckdb_v2_scalar_function_exec_get_arg(info, argument, &arguments[argument], &detail));
        DUCKDB_CALL(duckdb_v2_vector_flatten(arguments[argument], &detail));
    }
    if (operation->panel) {
        DUCKDB_CALL(duckdb_v2_vector_get_child(arguments[ARG_PATTERN], 0, &pattern_child, &detail));
        DUCKDB_CALL(duckdb_v2_vector_flatten(pattern_child, &detail));
    }
    for (uint32_t argument = 0; argument < argument_count; ++argument) {
        DUCKDB_CALL(duckdb_v2_vector_get_view(arguments[argument], &views[argument], &detail));
    }
    if (operation->panel) {
        DUCKDB_CALL(duckdb_v2_vector_get_view(pattern_child, &pattern_view, &detail));
    }
    DUCKDB_CALL(duckdb_v2_scalar_function_exec_get_result(info, &output, &detail));
    DUCKDB_CALL(duckdb_v2_vector_flatten(output, &detail));
    DUCKDB_CALL(duckdb_v2_vector_set_size(output, row_count, &detail));
    DUCKDB_CALL(duckdb_v2_vector_get_data_mutable(output, &output_data, &detail));
    DUCKDB_CALL(duckdb_v2_vector_flat_get_validity_mutable(output, &output_validity, &detail));
    if (output_hits) {
        DUCKDB_CALL(duckdb_v2_vector_get_child(output, 0, &hit_struct, &detail));
        DUCKDB_CALL(duckdb_v2_vector_set_size(hit_struct, 0, &detail));
    }

    for (idx_t row = 0; row < row_count; ++row) {
        bool valid = true;
        for (uint32_t argument = 0; argument < argument_count; ++argument) {
            valid = valid && row_is_valid(&views[argument], row);
        }
        if (!valid) {
            if (output_hits) {
                ((duckdb_v2_list_entry *)output_data)[row] = (duckdb_v2_list_entry){0, 0};
            }
            DUCKDB_CALL(duckdb_v2_vector_set_null(output, row, &detail));
            continue;
        }

        int64_t max_edits = integer_at(&views[ARG_MAX_EDITS], row);
        int64_t max_hits = integer_at(&views[ARG_MAX_HITS], row);
        int64_t max_text_bytes = integer_at(&views[ARG_MAX_TEXT_BYTES], row);
        if (max_edits < 0 || (uint64_t)max_edits > UINT32_MAX || max_hits <= 0 ||
            max_text_bytes <= 0) {
            INPUT_ERROR("ducksassy: k must be nonnegative and resource limits must be positive");
        }
        uint32_t alphabet = SASSY_C_IUPAC;
        sassy_c_crispr_options crispr_options = {0};
        if (crispr) {
            int64_t pam_length = integer_at(&views[ARG_PAM_LENGTH], row);
            const duckdb_v2_vector_view *fraction_view = &views[ARG_MAX_N_FRACTION];
            double max_n_fraction =
                ((const double *)fraction_view->data)[physical_row(fraction_view, row)];
            if (pam_length <= 0 || (uint64_t)pam_length > UINT32_MAX ||
                !(max_n_fraction >= 0.0 && max_n_fraction <= 1.0)) {
                INPUT_ERROR(
                    "ducksassy: pam_length must be positive and max_n_frac must be in [0,1]");
            }
            crispr_options.struct_size = sizeof(crispr_options);
            crispr_options.pam_length = (uint32_t)pam_length;
            crispr_options.allow_pam_edits = boolean_at(&views[ARG_ALLOW_PAM_EDITS], row) ? 1U : 0U;
            crispr_options.include_cigar = 1;
            crispr_options.max_hits = (uint64_t)max_hits;
            crispr_options.max_text_bytes = (uint64_t)max_text_bytes;
            crispr_options.max_n_frac = (float)max_n_fraction;
        } else {
            sassy_c_slice label = byte_span(&views[ARG_ALPHABET], row);
            if (equal_label(label, "ascii")) {
                alphabet = SASSY_C_ASCII;
            } else if (equal_label(label, "dna")) {
                alphabet = SASSY_C_DNA;
            } else if (equal_label(label, "iupac")) {
                alphabet = SASSY_C_IUPAC;
            } else {
                INPUT_ERROR("ducksassy: alphabet must be ascii, dna, or iupac");
            }
        }
        uint32_t reverse_complement = boolean_at(&views[ARG_REVERSE_COMPLEMENT], row) ? 1U : 0U;
        sassy_c_searcher **searcher = &worker->searchers[alphabet][reverse_complement];
        if (!*searcher &&
            sassy_c_searcher_new(alphabet, reverse_complement, searcher) != SASSY_C_OK) {
            INPUT_ERROR(sassy_c_last_error());
        }
        sassy_c_options options = {.struct_size = sizeof(options),
                                   .all_endpoints =
                                       boolean_at(&views[ARG_ALL_ENDPOINTS], row) ? 1U : 0U,
                                   .include_cigar = output_hits ? 1U : 0U,
                                   .max_hits = (uint64_t)max_hits,
                                   .max_text_bytes = (uint64_t)max_text_bytes};

        sassy_c_slice text = byte_span(&views[ARG_TEXT], row);
        sassy_c_slice single_pattern;
        const sassy_c_slice *patterns = &single_pattern;
        size_t pattern_count = 1;
        if (operation->panel) {
            const duckdb_v2_vector_view *panel_view = &views[ARG_PATTERN];
            duckdb_v2_list_entry entry =
                ((const duckdb_v2_list_entry *)panel_view->data)[physical_row(panel_view, row)];
            if (entry.length > PANEL_LIMIT || entry.offset > pattern_view.count ||
                entry.length > pattern_view.count - entry.offset) {
                INPUT_ERROR("ducksassy: invalid panel bounds or more than 4096 patterns");
            }
            pattern_count = (size_t)entry.length;
            if (pattern_count > worker->pattern_capacity) {
                sassy_c_slice *resized =
                    (sassy_c_slice *)realloc(worker->patterns, pattern_count * sizeof(*resized));
                if (!resized) {
                    INPUT_ERROR("ducksassy: pattern descriptor allocation failed");
                }
                worker->patterns = resized;
                worker->pattern_capacity = pattern_count;
            }
            for (size_t index = 0; index < pattern_count; ++index) {
                idx_t child_row = entry.offset + index;
                if (!row_is_valid(&pattern_view, child_row)) {
                    INPUT_ERROR("ducksassy: a pattern panel cannot contain NULL elements");
                }
                worker->patterns[index] = byte_span(&pattern_view, child_row);
            }
            patterns = worker->patterns;
        } else {
            single_pattern = byte_span(&views[ARG_PATTERN], row);
        }

        int32_t status;
        if (crispr) {
            status = sassy_c_crispr_search_many(*searcher, patterns, pattern_count, text,
                                                (uint32_t)max_edits, &crispr_options, &result);
        } else {
            status = sassy_c_search_many(*searcher, patterns, pattern_count, text,
                                         (uint32_t)max_edits, &options, &result);
        }
        if (operation->panel && pattern_count > 0) {
            memset(worker->patterns, 0, pattern_count * sizeof(*worker->patterns));
        }
        if (status != SASSY_C_OK) {
            INPUT_ERROR(sassy_c_last_error());
        }
        hit_batch_view batch = {0};
        if (sassy_c_result_view(result, &batch.hits, &batch.hit_count, &batch.cigars,
                                &batch.cigar_bytes) != SASSY_C_OK) {
            INPUT_ERROR(sassy_c_last_error());
        }
        if (operation->kind == OP_COUNT) {
            ((uint64_t *)output_data)[row] = (uint64_t)batch.hit_count;
        } else if (operation->kind == OP_CONTAINS) {
            ((bool *)output_data)[row] = batch.hit_count != 0;
        } else {
            if (!append_hits(hit_struct, &batch, total_hits, error)) {
                goto cleanup;
            }
            ((duckdb_v2_list_entry *)output_data)[row] =
                (duckdb_v2_list_entry){total_hits, (idx_t)batch.hit_count};
            total_hits += batch.hit_count;
        }
        mark_valid(output_validity, row);
        sassy_c_result_free(result);
        result = NULL;
    }
cleanup:
    sassy_c_result_free(result);
    if (worker && worker->patterns) {
        memset(worker->patterns, 0, worker->pattern_capacity * sizeof(*worker->patterns));
    }
    (void)duckdb_v2_error_info_destroy(&detail);
}

static bool register_operation(duckdb_v2_extension_handle extension,
                               duckdb_v2_context_handle context, const search_operation *operation,
                               const char *sequence_type, duckdb_v2_error_info_handle *error) {
    duckdb_v2_scalar_function_handle function = NULL;
    duckdb_v2_function_signature_handle signature = NULL;
    duckdb_v2_logical_type_handle type = NULL;
    duckdb_v2_error_info_handle detail = NULL;
    bool success = false;
    duckdb_v2_str name = string_view(operation->name);
    DUCKDB_CALL(duckdb_v2_scalar_function_create_with_extension(extension, &function, &detail));
    DUCKDB_CALL(duckdb_v2_scalar_function_set_name(function, &name, &detail));
    DUCKDB_CALL(duckdb_v2_scalar_function_get_signature(function, &signature, &detail));
    char pattern_type[32];
    (void)snprintf(pattern_type, sizeof(pattern_type), "%s%s", sequence_type,
                   operation->panel ? "[]" : "");
    const char *types[CRISPR_ARGUMENT_COUNT] = {[ARG_PATTERN] = pattern_type,
                                                [ARG_TEXT] = sequence_type,
                                                [ARG_MAX_EDITS] = "BIGINT",
                                                [ARG_ALPHABET] = "VARCHAR",
                                                [ARG_REVERSE_COMPLEMENT] = "BOOLEAN",
                                                [ARG_ALL_ENDPOINTS] = "BOOLEAN",
                                                [ARG_MAX_HITS] = "BIGINT",
                                                [ARG_MAX_TEXT_BYTES] = "BIGINT",
                                                [ARG_MAX_N_FRACTION] = "DOUBLE"};
    const char *names[CRISPR_ARGUMENT_COUNT] = {[ARG_PATTERN] = "pattern",
                                                [ARG_TEXT] = "text",
                                                [ARG_MAX_EDITS] = "k",
                                                [ARG_ALPHABET] = "alphabet",
                                                [ARG_REVERSE_COMPLEMENT] = "rc",
                                                [ARG_ALL_ENDPOINTS] = "all_endpoints",
                                                [ARG_MAX_HITS] = "max_hits",
                                                [ARG_MAX_TEXT_BYTES] = "max_text_bytes",
                                                [ARG_MAX_N_FRACTION] = "max_n_frac"};
    uint32_t argument_count = SEARCH_ARGUMENT_COUNT;
    if (operation->kind == OP_CRISPR) {
        argument_count = CRISPR_ARGUMENT_COUNT;
        types[ARG_PAM_LENGTH] = "BIGINT";
        names[ARG_PATTERN] = "guide";
        names[ARG_PAM_LENGTH] = "pam_length";
        names[ARG_ALLOW_PAM_EDITS] = "allow_pam_edits";
    }
    for (uint32_t argument = 0; argument < argument_count; ++argument) {
        DUCKDB_CALL(duckdb_v2_context_create_type_from_text(context, string_view(types[argument]),
                                                            &type, &detail));
        DUCKDB_CALL(duckdb_v2_function_signature_add_parameter(
            signature, string_view(names[argument]), type, NULL, &detail));
        (void)duckdb_v2_logical_type_destroy(&type);
    }
    const char *return_type = "STRUCT(pattern_idx UBIGINT, text_start UBIGINT, text_end UBIGINT, "
                              "pattern_start UBIGINT, pattern_end UBIGINT, cost INTEGER, strand "
                              "VARCHAR, cigar VARCHAR)[]";
    if (operation->kind == OP_COUNT) {
        return_type = "UBIGINT";
    } else if (operation->kind == OP_CONTAINS) {
        return_type = "BOOLEAN";
    }
    DUCKDB_CALL(
        duckdb_v2_context_create_type_from_text(context, string_view(return_type), &type, &detail));
    DUCKDB_CALL(duckdb_v2_function_signature_set_return_type(signature, type, &detail));
    (void)duckdb_v2_logical_type_destroy(&type);
    duckdb_v2_opaque data = {(void *)operation, NULL, NULL};
    DUCKDB_CALL(duckdb_v2_scalar_function_set_user_data(function, &data, &detail));
    DUCKDB_CALL(duckdb_v2_scalar_function_set_property(
        function, DUCKDB_V2_FUNCTION_PROPERTY_NULL_HANDLING,
        DUCKDB_V2_FUNCTION_PROPERTY_NULL_HANDLING_SPECIAL, &detail));
    DUCKDB_CALL(duckdb_v2_scalar_function_set_property(
        function, DUCKDB_V2_FUNCTION_PROPERTY_COLLATION_HANDLING,
        DUCKDB_V2_FUNCTION_PROPERTY_COLLATION_HANDLING_IGNORE, &detail));
    DUCKDB_CALL(duckdb_v2_scalar_function_set_init_callback(function, scalar_init, &detail));
    DUCKDB_CALL(duckdb_v2_scalar_function_set_exec_callback(function, scalar_exec, &detail));
    DUCKDB_CALL(duckdb_v2_scalar_function_register(function, &detail));
    success = true;
cleanup:
    (void)duckdb_v2_logical_type_destroy(&type);
    (void)duckdb_v2_scalar_function_destroy(&function);
    (void)duckdb_v2_error_info_destroy(&detail);
    return success;
}

typedef enum {
    BACKEND_NAME,
    BACKEND_COMPILED,
    BACKEND_SUPPORTED,
    BACKEND_SELECTED,
    BACKEND_FIELD_COUNT
} backend_field;

static void backend_info_exec(duckdb_v2_scalar_function_exec_info_handle info,
                              duckdb_v2_context_handle context,
                              duckdb_v2_error_info_handle *error) {
    (void)context;
    duckdb_v2_error_info_handle detail = NULL;
    duckdb_v2_vector_handle output = NULL;
    duckdb_v2_vector_handle entries = NULL;
    duckdb_v2_arena_handle arena = NULL;
    duckdb_v2_vector_handle fields[BACKEND_FIELD_COUNT] = {0};
    void *field_data[BACKEND_FIELD_COUNT] = {0};
    uint64_t *field_validity[BACKEND_FIELD_COUNT] = {0};
    void *list_data = NULL;
    uint64_t *list_validity = NULL;
    uint64_t *entry_validity = NULL;
    idx_t row_count = 0;
    sassy_c_backend_status statuses[SASSY_C_BACKEND_COUNT];
    for (int backend = 0; backend < SASSY_C_BACKEND_COUNT; ++backend) {
        statuses[backend].struct_size = sizeof(statuses[backend]);
        if (sassy_c_backend_status_get((sassy_c_backend)backend, &statuses[backend]) !=
            SASSY_C_OK) {
            INPUT_ERROR(sassy_c_last_error());
        }
    }
    DUCKDB_CALL(duckdb_v2_scalar_function_exec_get_row_count(info, &row_count, &detail));
    DUCKDB_CALL(duckdb_v2_scalar_function_exec_get_result(info, &output, &detail));
    DUCKDB_CALL(duckdb_v2_vector_flatten(output, &detail));
    DUCKDB_CALL(duckdb_v2_vector_set_size(output, row_count, &detail));
    DUCKDB_CALL(duckdb_v2_vector_get_data_mutable(output, &list_data, &detail));
    DUCKDB_CALL(duckdb_v2_vector_flat_get_validity_mutable(output, &list_validity, &detail));
    DUCKDB_CALL(duckdb_v2_vector_get_child(output, 0, &entries, &detail));
    idx_t entry_count = row_count * SASSY_C_BACKEND_COUNT;
    DUCKDB_CALL(duckdb_v2_vector_set_size(entries, entry_count, &detail));
    DUCKDB_CALL(duckdb_v2_vector_flat_get_validity_mutable(entries, &entry_validity, &detail));
    for (idx_t field = 0; field < BACKEND_FIELD_COUNT; ++field) {
        DUCKDB_CALL(duckdb_v2_vector_get_child(entries, field, &fields[field], &detail));
        DUCKDB_CALL(duckdb_v2_vector_set_size(fields[field], entry_count, &detail));
        DUCKDB_CALL(duckdb_v2_vector_get_data_mutable(fields[field], &field_data[field], &detail));
        DUCKDB_CALL(duckdb_v2_vector_flat_get_validity_mutable(fields[field],
                                                               &field_validity[field], &detail));
    }
    DUCKDB_CALL(duckdb_v2_vector_get_arena(fields[BACKEND_NAME], &arena, &detail));
    for (idx_t row = 0; row < row_count; ++row) {
        idx_t offset = row * SASSY_C_BACKEND_COUNT;
        ((duckdb_v2_list_entry *)list_data)[row] =
            (duckdb_v2_list_entry){offset, SASSY_C_BACKEND_COUNT};
        mark_valid(list_validity, row);
        for (int backend = 0; backend < SASSY_C_BACKEND_COUNT; ++backend) {
            idx_t position = offset + (idx_t)backend;
            const char *name = sassy_c_backend_name((sassy_c_backend)backend);
            duckdb_v2_bytes *name_output = &((duckdb_v2_bytes *)field_data[BACKEND_NAME])[position];
            DUCKDB_CALL(
                write_bytes(arena, name_output, (const uint8_t *)name, strlen(name), &detail));
            ((bool *)field_data[BACKEND_COMPILED])[position] = statuses[backend].compiled != 0;
            ((bool *)field_data[BACKEND_SUPPORTED])[position] = statuses[backend].supported != 0;
            ((bool *)field_data[BACKEND_SELECTED])[position] = statuses[backend].selected != 0;
            mark_valid(entry_validity, position);
            for (idx_t field = 0; field < BACKEND_FIELD_COUNT; ++field) {
                mark_valid(field_validity[field], position);
            }
        }
    }
cleanup:
    (void)duckdb_v2_error_info_destroy(&detail);
}

static bool register_backend_info(duckdb_v2_extension_handle extension,
                                  duckdb_v2_context_handle context,
                                  duckdb_v2_error_info_handle *error) {
    duckdb_v2_scalar_function_handle function = NULL;
    duckdb_v2_function_signature_handle signature = NULL;
    duckdb_v2_logical_type_handle type = NULL;
    duckdb_v2_error_info_handle detail = NULL;
    bool success = false;
    duckdb_v2_str name = string_view("__sassy_backend_info");
    DUCKDB_CALL(duckdb_v2_scalar_function_create_with_extension(extension, &function, &detail));
    DUCKDB_CALL(duckdb_v2_scalar_function_set_name(function, &name, &detail));
    DUCKDB_CALL(duckdb_v2_scalar_function_get_signature(function, &signature, &detail));
    DUCKDB_CALL(duckdb_v2_context_create_type_from_text(
        context,
        string_view(
            "STRUCT(name VARCHAR, compiled BOOLEAN, supported BOOLEAN, selected BOOLEAN)[]"),
        &type, &detail));
    DUCKDB_CALL(duckdb_v2_function_signature_set_return_type(signature, type, &detail));
    DUCKDB_CALL(duckdb_v2_scalar_function_set_property(
        function, DUCKDB_V2_FUNCTION_PROPERTY_STABILITY,
        DUCKDB_V2_FUNCTION_PROPERTY_STABILITY_VOLATILE, &detail));
    DUCKDB_CALL(duckdb_v2_scalar_function_set_exec_callback(function, backend_info_exec, &detail));
    DUCKDB_CALL(duckdb_v2_scalar_function_register(function, &detail));
    success = true;
cleanup:
    (void)duckdb_v2_logical_type_destroy(&type);
    (void)duckdb_v2_scalar_function_destroy(&function);
    (void)duckdb_v2_error_info_destroy(&detail);
    return success;
}

DUCKDB_EXTENSION_ENTRYPOINT(duckdb_v2_extension_handle extension, duckdb_v2_context_handle context,
                            duckdb_v2_error_info_handle *error) {
    if (sassy_c_abi_version() != SASSY_C_ABI_VERSION) {
        set_error(*error, DUCKDB_V2_ERROR_INPUT_INVALID,
                  "ducksassy: incompatible Sassy C library ABI");
        return;
    }
    if (!register_backend_info(extension, context, error)) {
        return;
    }
    for (size_t index = 0; index < sizeof(operations) / sizeof(operations[0]); ++index) {
        if (!register_operation(extension, context, &operations[index], "VARCHAR", error)) {
            return;
        }
        if (!register_operation(extension, context, &operations[index], "BLOB", error)) {
            return;
        }
    }
}
