/* Host-neutral search execution. Input slices are borrowed for one callback. */
#ifndef DUCKSASSY_CORE_H
#define DUCKSASSY_CORE_H
#include "sassy_c.h"
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define CHUNK_HIT_LIMIT UINT64_C(1048576)
#define PANEL_LIMIT 4096
#define ALPHABET_COUNT (SASSY_C_IUPAC + 1)
#define ORIENTATION_COUNT 2

typedef enum {
    ARG_PATTERN, ARG_TEXT, ARG_MAX_EDITS, ARG_ALPHABET,
    ARG_PAM_LENGTH = ARG_ALPHABET, ARG_REVERSE_COMPLEMENT, ARG_ALL_ENDPOINTS,
    ARG_ALLOW_PAM_EDITS = ARG_ALL_ENDPOINTS, ARG_MAX_N_FRACTION,
    CRISPR_ARGUMENT_COUNT, SEARCH_BASE_ARGUMENT_COUNT = ARG_MAX_N_FRACTION,
    ARG_CIGAR_FORMAT = ARG_MAX_N_FRACTION, SEARCH_ARGUMENT_COUNT,
    ARG_PANEL_CHILD = CRISPR_ARGUMENT_COUNT
} search_argument;
typedef enum {
    HIT_PATTERN_INDEX, HIT_TEXT_START, HIT_TEXT_END, HIT_PATTERN_START,
    HIT_PATTERN_END, HIT_COST, HIT_STRAND, HIT_CIGAR, HIT_CIGAR_OPS, HIT_FIELD_COUNT
} hit_field;
typedef enum { OP_MATCHES, OP_COUNT, OP_CONTAINS, OP_CRISPR } operation_kind;
typedef struct { const char *name; operation_kind kind; bool panel; } search_operation;
extern const search_operation operations[8];

typedef struct {
    sassy_c_searcher *searchers[ALPHABET_COUNT][ORIENTATION_COUNT];
    sassy_c_slice *patterns;
    size_t pattern_capacity;
} search_worker;
void worker_destroy(void *pointer);

typedef struct {
    const sassy_c_hit *hits;
    size_t hit_count;
    const uint8_t *cigars;
    size_t cigar_bytes;
    bool text, packed;
    const sassy_c_op_span *spans;
    const uint32_t *ops;
    size_t op_count;
} hit_batch_view;
typedef struct { uint64_t offset, length, child_count; } panel_entry;

/* Ten operations: host layout, output ownership and worker lifetime stay here.
 * write_hits appends one validated batch, not one virtual call per hit.
 * write_result writes NULL, a count/boolean, or a list entry according to kind.
 * Callback failures must report their own host error before returning false. */
typedef struct {
    bool (*valid)(void *, unsigned, uint64_t);
    sassy_c_slice (*string)(void *, unsigned, uint64_t);
    int64_t (*integer)(void *, unsigned, uint64_t);
    bool (*boolean)(void *, unsigned, uint64_t);
    double (*real)(void *, unsigned, uint64_t);
    panel_entry (*list)(void *, uint64_t);
    bool (*write_hits)(void *, const hit_batch_view *, uint64_t);
    bool (*write_result)(void *, uint64_t, bool, uint64_t, uint64_t);
    search_worker *(*worker)(void *);
    void (*error)(void *, const char *);
} search_host;
bool search_execute(const search_operation *operation, const search_host *host,
                    void *context, uint64_t row_count, uint64_t *total_hits);
bool equal_label(sassy_c_slice value, const char *label);

#define GREP_CORE_BYTES 1024
#define GREP_OUTPUT_ROWS 1024
enum { GREP_TEXT_START, GREP_TEXT_END, GREP_COST, GREP_CIGAR, GREP_COLUMN_COUNT };
typedef struct { sassy_c_slice pattern, text; uint32_t k; } grep_input;
typedef struct {
    sassy_c_searcher *searcher;
    sassy_c_result *result;
    const sassy_c_hit *hits;
    const uint8_t *cigars;
    size_t hit_count, hit_index;
    size_t core_start, window_start, core_begin;
} grep_state;
void grep_state_destroy(void *pointer);
bool grep_validate(const grep_input *data, const char **error);
/* Returns 1 with a hit, 2 at a window boundary, 0 at end, -1 on failure.
 * At a boundary, emit a nonempty output chunk before reading another window. */
int grep_next(const grep_input *data, grep_state *state, sassy_c_hit *hit,
              const uint8_t **cigar, const char **error);
#endif
