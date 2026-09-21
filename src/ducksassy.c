/* DuckDB C API v2 adapter. The Rust library includes no DuckDB headers/crates. */
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
#error "ducksassy requires the DuckDB C API v2 SDK; no v1 fallback is supported"
#endif
/* ENTRYPOINT below defines the vtable; helpers above it need only its declaration. */
DUCKDB_EXTENSION_EXTERN
#define CHUNK_HIT_LIMIT UINT64_C(1048576)
#define PANEL_LIMIT 4096
#define NARGS 8
#define NFIELDS 8

typedef struct { const char *name; int mode; bool many; } operation;
static const operation operations[] = {
    {"__sassy_matches", 0, false}, {"__sassy_matches_many", 0, true},
    {"__sassy_count", 1, false}, {"__sassy_count_many", 1, true},
    {"__sassy_contains", 2, false}, {"__sassy_contains_many", 2, true}
};
typedef struct {
    sassy_c_searcher *engines[3][2];
    sassy_c_slice *patterns;
    size_t pattern_capacity;
} worker;
static duckdb_v2_str str(const char *s) {
    duckdb_v2_str out = {s, (idx_t)strlen(s)};
    return out;
}
/* Callback slots are borrowed LIVE handles. Fallible API calls get a separate
 * owned error slot, never the callback slot that they would replace. */
