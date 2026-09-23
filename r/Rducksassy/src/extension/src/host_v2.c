/* DuckDB C API v2 adapter for the Sassy C library. */
#define DUCKDB_EXTENSION_NAME ducksassy
#define DUCKDB_V2_API_ALLOW_UNSTABLE 0
#define DUCKDB_V2_API_ALLOW_DEPRECATED 0
#include "duckdb_extension_v2.h"
#include "ducksassy_core.h"
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if DUCKDB_EXTENSION_HEADER_VERSION != 2 || DUCKDB_V2_API_VERSION_MAJOR != 2
#error "ducksassy requires the DuckDB C API v2 SDK"
#endif

DUCKDB_EXTENSION_EXTERN

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

typedef struct {
    duckdb_v2_vector_handle vector;
    duckdb_v2_vector_handle fields[HIT_FIELD_COUNT];
    void *data[HIT_FIELD_COUNT];
    uint64_t *validity[HIT_FIELD_COUNT];
    uint64_t *struct_validity;
    duckdb_v2_arena_handle cigar_arena;
    idx_t capacity;
    bool extended;
    duckdb_v2_vector_handle ops;
    uint32_t *op_data;
    idx_t op_size, op_capacity;
} hit_output;

static bool resize_hit_output(hit_output *output, idx_t size,
                              duckdb_v2_error_info_handle *error) {
    duckdb_v2_error_info_handle detail = NULL;
    bool success = false;
    DUCKDB_CALL(duckdb_v2_vector_set_size(output->vector, size, &detail));
    DUCKDB_CALL(duckdb_v2_vector_flat_get_validity_mutable(output->vector,
                                                          &output->struct_validity, &detail));
    // Resizing can move storage. Refresh every borrowed pointer and the arena.
    for (idx_t field = 0; field < (output->extended ? HIT_FIELD_COUNT : HIT_CIGAR_OPS); ++field) {
        DUCKDB_CALL(duckdb_v2_vector_get_child(output->vector, field,
                                               &output->fields[field], &detail));
        DUCKDB_CALL(duckdb_v2_vector_set_size(output->fields[field], size, &detail));
        DUCKDB_CALL(duckdb_v2_vector_get_data_mutable(output->fields[field],
                                                      &output->data[field], &detail));
        DUCKDB_CALL(duckdb_v2_vector_flat_get_validity_mutable(output->fields[field],
                                                               &output->validity[field], &detail));
    }
    DUCKDB_CALL(duckdb_v2_vector_get_arena(output->fields[HIT_CIGAR],
                                           &output->cigar_arena, &detail));
    output->capacity = size;
    success = true;
cleanup:
    (void)duckdb_v2_error_info_destroy(&detail);
    return success;
}

