#define DUCKDB_EXTENSION_NAME panicprobe
#include "duckdb_extension.h"
DUCKDB_EXTENSION_EXTERN

extern int probe_catch(void);

static void probe(duckdb_function_info info, duckdb_data_chunk input, duckdb_vector output) {
    (void)info;
    (void)input;
    *(int32_t *)duckdb_vector_get_data(output) = probe_catch();
}

DUCKDB_EXTENSION_ENTRYPOINT(duckdb_connection connection, duckdb_extension_info info,
                           struct duckdb_extension_access *access) {
    (void)info;
    (void)access;
    duckdb_scalar_function fun = duckdb_create_scalar_function();
    duckdb_scalar_function_set_name(fun, "panicprobe");
    duckdb_logical_type type = duckdb_create_logical_type(DUCKDB_TYPE_INTEGER);
    duckdb_scalar_function_set_return_type(fun, type);
    duckdb_destroy_logical_type(&type);
    duckdb_scalar_function_set_function(fun, probe);
    duckdb_state state = duckdb_register_scalar_function(connection, fun);
    duckdb_destroy_scalar_function(&fun);
    return state == DuckDBSuccess;
}