static void message(duckdb_v2_error_info_handle target, DUCKDB_V2_ERROR code, const char *text) {
    (void)duckdb_v2_error_info_set_code(target, code);
    (void)duckdb_v2_error_info_set_text(target, str(text));
}
static void propagate(duckdb_v2_error_info_handle target, DUCKDB_V2_ERROR code,
                      duckdb_v2_error_info_handle source) {
    duckdb_v2_str text = str("ducksassy: DuckDB C API v2 call failed");
    if (source) (void)duckdb_v2_error_info_get_text(source, &text);
    (void)duckdb_v2_error_info_set_code(target, code);
    (void)duckdb_v2_error_info_set_text(target, text);
}
#define CALL(expression) do { \
    status = (expression); \
    if (status != DUCKDB_V2_ERROR_NONE) { propagate(*err, status, detail); goto fail; } \
} while (0)
#define INPUT_ERROR(text) do { message(*err, DUCKDB_V2_ERROR_INPUT_INVALID, text); goto fail; } while (0)
static idx_t physical(const duckdb_v2_vector_view *v, idx_t row) { return v->sel ? v->sel[row] : row; }
static bool valid(const duckdb_v2_vector_view *v, idx_t row) {
    idx_t p = physical(v, row);
    return !v->validity || (v->validity[p >> 6] & (UINT64_C(1) << (p & 63))) != 0;
}
static void mark_valid(uint64_t *mask, idx_t row) { mask[row >> 6] |= UINT64_C(1) << (row & 63); }
static sassy_c_slice byte_span(const duckdb_v2_vector_view *v, idx_t row) {
    const duckdb_v2_bytes *b = &((const duckdb_v2_bytes *)v->data)[physical(v, row)];
    sassy_c_slice s;
    s.len = b->value.inlined.length;
    s.data = (const uint8_t *)(s.len <= 12 ? b->value.inlined.inlined : b->value.pointer.ptr);
    return s;
}
static bool equal_label(sassy_c_slice s, const char *label) {
    size_t n = strlen(label);
    if (s.len != n) return false;
    for (size_t i = 0; i < n; ++i)
        if (tolower((unsigned char)s.data[i]) != (unsigned char)label[i]) return false;
    return true;
}
static int64_t integer_at(const duckdb_v2_vector_view *v, idx_t row) {
    return ((const int64_t *)v->data)[physical(v, row)];
}
static bool bool_at(const duckdb_v2_vector_view *v, idx_t row) {
    return ((const bool *)v->data)[physical(v, row)];
}
static DUCKDB_V2_ERROR write_bytes(duckdb_v2_arena_handle arena, duckdb_v2_bytes *out,
                                  const uint8_t *bytes, size_t len,
                                  duckdb_v2_error_info_handle *detail) {
    memset(out, 0, sizeof(*out));
    if (len > UINT32_MAX) return DUCKDB_V2_ERROR_INPUT_INVALID;
    out->value.inlined.length = (uint32_t)len;
    if (len <= 12) {
        if (len) memcpy(out->value.inlined.inlined, bytes, len);
        return DUCKDB_V2_ERROR_NONE;
    }
    uint8_t *target = NULL;
    DUCKDB_V2_ERROR code = duckdb_v2_arena_allocate(arena, (idx_t)len, &target, detail);
    if (code != DUCKDB_V2_ERROR_NONE) return code;
    memcpy(target, bytes, len);
    memcpy(out->value.pointer.prefix, bytes, 4);
    out->value.pointer.ptr = (char *)target;
    return DUCKDB_V2_ERROR_NONE;
}
static void worker_destroy(void *ptr) {
    worker *w = (worker *)ptr;
    if (!w) return;
    for (int a = 0; a < 3; ++a)
        for (int r = 0; r < 2; ++r) sassy_c_searcher_free(w->engines[a][r]);
    free(w->patterns);
    free(w);
}
static void scalar_init(duckdb_v2_scalar_function_init_info_handle info,
                        duckdb_v2_context_handle context, duckdb_v2_error_info_handle *err) {
    (void)context;
    worker *w = (worker *)calloc(1, sizeof(*w));
    if (!w) { message(*err, DUCKDB_V2_ERROR_INPUT_INVALID, "ducksassy: worker allocation failed"); return; }
    duckdb_v2_opaque state = {w, worker_destroy, NULL};
    duckdb_v2_error_info_handle detail = NULL;
    DUCKDB_V2_ERROR status = duckdb_v2_scalar_function_init_set_init_data(info, &state, &detail);
    if (status != DUCKDB_V2_ERROR_NONE) {
        propagate(*err, status, detail);
        worker_destroy(w);
    }
    (void)duckdb_v2_error_info_destroy(&detail);
}
static void scalar_exec(duckdb_v2_scalar_function_exec_info_handle info,
                        duckdb_v2_context_handle context, duckdb_v2_error_info_handle *err) {
    (void)context;
    DUCKDB_V2_ERROR status;
    duckdb_v2_error_info_handle detail = NULL;
    duckdb_v2_vector_handle args[NARGS] = {0}, output = NULL, pattern_child = NULL, hit_struct = NULL;
    duckdb_v2_vector_view views[NARGS], pattern_view;
    sassy_c_result *result = NULL;
    const operation *op = NULL;
    worker *w = NULL;
    void *opaque = NULL, *output_data = NULL;
    uint64_t *output_validity = NULL;
    idx_t rows = 0, total_hits = 0;
    CALL(duckdb_v2_scalar_function_exec_get_user_data(info, &opaque, &detail));
    op = (const operation *)opaque;
    opaque = NULL;
    CALL(duckdb_v2_scalar_function_exec_get_init_data(info, &opaque, &detail));
    w = (worker *)opaque;
    if (!op || !w) INPUT_ERROR("ducksassy: missing function/worker state");
    CALL(duckdb_v2_scalar_function_exec_get_row_count(info, &rows, &detail));
    /* Flatten ALL inputs before acquiring views: a later aliased dictionary
     * must not invalidate an earlier view. String payloads remain borrowed. */
    for (uint32_t i = 0; i < NARGS; ++i) {
        CALL(duckdb_v2_scalar_function_exec_get_arg(info, i, &args[i], &detail));
        CALL(duckdb_v2_vector_flatten(args[i], &detail));
    }
    if (op->many) {
        CALL(duckdb_v2_vector_get_child(args[0], 0, &pattern_child, &detail));
        CALL(duckdb_v2_vector_flatten(pattern_child, &detail));
    }
    for (uint32_t i = 0; i < NARGS; ++i)
        CALL(duckdb_v2_vector_get_view(args[i], &views[i], &detail));
    if (op->many) CALL(duckdb_v2_vector_get_view(pattern_child, &pattern_view, &detail));
    CALL(duckdb_v2_scalar_function_exec_get_result(info, &output, &detail));
    CALL(duckdb_v2_vector_flatten(output, &detail));
    CALL(duckdb_v2_vector_set_size(output, rows, &detail));
    CALL(duckdb_v2_vector_get_data_mutable(output, &output_data, &detail));
    CALL(duckdb_v2_vector_flat_get_validity_mutable(output, &output_validity, &detail));
    if (op->mode == 0) {
        CALL(duckdb_v2_vector_get_child(output, 0, &hit_struct, &detail));
        CALL(duckdb_v2_vector_set_size(hit_struct, 0, &detail));
    }
    for (idx_t row = 0; row < rows; ++row) {
        bool row_valid = true;
        for (int i = 0; i < NARGS; ++i) row_valid = row_valid && valid(&views[i], row);
        if (!row_valid) {
            if (op->mode == 0) ((duckdb_v2_list_entry *)output_data)[row] = (duckdb_v2_list_entry){0, 0};
            CALL(duckdb_v2_vector_set_null(output, row, &detail));
            continue;
        }
        int64_t k = integer_at(&views[2], row);
        int64_t max_hits = integer_at(&views[6], row), max_bytes = integer_at(&views[7], row);
        if (k < 0 || (uint64_t)k > UINT32_MAX || max_hits <= 0 || max_bytes <= 0)
            INPUT_ERROR("ducksassy: k must be nonnegative and resource limits must be positive");
        sassy_c_slice alphabet = byte_span(&views[3], row);
        int a = equal_label(alphabet, "ascii") ? 0 : equal_label(alphabet, "dna") ? 1 : equal_label(alphabet, "iupac") ? 2 : -1;
        if (a < 0) INPUT_ERROR("ducksassy: alphabet must be ascii, dna, or iupac");
        uint32_t rc = bool_at(&views[4], row) ? 1 : 0;
        if (!w->engines[a][rc] && sassy_c_searcher_new((uint32_t)a, rc, &w->engines[a][rc]) != 0)
            INPUT_ERROR(sassy_c_last_error());
        sassy_c_options options = {
            sizeof(sassy_c_options), bool_at(&views[5], row) ? 1U : 0U,
            op->mode == 0 ? 1U : 0U, 0, (uint64_t)max_hits, (uint64_t)max_bytes
        };
        sassy_c_slice text = byte_span(&views[1], row), one;
        const sassy_c_slice *patterns = &one;
        size_t count = 1;
        if (op->many) {
            duckdb_v2_list_entry entry = ((const duckdb_v2_list_entry *)views[0].data)[physical(&views[0], row)];
            if (entry.length > PANEL_LIMIT || entry.offset > pattern_view.count || entry.length > pattern_view.count - entry.offset)
                INPUT_ERROR("ducksassy: invalid panel bounds or more than 4096 patterns");
            count = (size_t)entry.length;
            if (count > w->pattern_capacity) {
                sassy_c_slice *p = (sassy_c_slice *)realloc(w->patterns, count * sizeof(*p));
                if (!p) INPUT_ERROR("ducksassy: pattern descriptor allocation failed");
                w->patterns = p;
                w->pattern_capacity = count;
            }
            for (size_t j = 0; j < count; ++j) {
                idx_t index = entry.offset + j;
                if (!valid(&pattern_view, index)) INPUT_ERROR("ducksassy: a pattern panel cannot contain NULL elements");
                w->patterns[j] = byte_span(&pattern_view, index);
            }
            patterns = w->patterns;
        } else one = byte_span(&views[0], row);
        int32_t code = sassy_c_search_many(w->engines[a][rc], patterns, count, text, (uint32_t)k, &options, &result);
        if (op->many && count) memset(w->patterns, 0, count * sizeof(*w->patterns));
        if (code != SASSY_C_OK) INPUT_ERROR(sassy_c_last_error());
        const sassy_c_hit *hits = NULL;
        const uint8_t *cigars = NULL;
        size_t hit_count = 0, cigar_bytes = 0;
        if (sassy_c_result_view(result, &hits, &hit_count, &cigars, &cigar_bytes) != SASSY_C_OK)
            INPUT_ERROR(sassy_c_last_error());
        if (op->mode == 1) ((uint64_t *)output_data)[row] = (uint64_t)hit_count;
        else if (op->mode == 2) ((bool *)output_data)[row] = hit_count != 0;
        else {
            if ((uint64_t)hit_count > CHUNK_HIT_LIMIT - total_hits)
                INPUT_ERROR("ducksassy: chunk exceeds 1048576 output hits; reduce the search scope or use count/contains");
            idx_t new_size = total_hits + hit_count;
            CALL(duckdb_v2_vector_set_size(hit_struct, new_size, &detail));
            uint64_t *struct_validity = NULL;
            CALL(duckdb_v2_vector_flat_get_validity_mutable(hit_struct, &struct_validity, &detail));
            duckdb_v2_vector_handle fields[NFIELDS] = {0};
            void *data[NFIELDS] = {0};
            uint64_t *masks[NFIELDS] = {0};
            duckdb_v2_arena_handle cigar_arena = NULL;
            for (idx_t i = 0; i < NFIELDS; ++i) {
                CALL(duckdb_v2_vector_get_child(hit_struct, i, &fields[i], &detail));
                CALL(duckdb_v2_vector_set_size(fields[i], new_size, &detail));
                CALL(duckdb_v2_vector_get_data_mutable(fields[i], &data[i], &detail));
                CALL(duckdb_v2_vector_flat_get_validity_mutable(fields[i], &masks[i], &detail));
            }
            CALL(duckdb_v2_vector_get_arena(fields[7], &cigar_arena, &detail));
            for (size_t j = 0; j < hit_count; ++j) {
                idx_t pos = total_hits + j;
                const sassy_c_hit *h = &hits[j];
                ((uint64_t *)data[0])[pos] = h->pattern_idx;
                ((uint64_t *)data[1])[pos] = h->text_start;
                ((uint64_t *)data[2])[pos] = h->text_end;
                ((uint64_t *)data[3])[pos] = h->pattern_start;
                ((uint64_t *)data[4])[pos] = h->pattern_end;
                ((int32_t *)data[5])[pos] = h->cost;
                const uint8_t strand = h->strand ? '-' : '+';
                CALL(write_bytes(NULL, &((duckdb_v2_bytes *)data[6])[pos], &strand, 1, &detail));
                if (h->cigar_offset > cigar_bytes || h->cigar_length > cigar_bytes - h->cigar_offset)
                    INPUT_ERROR("ducksassy: invalid CIGAR slab bounds returned by Rust");
                const uint8_t *cigar = h->cigar_length ? cigars + h->cigar_offset : NULL;
                CALL(write_bytes(cigar_arena, &((duckdb_v2_bytes *)data[7])[pos], cigar, (size_t)h->cigar_length, &detail));
                mark_valid(struct_validity, pos);
                for (int i = 0; i < NFIELDS; ++i) mark_valid(masks[i], pos);
            }
            ((duckdb_v2_list_entry *)output_data)[row] = (duckdb_v2_list_entry){total_hits, (idx_t)hit_count};
            total_hits = new_size;
        }
        mark_valid(output_validity, row);
        sassy_c_result_free(result);
        result = NULL;
    }
fail:
    sassy_c_result_free(result);
    if (w && w->patterns) memset(w->patterns, 0, w->pattern_capacity * sizeof(*w->patterns));
    (void)duckdb_v2_error_info_destroy(&detail);
}
static bool register_operation(duckdb_v2_extension_handle extension, duckdb_v2_context_handle context,
                               const operation *op, const char *sequence_type,
                               duckdb_v2_error_info_handle *err) {
    duckdb_v2_scalar_function_handle function = NULL;
    duckdb_v2_function_signature_handle signature = NULL;
    duckdb_v2_logical_type_handle type = NULL;
    duckdb_v2_error_info_handle detail = NULL;
    DUCKDB_V2_ERROR status;
    bool ok = false;
    duckdb_v2_str name = str(op->name);
    CALL(duckdb_v2_scalar_function_create_with_extension(extension, &function, &detail));
    CALL(duckdb_v2_scalar_function_set_name(function, &name, &detail));
    CALL(duckdb_v2_scalar_function_get_signature(function, &signature, &detail));
    char pattern_type[32];
    (void)snprintf(pattern_type, sizeof(pattern_type), "%s%s", sequence_type, op->many ? "[]" : "");
    const char *types[NARGS] = {pattern_type, sequence_type, "BIGINT", "VARCHAR", "BOOLEAN", "BOOLEAN", "BIGINT", "BIGINT"};
    const char *names[NARGS] = {"pattern", "text", "k", "alphabet", "rc", "all_endpoints", "max_hits", "max_text_bytes"};
    for (int i = 0; i < NARGS; ++i) {
        CALL(duckdb_v2_context_create_type_from_text(context, str(types[i]), &type, &detail));
        CALL(duckdb_v2_function_signature_add_parameter(signature, str(names[i]), type, NULL, &detail));
        (void)duckdb_v2_logical_type_destroy(&type);
    }
    const char *return_type = op->mode == 1 ? "UBIGINT" : op->mode == 2 ? "BOOLEAN" :
        "STRUCT(pattern_idx UBIGINT, text_start UBIGINT, text_end UBIGINT, pattern_start UBIGINT, pattern_end UBIGINT, cost INTEGER, strand VARCHAR, cigar VARCHAR)[]";
    CALL(duckdb_v2_context_create_type_from_text(context, str(return_type), &type, &detail));
    CALL(duckdb_v2_function_signature_set_return_type(signature, type, &detail));
    (void)duckdb_v2_logical_type_destroy(&type);
    duckdb_v2_opaque data = {(void *)op, NULL, NULL};
    CALL(duckdb_v2_scalar_function_set_user_data(function, &data, &detail));
    CALL(duckdb_v2_scalar_function_set_property(function, DUCKDB_V2_FUNCTION_PROPERTY_NULL_HANDLING,
          DUCKDB_V2_FUNCTION_PROPERTY_NULL_HANDLING_SPECIAL, &detail));
    CALL(duckdb_v2_scalar_function_set_property(function, DUCKDB_V2_FUNCTION_PROPERTY_COLLATION_HANDLING,
          DUCKDB_V2_FUNCTION_PROPERTY_COLLATION_HANDLING_IGNORE, &detail));
    CALL(duckdb_v2_scalar_function_set_init_callback(function, scalar_init, &detail));
    CALL(duckdb_v2_scalar_function_set_exec_callback(function, scalar_exec, &detail));
    CALL(duckdb_v2_scalar_function_register(function, &detail));
    ok = true;
fail:
    (void)duckdb_v2_logical_type_destroy(&type);
    (void)duckdb_v2_scalar_function_destroy(&function);
    (void)duckdb_v2_error_info_destroy(&detail);
    return ok;
}
DUCKDB_EXTENSION_ENTRYPOINT(duckdb_v2_extension_handle extension, duckdb_v2_context_handle context,
                           duckdb_v2_error_info_handle *err) {
    if (sassy_c_abi_version() != SASSY_C_ABI_VERSION) {
        message(*err, DUCKDB_V2_ERROR_INPUT_INVALID, "ducksassy: incompatible Sassy C library ABI");
        return;
    }
    for (size_t i = 0; i < sizeof(operations) / sizeof(operations[0]); ++i) {
        if (!register_operation(extension, context, &operations[i], "VARCHAR", err)) return;
        if (!register_operation(extension, context, &operations[i], "BLOB", err)) return;
    }
}
