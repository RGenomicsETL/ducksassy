#include "duckdb_extension.h"
#include "ducksassy_core.h"
#if defined(__EMSCRIPTEN__) && !defined(__EMSCRIPTEN_PTHREADS__)
#define SASSY_SINGLE_THREADED
#elif defined(_WIN32)
#include <windows.h>
#else
#include <pthread.h>
#endif
#include <stdlib.h>
#include <string.h>
DUCKDB_EXTENSION_EXTERN

/* Stable v1 has no scalar init hook. Each registered function owns a TLS key
 * and all workers allocated through it. Catalog teardown follows execution;
 * deleting the key and worker list also reclaims the caller thread's cache. */
typedef struct worker_node {
    search_worker *worker;
    struct worker_node *next;
} worker_node;
typedef struct {
    const search_operation *operation;
#ifdef SASSY_SINGLE_THREADED
    search_worker *worker;
#elif defined(_WIN32)
    DWORD key;
    SRWLOCK mutex;
#else
    pthread_key_t key;
    pthread_mutex_t mutex;
#endif
    worker_node *workers;
} function_data;

typedef struct {
    void *data;
    uint64_t *validity;
} input_view;
typedef struct {
    duckdb_function_info info;
    function_data *function;
    input_view views[CRISPR_ARGUMENT_COUNT + 1];
    idx_t child_count;
    duckdb_vector output;
    void *output_data;
    uint64_t *output_validity;
    duckdb_vector children[HIT_FIELD_COUNT];
    void *child_data[HIT_FIELD_COUNT];
    uint64_t *child_validity[HIT_FIELD_COUNT];
    uint64_t *struct_validity;
    uint64_t capacity;
    uint64_t ops_size, ops_capacity;
} scalar_context;