static bool append_hits(hit_output *output, const hit_batch_view *batch, idx_t offset,
                        duckdb_v2_error_info_handle *error) {
    duckdb_v2_error_info_handle detail = NULL;
    bool success = false;
    if (!batch->hit_count) return true;
    idx_t required = offset + batch->hit_count;
    if (required > output->capacity) {
        idx_t capacity = output->capacity ? output->capacity : 2048;
        while (capacity < required) {
            capacity *= 2;
        }
        if (!resize_hit_output(output, capacity, error)) {
            goto cleanup;
        }
    }
    if (batch->packed) {
        if (batch->op_count > UINT64_MAX - output->op_size) INPUT_ERROR("ducksassy: packed CIGAR size overflow");
        idx_t needed = output->op_size + batch->op_count;
        if (needed > output->op_capacity) {
            idx_t capacity = output->op_capacity ? output->op_capacity : 2048;
            while (capacity < needed) {
                if (capacity > UINT64_MAX / 2) { capacity = needed; break; }
                capacity *= 2;
            }
            DUCKDB_CALL(duckdb_v2_vector_get_child(output->fields[HIT_CIGAR_OPS], 0, &output->ops, &detail));
            DUCKDB_CALL(duckdb_v2_vector_set_size(output->ops, capacity, &detail));
            DUCKDB_CALL(duckdb_v2_vector_get_data_mutable(output->ops, (void **)&output->op_data, &detail));
            uint64_t *validity = NULL;
            DUCKDB_CALL(duckdb_v2_vector_flat_get_validity_mutable(output->ops, &validity, &detail));
            memset(validity, 0xFF, ((capacity + 63) / 64) * sizeof(*validity));
            output->op_capacity = capacity;
        }
        if (batch->op_count) memcpy(output->op_data + output->op_size, batch->ops,
                                    batch->op_count * sizeof(*batch->ops));
    }
    void **field_data = output->data;
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
        if (batch->text) {
            const uint8_t *cigar = hit->cigar_length ? batch->cigars + hit->cigar_offset : NULL;
            duckdb_v2_bytes *cigar_output = &((duckdb_v2_bytes *)field_data[HIT_CIGAR])[position];
            DUCKDB_CALL(write_bytes(output->cigar_arena, cigar_output, cigar, (size_t)hit->cigar_length, &detail));
        }
        mark_valid(output->struct_validity, position);
        for (idx_t field = 0; field < (output->extended ? HIT_FIELD_COUNT : HIT_CIGAR_OPS); ++field) {
            mark_valid(output->validity[field], position);
        }
        if (!batch->text) output->validity[HIT_CIGAR][position >> 6] &= ~(UINT64_C(1) << (position & 63));
        if (output->extended) {
            sassy_c_op_span span = batch->packed ? batch->spans[index] : (sassy_c_op_span){0, 0};
            ((duckdb_v2_list_entry *)field_data[HIT_CIGAR_OPS])[position] =
                (duckdb_v2_list_entry){output->op_size + span.offset, span.length};
            if (!batch->packed) output->validity[HIT_CIGAR_OPS][position >> 6] &= ~(UINT64_C(1) << (position & 63));
        }
    }
    output->op_size += batch->op_count;
    success = true;
cleanup:
    (void)duckdb_v2_error_info_destroy(&detail);
    return success;
}

typedef struct {
    duckdb_v2_vector_view *views;
    search_worker *worker;
    const search_operation *operation;
    duckdb_v2_vector_handle output;
    void *data;
    uint64_t *validity;
    hit_output *hits;
    duckdb_v2_error_info_handle *error;
} scalar_context;

static bool input_valid(void *pointer, unsigned argument, uint64_t row) {
    return row_is_valid(&((scalar_context *)pointer)->views[argument], row);
}
static sassy_c_slice input_string(void *pointer, unsigned argument, uint64_t row) {
    return byte_span(&((scalar_context *)pointer)->views[argument], row);
}
static int64_t input_integer(void *pointer, unsigned argument, uint64_t row) {
    return integer_at(&((scalar_context *)pointer)->views[argument], row);
}
static bool input_boolean(void *pointer, unsigned argument, uint64_t row) {
    return boolean_at(&((scalar_context *)pointer)->views[argument], row);
}
static double input_real(void *pointer, unsigned argument, uint64_t row) {
    const duckdb_v2_vector_view *view = &((scalar_context *)pointer)->views[argument];
    return ((const double *)view->data)[physical_row(view, row)];
}
static panel_entry input_list(void *pointer, uint64_t row) {
    scalar_context *context = pointer;
    const duckdb_v2_vector_view *view = &context->views[ARG_PATTERN];
    duckdb_v2_list_entry entry = ((const duckdb_v2_list_entry *)view->data)[physical_row(view, row)];
    return (panel_entry){entry.offset, entry.length, context->views[ARG_PANEL_CHILD].count};
}
static bool output_hits(void *pointer, const hit_batch_view *batch, uint64_t offset) {
    scalar_context *context = pointer;
    return append_hits(context->hits, batch, offset, context->error);
}
static bool output_result(void *pointer, uint64_t row, bool valid, uint64_t offset, uint64_t count) {
    scalar_context *context = pointer;
    duckdb_v2_error_info_handle detail = NULL;
    duckdb_v2_error_info_handle *error = context->error;
    if (context->operation->kind == OP_MATCHES || context->operation->kind == OP_CRISPR) {
        ((duckdb_v2_list_entry *)context->data)[row] = (duckdb_v2_list_entry){offset, count};
    } else if (valid && context->operation->kind == OP_COUNT) {
        ((uint64_t *)context->data)[row] = count;
    } else if (valid) {
        ((bool *)context->data)[row] = count != 0;
    }
    if (valid) mark_valid(context->validity, row);
    else DUCKDB_CALL(duckdb_v2_vector_set_null(context->output, row, &detail));
    (void)duckdb_v2_error_info_destroy(&detail);
    return true;
cleanup:
    (void)duckdb_v2_error_info_destroy(&detail);
    return false;
}
static search_worker *input_worker(void *pointer) {
    return ((scalar_context *)pointer)->worker;
}
static void input_error(void *pointer, const char *message) {
    set_error(*((scalar_context *)pointer)->error, DUCKDB_V2_ERROR_INPUT_INVALID, message);
}
static const search_host host = {
    input_valid, input_string, input_integer, input_boolean, input_real, input_list,
    output_hits, output_result, input_worker, input_error
};