static void function_destroy(void *pointer) {
    function_data *data = pointer;
#ifdef _WIN32
    TlsFree(data->key);
#elif !defined(SASSY_SINGLE_THREADED)
    pthread_key_delete(data->key);
#endif
    worker_node *node = data->workers;
    while (node) {
        worker_node *next = node->next;
        worker_destroy(node->worker);
        free(node);
        node = next;
    }
#if !defined(_WIN32) && !defined(SASSY_SINGLE_THREADED)
    pthread_mutex_destroy(&data->mutex);
#endif
    free(data);
}
static void input_error(void *pointer, const char *message) {
    duckdb_scalar_function_set_error(((scalar_context *)pointer)->info, message);
}
static search_worker *input_worker(void *pointer) {
    scalar_context *context = pointer;
    function_data *data = context->function;
#ifdef SASSY_SINGLE_THREADED
    search_worker *worker = data->worker;
#elif defined(_WIN32)
    search_worker *worker = TlsGetValue(data->key);
#else
    search_worker *worker = pthread_getspecific(data->key);
#endif
    if (worker) return worker;
    worker_node *node = calloc(1, sizeof(*node));
    worker = calloc(1, sizeof(*worker));
    if (!node || !worker) {
        free(node);
        free(worker);
        input_error(context, "ducksassy: thread worker allocation failed");
        return NULL;
    }
#ifdef SASSY_SINGLE_THREADED
    data->worker = worker;
    bool stored = true;
#elif defined(_WIN32)
    bool stored = TlsSetValue(data->key, worker) != 0;
#else
    bool stored = pthread_setspecific(data->key, worker) == 0;
#endif
    if (!stored) {
        free(node);
        free(worker);
        input_error(context, "ducksassy: thread worker allocation failed");
        return NULL;
    }
    node->worker = worker;
#ifdef _WIN32
    AcquireSRWLockExclusive(&data->mutex);
#elif !defined(SASSY_SINGLE_THREADED)
    pthread_mutex_lock(&data->mutex);
#endif
    node->next = data->workers;
    data->workers = node;
#ifdef _WIN32
    ReleaseSRWLockExclusive(&data->mutex);
#elif !defined(SASSY_SINGLE_THREADED)
    pthread_mutex_unlock(&data->mutex);
#endif
    return worker;
}
static bool input_valid(void *pointer, unsigned argument, uint64_t row) {
    uint64_t *validity = ((scalar_context *)pointer)->views[argument].validity;
    return !validity || (validity[row >> 6] & (UINT64_C(1) << (row & 63))) != 0;
}
static sassy_c_slice input_string(void *pointer, unsigned argument, uint64_t row) {
    scalar_context *context = pointer;
    if (!context->views[argument].data) {
        return argument == ARG_CIGAR_FORMAT ? (sassy_c_slice){(const uint8_t *)"text", 4} :
            (sassy_c_slice){(const uint8_t *)"iupac", 5};
    }
    duckdb_string_t *value = &((duckdb_string_t *)context->views[argument].data)[row];
    return (sassy_c_slice){(const uint8_t *)duckdb_string_t_data(value), duckdb_string_t_length(*value)};
}
static int64_t input_integer(void *pointer, unsigned argument, uint64_t row) {
    int64_t *data = ((scalar_context *)pointer)->views[argument].data;
    return data ? data[row] : 3;
}
static bool input_boolean(void *pointer, unsigned argument, uint64_t row) {
    bool *data = ((scalar_context *)pointer)->views[argument].data;
    return data ? data[row] : argument == ARG_REVERSE_COMPLEMENT;
}
static double input_real(void *pointer, unsigned argument, uint64_t row) {
    double *data = ((scalar_context *)pointer)->views[argument].data;
    return data ? data[row] : 0.2;
}
static panel_entry input_list(void *pointer, uint64_t row) {
    scalar_context *context = pointer;
    duckdb_list_entry entry = ((duckdb_list_entry *)context->views[ARG_PATTERN].data)[row];
    return (panel_entry){entry.offset, entry.length, context->child_count};
}
static bool output_hits(void *pointer, const hit_batch_view *batch, uint64_t offset) {
    scalar_context *context = pointer;
    if (!batch->hit_count) return true;
    bool extended = context->function->operation->kind == OP_MATCHES;
    unsigned field_count = extended ? HIT_FIELD_COUNT : HIT_CIGAR_OPS;
    uint64_t needed = offset + batch->hit_count;
    if (needed > context->capacity) {
        uint64_t capacity = context->capacity ? context->capacity : 256;
        while (capacity < needed) capacity *= 2;
        if (capacity > CHUNK_HIT_LIMIT) capacity = CHUNK_HIT_LIMIT;
        if (duckdb_list_vector_reserve(context->output, capacity) != DuckDBSuccess) {
            input_error(context, "ducksassy: list reserve failed");
            return false;
        }
        context->capacity = capacity;
        duckdb_vector child = duckdb_list_vector_get_child(context->output);
        duckdb_vector_ensure_validity_writable(child);
        context->struct_validity = duckdb_vector_get_validity(child);
        for (unsigned column = 0; column < field_count; ++column) {
            context->children[column] = duckdb_struct_vector_get_child(child, column);
            duckdb_vector_ensure_validity_writable(context->children[column]);
            context->child_data[column] = duckdb_vector_get_data(context->children[column]);
            context->child_validity[column] = duckdb_vector_get_validity(context->children[column]);
        }
    }
    if (batch->packed) {
        if (batch->op_count > UINT64_MAX - context->ops_size) {
            input_error(context, "ducksassy: packed CIGAR size overflow");
            return false;
        }
        uint64_t ops_needed = context->ops_size + batch->op_count;
        duckdb_vector list = context->children[HIT_CIGAR_OPS];
        if (ops_needed > context->ops_capacity) {
            uint64_t capacity = context->ops_capacity ? context->ops_capacity : 256;
            while (capacity < ops_needed) {
                if (capacity > UINT64_MAX / 2) { capacity = ops_needed; break; }
                capacity *= 2;
            }
            if (duckdb_list_vector_reserve(list, capacity) != DuckDBSuccess) {
                input_error(context, "ducksassy: packed CIGAR reserve failed");
                return false;
            }
            context->ops_capacity = capacity;
        }
        uint32_t *ops = duckdb_vector_get_data(duckdb_list_vector_get_child(list));
        if (batch->op_count) memcpy(ops + context->ops_size, batch->ops, batch->op_count * sizeof(*ops));
        if (duckdb_list_vector_set_size(list, ops_needed) != DuckDBSuccess) {
            input_error(context, "ducksassy: packed CIGAR size update failed");
            return false;
        }
    }
    for (size_t index = 0; index < batch->hit_count; ++index) {
        const sassy_c_hit *hit = &batch->hits[index];
        idx_t row = offset + index;
        ((uint64_t *)context->child_data[HIT_PATTERN_INDEX])[row] = hit->pattern_idx;
        ((uint64_t *)context->child_data[HIT_TEXT_START])[row] = hit->text_start;
        ((uint64_t *)context->child_data[HIT_TEXT_END])[row] = hit->text_end;
        ((uint64_t *)context->child_data[HIT_PATTERN_START])[row] = hit->pattern_start;
        ((uint64_t *)context->child_data[HIT_PATTERN_END])[row] = hit->pattern_end;
        ((int32_t *)context->child_data[HIT_COST])[row] = hit->cost;
        char strand = hit->strand ? '-' : '+';
        duckdb_vector_assign_string_element_len(context->children[HIT_STRAND], row, &strand, 1);
        if (batch->text) duckdb_vector_assign_string_element_len(context->children[HIT_CIGAR], row,
            (const char *)batch->cigars + hit->cigar_offset, hit->cigar_length);
        duckdb_validity_set_row_valid(context->struct_validity, row);
        for (unsigned column = 0; column < field_count; ++column) {
            duckdb_validity_set_row_valid(context->child_validity[column], row);
        }
        duckdb_validity_set_row_validity(context->child_validity[HIT_CIGAR], row, batch->text);
        if (extended) {
            sassy_c_op_span span = batch->packed ? batch->spans[index] : (sassy_c_op_span){0, 0};
            ((duckdb_list_entry *)context->child_data[HIT_CIGAR_OPS])[row] =
                (duckdb_list_entry){context->ops_size + span.offset, span.length};
            duckdb_validity_set_row_validity(context->child_validity[HIT_CIGAR_OPS], row, batch->packed);
        }
    }
    context->ops_size += batch->op_count;
    return true;
}
static bool output_result(void *pointer, uint64_t row, bool valid, uint64_t offset, uint64_t count) {
    scalar_context *context = pointer;
    operation_kind kind = context->function->operation->kind;
    if (kind == OP_MATCHES || kind == OP_CRISPR) {
        ((duckdb_list_entry *)context->output_data)[row] = (duckdb_list_entry){offset, count};
    } else if (valid && kind == OP_COUNT) {
        ((uint64_t *)context->output_data)[row] = count;
    } else if (valid) {
        ((bool *)context->output_data)[row] = count != 0;
    }
    duckdb_validity_set_row_validity(context->output_validity, row, valid);
    return true;
}
static const search_host host = {
    input_valid, input_string, input_integer, input_boolean, input_real, input_list,
    output_hits, output_result, input_worker, input_error
};
static void scalar_exec(duckdb_function_info info, duckdb_data_chunk input, duckdb_vector output) {
    scalar_context context = {.info = info, .output = output};
    context.function = duckdb_scalar_function_get_extra_info(info);
    const search_operation *operation = context.function->operation;
    unsigned arguments = (unsigned)duckdb_data_chunk_get_column_count(input);
    /* CAPIScalarFunction calls DataChunk::Flatten before invoking this callback,
     * including LIST children. Stable v1 vector access is flat at this boundary. */
    for (unsigned argument = 0; argument < arguments; ++argument) {
        duckdb_vector vector = duckdb_data_chunk_get_vector(input, argument);
        unsigned slot = argument;
        if (operation->kind == OP_CRISPR && argument >= 4) {
            static const unsigned slots[] = {ARG_ALLOW_PAM_EDITS, ARG_MAX_N_FRACTION, ARG_REVERSE_COMPLEMENT};
            slot = slots[argument - 4];
        }
        context.views[slot] = (input_view){duckdb_vector_get_data(vector), duckdb_vector_get_validity(vector)};
    }
    if (operation->panel) {
        duckdb_vector panel = duckdb_data_chunk_get_vector(input, ARG_PATTERN);
        duckdb_vector child = duckdb_list_vector_get_child(panel);
        context.child_count = duckdb_list_vector_get_size(panel);
        context.views[ARG_PANEL_CHILD] = (input_view){duckdb_vector_get_data(child), duckdb_vector_get_validity(child)};
    }
    context.output_data = duckdb_vector_get_data(output);
    duckdb_vector_ensure_validity_writable(output);
    context.output_validity = duckdb_vector_get_validity(output);
    uint64_t total_hits = 0;
    if (!search_execute(operation, &host, &context, duckdb_data_chunk_get_size(input), &total_hits)) return;
    if ((operation->kind == OP_MATCHES || operation->kind == OP_CRISPR) &&
        duckdb_list_vector_set_size(output, total_hits) != DuckDBSuccess) {
        input_error(&context, "ducksassy: list size update failed");
    }
}

static duckdb_logical_type hit_type(bool extended) {
    const char *names[HIT_FIELD_COUNT] = {"pattern_idx", "text_start", "text_end", "pattern_start",
        "pattern_end", "cost", "strand", "cigar", "cigar_ops"};
    duckdb_type ids[HIT_FIELD_COUNT] = {DUCKDB_TYPE_UBIGINT, DUCKDB_TYPE_UBIGINT, DUCKDB_TYPE_UBIGINT,
        DUCKDB_TYPE_UBIGINT, DUCKDB_TYPE_UBIGINT, DUCKDB_TYPE_INTEGER, DUCKDB_TYPE_VARCHAR, DUCKDB_TYPE_VARCHAR};
    duckdb_logical_type children[HIT_FIELD_COUNT];
    unsigned count = extended ? HIT_FIELD_COUNT : HIT_CIGAR_OPS;
    for (unsigned i = 0; i < HIT_CIGAR_OPS; ++i) children[i] = duckdb_create_logical_type(ids[i]);
    if (extended) {
        duckdb_logical_type op = duckdb_create_logical_type(DUCKDB_TYPE_UINTEGER);
        children[HIT_CIGAR_OPS] = duckdb_create_list_type(op);
        duckdb_destroy_logical_type(&op);
    }
    duckdb_logical_type structure = duckdb_create_struct_type(children, names, count);
    duckdb_logical_type list = duckdb_create_list_type(structure);
    duckdb_destroy_logical_type(&structure);
    for (unsigned i = 0; i < count; ++i) duckdb_destroy_logical_type(&children[i]);
    return list;
}
static bool add_operation(duckdb_scalar_function_set set, const search_operation *operation,
                          duckdb_type sequence_type, unsigned count) {
    function_data *data = calloc(1, sizeof(*data));
    if (!data) return false;
    data->operation = operation;
#ifdef _WIN32
    data->key = TlsAlloc();
    if (data->key == TLS_OUT_OF_INDEXES) { free(data); return false; }
    InitializeSRWLock(&data->mutex);
#elif !defined(SASSY_SINGLE_THREADED)
    if (pthread_key_create(&data->key, NULL) != 0) { free(data); return false; }
    if (pthread_mutex_init(&data->mutex, NULL) != 0) {
        pthread_key_delete(data->key);
        free(data);
        return false;
    }
#endif
    duckdb_scalar_function function = duckdb_create_scalar_function();
    if (!function) { function_destroy(data); return false; }
    duckdb_scalar_function_set_name(function, operation->name + 2);
    duckdb_scalar_function_set_extra_info(function, data, function_destroy);
    duckdb_scalar_function_set_special_handling(function);
    duckdb_scalar_function_set_function(function, scalar_exec);
    bool crispr = operation->kind == OP_CRISPR;
    duckdb_type ids[CRISPR_ARGUMENT_COUNT] = {sequence_type, sequence_type, DUCKDB_TYPE_BIGINT,
        crispr ? DUCKDB_TYPE_BIGINT : DUCKDB_TYPE_VARCHAR, DUCKDB_TYPE_BOOLEAN,
        crispr ? DUCKDB_TYPE_DOUBLE : DUCKDB_TYPE_BOOLEAN,
        crispr ? DUCKDB_TYPE_BOOLEAN : DUCKDB_TYPE_VARCHAR};
    for (unsigned i = 0; i < count; ++i) {
        duckdb_logical_type type = duckdb_create_logical_type(ids[i]);
        if (i == ARG_PATTERN && operation->panel) {
            duckdb_logical_type list = duckdb_create_list_type(type);
            duckdb_destroy_logical_type(&type);
            type = list;
        }
        duckdb_scalar_function_add_parameter(function, type);
        duckdb_destroy_logical_type(&type);
    }
    duckdb_logical_type result = operation->kind == OP_COUNT ? duckdb_create_logical_type(DUCKDB_TYPE_UBIGINT) :
        operation->kind == OP_CONTAINS ? duckdb_create_logical_type(DUCKDB_TYPE_BOOLEAN) :
        hit_type(operation->kind == OP_MATCHES);
    duckdb_scalar_function_set_return_type(function, result);
    duckdb_destroy_logical_type(&result);
    duckdb_state status = duckdb_add_scalar_function_to_set(set, function);
    duckdb_destroy_scalar_function(&function);
    return status == DuckDBSuccess;
}