static void scalar_exec(duckdb_v2_scalar_function_exec_info_handle info,
                        duckdb_v2_context_handle context, duckdb_v2_error_info_handle *error) {
    (void)context;
    duckdb_v2_error_info_handle detail = NULL;
    duckdb_v2_vector_handle arguments[CRISPR_ARGUMENT_COUNT] = {0};
    duckdb_v2_vector_handle output = NULL;
    duckdb_v2_vector_handle pattern_child = NULL;
    duckdb_v2_vector_handle hit_struct = NULL;
    duckdb_v2_vector_view views[CRISPR_ARGUMENT_COUNT + 1];
    search_worker *worker = NULL;
    void *user_data = NULL;
    void *init_data = NULL;
    void *output_data = NULL;
    uint64_t *output_validity = NULL;
    idx_t row_count = 0;
    idx_t total_hits = 0;
    hit_output hits = {0};

    DUCKDB_CALL(duckdb_v2_scalar_function_exec_get_user_data(info, &user_data, &detail));
    const search_operation *operation = (const search_operation *)user_data;
    DUCKDB_CALL(duckdb_v2_scalar_function_exec_get_init_data(info, &init_data, &detail));
    worker = (search_worker *)init_data;
    if (!operation || !worker) {
        INPUT_ERROR("ducksassy: missing function/worker state");
    }
    bool crispr = operation->kind == OP_CRISPR;
    bool output_hits = operation->kind == OP_MATCHES || crispr;
    hits.extended = operation->kind == OP_MATCHES;
    uint32_t argument_count = crispr ? CRISPR_ARGUMENT_COUNT :
        hits.extended ? SEARCH_ARGUMENT_COUNT : SEARCH_BASE_ARGUMENT_COUNT;
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
        DUCKDB_CALL(duckdb_v2_vector_get_view(pattern_child, &views[ARG_PANEL_CHILD], &detail));
    }
    DUCKDB_CALL(duckdb_v2_scalar_function_exec_get_result(info, &output, &detail));
    DUCKDB_CALL(duckdb_v2_vector_flatten(output, &detail));
    DUCKDB_CALL(duckdb_v2_vector_set_size(output, row_count, &detail));
    DUCKDB_CALL(duckdb_v2_vector_get_data_mutable(output, &output_data, &detail));
    DUCKDB_CALL(duckdb_v2_vector_flat_get_validity_mutable(output, &output_validity, &detail));
    if (output_hits) {
        DUCKDB_CALL(duckdb_v2_vector_get_child(output, 0, &hit_struct, &detail));
        DUCKDB_CALL(duckdb_v2_vector_set_size(hit_struct, 0, &detail));
        hits.vector = hit_struct;
    }

    scalar_context execution = {views, worker, operation, output, output_data,
                                output_validity, &hits, error};
    if (!search_execute(operation, &host, &execution, row_count, &total_hits)) goto cleanup;
    /* Capacity is private to this callback; expose only initialized hits. */
    if (output_hits && !resize_hit_output(&hits, total_hits, error)) goto cleanup;
    if (hits.extended) {
        DUCKDB_CALL(duckdb_v2_vector_get_child(hits.fields[HIT_CIGAR_OPS], 0, &hits.ops, &detail));
        DUCKDB_CALL(duckdb_v2_vector_set_size(hits.ops, hits.op_size, &detail));
    }