static bool register_operation(duckdb_connection connection, const search_operation *operation) {
    duckdb_scalar_function_set set = duckdb_create_scalar_function_set(operation->name + 2);
    if (!set) return false;
    unsigned max_count = operation->kind == OP_CRISPR ? CRISPR_ARGUMENT_COUNT :
        operation->kind == OP_MATCHES ? SEARCH_ARGUMENT_COUNT : SEARCH_BASE_ARGUMENT_COUNT;
    bool success = true;
    for (unsigned count = 3; success && count <= max_count; ++count) {
        success = add_operation(set, operation, DUCKDB_TYPE_VARCHAR, count) &&
                  add_operation(set, operation, DUCKDB_TYPE_BLOB, count);
    }
    if (success) success = duckdb_register_scalar_function_set(connection, set) == DuckDBSuccess;
    duckdb_destroy_scalar_function_set(&set);
    return success;
}

static void backend_bind(duckdb_bind_info info) {
    const char *names[] = {"name", "compiled", "supported", "selected"};
    for (unsigned i = 0; i < 4; ++i) {
        duckdb_logical_type type = duckdb_create_logical_type(i == 0 ? DUCKDB_TYPE_VARCHAR : DUCKDB_TYPE_BOOLEAN);
        duckdb_bind_add_result_column(info, names[i], type);
        duckdb_destroy_logical_type(&type);
    }
    duckdb_bind_set_cardinality(info, SASSY_C_BACKEND_COUNT, true);
}
static void backend_init(duckdb_init_info info) {
    bool *done = calloc(1, sizeof(*done));
    if (!done) { duckdb_init_set_error(info, "ducksassy: backend state allocation failed"); return; }
    duckdb_init_set_init_data(info, done, free);
    duckdb_init_set_max_threads(info, 1);
}
static void backend_scan(duckdb_function_info info, duckdb_data_chunk output) {
    bool *done = duckdb_function_get_init_data(info);
    if (*done) { duckdb_data_chunk_set_size(output, 0); return; }
    duckdb_vector fields[4];
    for (unsigned i = 0; i < 4; ++i) fields[i] = duckdb_data_chunk_get_vector(output, i);
    for (unsigned i = 0; i < SASSY_C_BACKEND_COUNT; ++i) {
        sassy_c_backend_status status = {.struct_size = sizeof(status)};
        if (sassy_c_backend_status_get((sassy_c_backend)i, &status) != SASSY_C_OK) {
            duckdb_function_set_error(info, sassy_c_last_error()); return;
        }
        duckdb_vector_assign_string_element(fields[0], i, sassy_c_backend_name((sassy_c_backend)i));
        ((bool *)duckdb_vector_get_data(fields[1]))[i] = status.compiled != 0;
        ((bool *)duckdb_vector_get_data(fields[2]))[i] = status.supported != 0;
        ((bool *)duckdb_vector_get_data(fields[3]))[i] = status.selected != 0;
    }
    *done = true;
    duckdb_data_chunk_set_size(output, SASSY_C_BACKEND_COUNT);
}
static bool register_backend(duckdb_connection connection) {
    duckdb_table_function function = duckdb_create_table_function();
    duckdb_table_function_set_name(function, "sassy_backend_info");
    duckdb_table_function_set_bind(function, backend_bind);
    duckdb_table_function_set_init(function, backend_init);
    duckdb_table_function_set_function(function, backend_scan);
    duckdb_state status = duckdb_register_table_function(connection, function);
    duckdb_destroy_table_function(&function);
    return status == DuckDBSuccess;
}

/* Stable v1's value-string getter has no byte length. A private bind-time
 * SELECT exposes length-bearing vectors without casting VARCHAR to BLOB
 * (which interprets escapes). No query or DDL runs on the user's connection. */
static void grep_bind_destroy(void *pointer) {
    grep_input *input = pointer;
    free((void *)input->pattern.data);
    free((void *)input->text.data);
    free(input);
}
static void grep_bind(duckdb_bind_info info) {
    duckdb_value values[3];
    for (unsigned i = 0; i < 3; ++i) values[i] = duckdb_bind_get_parameter(info, i);
    grep_input *input = NULL;
    const char *error = NULL;
    duckdb_config config = NULL;
    duckdb_database db = NULL;
    duckdb_connection connection = NULL;
    duckdb_prepared_statement statement = NULL;
    duckdb_result result = {0};
    duckdb_data_chunk chunk = NULL;
    if (duckdb_is_null_value(values[0]) || duckdb_is_null_value(values[1]) || duckdb_is_null_value(values[2])) {
        error = "sassy_grep: arguments cannot be NULL";
        goto cleanup;
    }
    int64_t k = duckdb_get_int64(values[2]);
    if (k < 0 || (uint64_t)k > UINT32_MAX) {
        error = "sassy_grep: pattern must contain 1..4096 bytes and 0 <= k < pattern length";
        goto cleanup;
    }
    input = calloc(1, sizeof(*input));
    if (!input) { error = "sassy_grep: bind allocation failed"; goto cleanup; }
    input->k = (uint32_t)k;
    if (duckdb_create_config(&config) != DuckDBSuccess ||
        duckdb_set_config(config, "threads", "1") != DuckDBSuccess ||
        duckdb_open_ext(NULL, &db, config, NULL) != DuckDBSuccess ||
        duckdb_connect(db, &connection) != DuckDBSuccess ||
        duckdb_prepare(connection, "SELECT $1::VARCHAR, $2::VARCHAR", &statement) != DuckDBSuccess ||
        duckdb_bind_value(statement, 1, values[0]) != DuckDBSuccess ||
        duckdb_bind_value(statement, 2, values[1]) != DuckDBSuccess ||
        duckdb_execute_prepared(statement, &result) != DuckDBSuccess ||
        !(chunk = duckdb_fetch_chunk(result))) {
        error = "sassy_grep: could not materialize VARCHAR parameters";
        goto cleanup;
    }
    for (unsigned i = 0; i < 2; ++i) {
        duckdb_string_t *value = duckdb_vector_get_data(duckdb_data_chunk_get_vector(chunk, i));
        size_t length = duckdb_string_t_length(*value);
        uint8_t *copy = malloc(length ? length : 1);
        if (!copy) { error = "sassy_grep: input allocation failed"; goto cleanup; }
        if (length) memcpy(copy, duckdb_string_t_data(value), length);
        if (i == 0) input->pattern = (sassy_c_slice){copy, length};
        else input->text = (sassy_c_slice){copy, length};
    }
    if (!grep_validate(input, &error)) goto cleanup;
    const char *names[] = {"text_start", "text_end", "cost", "cigar"};
    duckdb_type ids[] = {DUCKDB_TYPE_UBIGINT, DUCKDB_TYPE_UBIGINT, DUCKDB_TYPE_INTEGER, DUCKDB_TYPE_VARCHAR};
    for (unsigned i = 0; i < GREP_COLUMN_COUNT; ++i) {
        duckdb_logical_type type = duckdb_create_logical_type(ids[i]);
        duckdb_bind_add_result_column(info, names[i], type);
        duckdb_destroy_logical_type(&type);
    }
    duckdb_bind_set_bind_data(info, input, grep_bind_destroy);
    input = NULL;
cleanup:
    duckdb_destroy_data_chunk(&chunk);
    duckdb_destroy_result(&result);
    duckdb_destroy_prepare(&statement);
    if (connection) duckdb_disconnect(&connection);
    if (db) duckdb_close(&db);
    duckdb_destroy_config(&config);
    if (input) grep_bind_destroy(input);
    for (unsigned i = 0; i < 3; ++i) duckdb_destroy_value(&values[i]);
    if (error) duckdb_bind_set_error(info, error);
}
static void grep_init(duckdb_init_info info) {
    grep_state *state = calloc(1, sizeof(*state));
    if (!state) { duckdb_init_set_error(info, "sassy_grep: scan allocation failed"); return; }
    if (sassy_c_searcher_new(SASSY_C_ASCII, 0, &state->searcher) != SASSY_C_OK) {
        duckdb_init_set_error(info, sassy_c_last_error());
        grep_state_destroy(state);
        return;
    }
    duckdb_init_set_init_data(info, state, grep_state_destroy);
    duckdb_init_set_max_threads(info, 1);
}
static void grep_exec(duckdb_function_info info, duckdb_data_chunk output) {
    grep_input *input = duckdb_function_get_bind_data(info);
    grep_state *state = duckdb_function_get_init_data(info);
    duckdb_vector vectors[GREP_COLUMN_COUNT];
    void *data[GREP_COLUMN_COUNT];
    for (unsigned i = 0; i < GREP_COLUMN_COUNT; ++i) {
        vectors[i] = duckdb_data_chunk_get_vector(output, i);
        data[i] = duckdb_vector_get_data(vectors[i]);
    }
    idx_t count = 0;
    while (count < GREP_OUTPUT_ROWS) {
        sassy_c_hit hit;
        const uint8_t *cigar = NULL;
        const char *error = NULL;
        int next = grep_next(input, state, &hit, &cigar, &error);
        if (next < 0) { duckdb_function_set_error(info, error); return; }
        if (next == 0 || (next == 2 && count > 0)) break;
        if (next == 2) continue;
        ((uint64_t *)data[GREP_TEXT_START])[count] = hit.text_start;
        ((uint64_t *)data[GREP_TEXT_END])[count] = hit.text_end;
        ((int32_t *)data[GREP_COST])[count] = hit.cost;
        duckdb_vector_assign_string_element_len(vectors[GREP_CIGAR], count, (const char *)cigar, hit.cigar_length);
        count++;
    }
    duckdb_data_chunk_set_size(output, count);
}
static bool register_grep(duckdb_connection connection) {
    duckdb_table_function function = duckdb_create_table_function();
    if (!function) return false;
    duckdb_table_function_set_name(function, "sassy_grep");
    for (unsigned i = 0; i < 3; ++i) {
        duckdb_logical_type type = duckdb_create_logical_type(i < 2 ? DUCKDB_TYPE_VARCHAR : DUCKDB_TYPE_BIGINT);
        duckdb_table_function_add_parameter(function, type);
        duckdb_destroy_logical_type(&type);
    }
    duckdb_table_function_set_bind(function, grep_bind);
    duckdb_table_function_set_init(function, grep_init);
    duckdb_table_function_set_function(function, grep_exec);
    duckdb_state status = duckdb_register_table_function(connection, function);
    duckdb_destroy_table_function(&function);
    return status == DuckDBSuccess;
}

DUCKDB_EXTENSION_ENTRYPOINT(duckdb_connection connection, duckdb_extension_info info,
                           struct duckdb_extension_access *access) {
    if (sassy_c_abi_version() != SASSY_C_ABI_VERSION) {
        access->set_error(info, "ducksassy: Rust/C ABI version mismatch");
        return false;
    }
    for (unsigned i = 0; i < sizeof(operations) / sizeof(operations[0]); ++i) {
        if (!register_operation(connection, &operations[i])) {
            access->set_error(info, "ducksassy: scalar registration failed"); return false;
        }
    }
    if (!register_backend(connection) || !register_grep(connection)) {
        access->set_error(info, "ducksassy: table registration failed"); return false;
    }
    return true;
}