cleanup:
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
                                                [ARG_MAX_N_FRACTION] = "DOUBLE"};
    const char *names[CRISPR_ARGUMENT_COUNT] = {[ARG_PATTERN] = "pattern",
                                                [ARG_TEXT] = "text",
                                                [ARG_MAX_EDITS] = "k",
                                                [ARG_ALPHABET] = "alphabet",
                                                [ARG_REVERSE_COMPLEMENT] = "rc",
                                                [ARG_ALL_ENDPOINTS] = "all_endpoints",
                                                [ARG_MAX_N_FRACTION] = "max_n_frac"};
    uint32_t argument_count = SEARCH_BASE_ARGUMENT_COUNT;
    if (operation->kind == OP_MATCHES) {
        argument_count = SEARCH_ARGUMENT_COUNT;
        types[ARG_CIGAR_FORMAT] = "VARCHAR";
        names[ARG_CIGAR_FORMAT] = "cigar_format";
    }
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
    if (operation->kind == OP_MATCHES) {
        return_type = "STRUCT(pattern_idx UBIGINT, text_start UBIGINT, text_end UBIGINT, "
                      "pattern_start UBIGINT, pattern_end UBIGINT, cost INTEGER, strand "
                      "VARCHAR, cigar VARCHAR, cigar_ops UINTEGER[])[]";
    } else if (operation->kind == OP_COUNT) {
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

typedef struct {
    duckdb_v2_value_handle pattern_value;
    duckdb_v2_value_handle text_value;
    grep_input input;
} grep_bind_data;

static void grep_bind_destroy(void *pointer) {
    grep_bind_data *data = (grep_bind_data *)pointer;
    if (data) {
        (void)duckdb_v2_value_destroy(&data->pattern_value);
        (void)duckdb_v2_value_destroy(&data->text_value);
        free(data);
    }
}

static void grep_bind(duckdb_v2_table_function_bind_info_handle info,
                      duckdb_v2_context_handle context, duckdb_v2_error_info_handle *error) {
    duckdb_v2_error_info_handle detail = NULL;
    duckdb_v2_value_handle pattern_value = NULL;
    duckdb_v2_value_handle text_value = NULL;
    duckdb_v2_value_handle k_value = NULL;
    duckdb_v2_logical_type_handle types[GREP_COLUMN_COUNT] = {0};
    grep_bind_data *data = NULL;
    bool owned = false;
    duckdb_v2_str pattern;
    duckdb_v2_str text;
    int64_t k = 0;
    duckdb_v2_value_handle *arguments[] = {&pattern_value, &text_value, &k_value};
    const char *names[GREP_COLUMN_COUNT] = {"text_start", "text_end", "cost", "cigar"};
    const char *type_names[GREP_COLUMN_COUNT] = {"UBIGINT", "UBIGINT", "INTEGER", "VARCHAR"};
    for (idx_t argument = 0; argument < 3; ++argument) {
        DUCKDB_CALL(duckdb_v2_table_function_bind_get_arg_value(
            info, argument, arguments[argument], &detail));
        bool is_null = false;
        DUCKDB_CALL(duckdb_v2_value_is_null(*arguments[argument], &is_null, &detail));
        if (is_null) {
            INPUT_ERROR("sassy_grep: arguments cannot be NULL");
        }
    }
    DUCKDB_CALL(duckdb_v2_value_get_varchar(pattern_value, &pattern, &detail));
    DUCKDB_CALL(duckdb_v2_value_get_varchar(text_value, &text, &detail));
    DUCKDB_CALL(duckdb_v2_value_get_bigint(k_value, &k, &detail));
    if (k < 0 || k > UINT32_MAX) {
        INPUT_ERROR("sassy_grep: pattern must contain 1..4096 bytes and 0 <= k < pattern length");
    }
    grep_input input = {{(const uint8_t *)pattern.ptr, (size_t)pattern.len},
                        {(const uint8_t *)text.ptr, (size_t)text.len}, (uint32_t)k};
    const char *message = NULL;
    if (!grep_validate(&input, &message)) INPUT_ERROR(message);
    data = (grep_bind_data *)calloc(1, sizeof(*data));
    if (!data) {
        INPUT_ERROR("sassy_grep: allocation failed");
    }
    data->input = input;
    data->pattern_value = pattern_value;
    data->text_value = text_value;
    pattern_value = NULL;
    text_value = NULL;
    for (idx_t i = 0; i < GREP_COLUMN_COUNT; ++i) {
        DUCKDB_CALL(duckdb_v2_context_create_type_from_text(context, string_view(type_names[i]),
                                                              &types[i], &detail));
        DUCKDB_CALL(duckdb_v2_table_function_bind_add_result_column(
            info, string_view(names[i]), types[i], &detail));
    }
    duckdb_v2_opaque opaque = {data, grep_bind_destroy, NULL};
    DUCKDB_CALL(duckdb_v2_table_function_bind_set_bind_data(info, &opaque, &detail));
    owned = true;
cleanup:
    if (!owned) {
        grep_bind_destroy(data);
    }
    (void)duckdb_v2_value_destroy(&pattern_value);
    (void)duckdb_v2_value_destroy(&text_value);
    (void)duckdb_v2_value_destroy(&k_value);
    for (idx_t i = 0; i < GREP_COLUMN_COUNT; ++i) {
        (void)duckdb_v2_logical_type_destroy(&types[i]);
    }
    (void)duckdb_v2_error_info_destroy(&detail);
}

static void grep_init(duckdb_v2_table_function_init_global_info_handle info,
                      duckdb_v2_context_handle context, duckdb_v2_error_info_handle *error) {
    (void)context;
    duckdb_v2_error_info_handle detail = NULL;
    grep_state *state = (grep_state *)calloc(1, sizeof(*state));
    bool owned = false;
    if (!state) {
        set_error(*error, DUCKDB_V2_ERROR_INPUT_INVALID, "sassy_grep: allocation failed");
        return;
    }
    if (sassy_c_searcher_new(SASSY_C_ASCII, 0, &state->searcher) != SASSY_C_OK) {
        INPUT_ERROR(sassy_c_last_error());
    }
    duckdb_v2_opaque opaque = {state, grep_state_destroy, NULL};
    DUCKDB_CALL(duckdb_v2_table_function_init_global_set_global_state(info, &opaque, &detail));
    owned = true;
cleanup:
    if (!owned) {
        grep_state_destroy(state);
    }
    (void)duckdb_v2_error_info_destroy(&detail);
}

static void grep_exec(duckdb_v2_table_function_exec_info_handle info,
                      duckdb_v2_context_handle context, duckdb_v2_error_info_handle *error) {
    (void)context;
    duckdb_v2_error_info_handle detail = NULL;
    grep_bind_data *data = NULL;
    grep_state *state = NULL;
    duckdb_v2_data_chunk_handle chunk = NULL;
    duckdb_v2_vector_handle columns[GREP_COLUMN_COUNT] = {0};
    void *output[GREP_COLUMN_COUNT] = {0};
    duckdb_v2_arena_handle arena = NULL;
    idx_t count = 0;
    DUCKDB_CALL(duckdb_v2_table_function_exec_get_bind_data(info, (void **)&data, &detail));
    DUCKDB_CALL(duckdb_v2_table_function_exec_get_global_state(info, (void **)&state, &detail));
    DUCKDB_CALL(duckdb_v2_table_function_exec_get_output_chunk(info, &chunk, &detail));
    if (!data || !state) {
        INPUT_ERROR("sassy_grep: missing scan state");
    }
    for (idx_t i = 0; i < GREP_COLUMN_COUNT; ++i) {
        DUCKDB_CALL(duckdb_v2_data_chunk_get_vector(chunk, i, &columns[i], &detail));
        DUCKDB_CALL(duckdb_v2_vector_get_data_mutable(columns[i], &output[i], &detail));
    }
    DUCKDB_CALL(duckdb_v2_vector_get_arena(columns[GREP_CIGAR], &arena, &detail));
    while (count < GREP_OUTPUT_ROWS) {
        sassy_c_hit hit;
        const uint8_t *cigar = NULL;
        const char *message = NULL;
        int next = grep_next(&data->input, state, &hit, &cigar, &message);
        if (next < 0) INPUT_ERROR(message);
        if (next == 0 || (next == 2 && count > 0)) break;
        if (next == 2) continue;
        ((uint64_t *)output[GREP_TEXT_START])[count] = hit.text_start;
        ((uint64_t *)output[GREP_TEXT_END])[count] = hit.text_end;
        ((int32_t *)output[GREP_COST])[count] = hit.cost;
        DUCKDB_CALL(write_bytes(arena, &((duckdb_v2_bytes *)output[GREP_CIGAR])[count],
                                cigar, (size_t)hit.cigar_length, &detail));
        count++;
    }
    DUCKDB_CALL(duckdb_v2_vector_set_size(columns[GREP_TEXT_START], count, &detail));
cleanup:
    (void)duckdb_v2_error_info_destroy(&detail);
}

static bool register_grep(duckdb_v2_extension_handle extension,
                          duckdb_v2_context_handle context, duckdb_v2_error_info_handle *error) {
    duckdb_v2_error_info_handle detail = NULL;
    duckdb_v2_table_function_handle function = NULL;
    duckdb_v2_function_signature_handle signature = NULL;
    duckdb_v2_logical_type_handle types[2] = {0};
    bool success = false;
    DUCKDB_CALL(duckdb_v2_table_function_create_with_extension(extension, &function, &detail));
    duckdb_v2_str name = string_view("sassy_grep");
    DUCKDB_CALL(duckdb_v2_table_function_set_name(function, &name, &detail));
    DUCKDB_CALL(duckdb_v2_table_function_get_signature(function, &signature, &detail));
    DUCKDB_CALL(duckdb_v2_context_create_type_from_text(context, string_view("VARCHAR"),
                                                          &types[0], &detail));
    DUCKDB_CALL(duckdb_v2_context_create_type_from_text(context, string_view("BIGINT"),
                                                          &types[1], &detail));
    DUCKDB_CALL(duckdb_v2_function_signature_add_parameter(
        signature, string_view("pattern"), types[0], NULL, &detail));
    DUCKDB_CALL(duckdb_v2_function_signature_add_parameter(
        signature, string_view("text"), types[0], NULL, &detail));
    DUCKDB_CALL(duckdb_v2_function_signature_add_parameter(
        signature, string_view("k"), types[1], NULL, &detail));
    DUCKDB_CALL(duckdb_v2_table_function_set_bind_callback(function, grep_bind, &detail));
    DUCKDB_CALL(duckdb_v2_table_function_set_init_global_callback(function, grep_init, &detail));
    DUCKDB_CALL(duckdb_v2_table_function_set_exec_callback(function, grep_exec, &detail));
    DUCKDB_CALL(duckdb_v2_table_function_register(function, &detail));
    success = true;
cleanup:
    for (idx_t i = 0; i < 2; ++i) {
        (void)duckdb_v2_logical_type_destroy(&types[i]);
    }
    (void)duckdb_v2_table_function_destroy(&function);
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
    if (!register_grep(extension, context, error)) {
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
