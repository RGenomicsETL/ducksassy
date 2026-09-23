#include "ducksassy_core.h"
#include <ctype.h>
#include <stdlib.h>
#include <string.h>

const search_operation operations[8] = {
    {"__sassy_matches", OP_MATCHES, false},
    {"__sassy_matches_many", OP_MATCHES, true},
    {"__sassy_count", OP_COUNT, false},
    {"__sassy_count_many", OP_COUNT, true},
    {"__sassy_contains", OP_CONTAINS, false},
    {"__sassy_contains_many", OP_CONTAINS, true},
    {"__sassy_crispr_matches", OP_CRISPR, false},
    {"__sassy_crispr_matches_many", OP_CRISPR, true}
};

bool equal_label(sassy_c_slice value, const char *label) {
    size_t length = strlen(label);
    if (value.len != length) return false;
    for (size_t index = 0; index < length; ++index) {
        if (tolower((unsigned char)value.data[index]) != (unsigned char)label[index]) return false;
    }
    return true;
}

void worker_destroy(void *pointer) {
    search_worker *worker = pointer;
    if (!worker) return;
    for (uint32_t alphabet = 0; alphabet < ALPHABET_COUNT; ++alphabet) {
        for (uint32_t orientation = 0; orientation < ORIENTATION_COUNT; ++orientation) {
            sassy_c_searcher_free(worker->searchers[alphabet][orientation]);
        }
    }
    free(worker->patterns);
    free(worker);
}

#define INPUT_ERROR(message) do { host->error(context, message); goto cleanup; } while (0)

bool search_execute(const search_operation *operation, const search_host *host,
                    void *context, uint64_t row_count, uint64_t *total_hits) {
    sassy_c_result *result = NULL;
    search_worker *worker = host->worker(context);
    bool success = false;
    *total_hits = 0;
    if (!worker) return false;
    bool crispr = operation->kind == OP_CRISPR;
    bool output_hits = operation->kind == OP_MATCHES || crispr;
    unsigned argument_count = crispr ? CRISPR_ARGUMENT_COUNT :
        operation->kind == OP_MATCHES ? SEARCH_ARGUMENT_COUNT : SEARCH_BASE_ARGUMENT_COUNT;
    for (uint64_t row = 0; row < row_count; ++row) {
        bool valid = true;
        for (unsigned argument = 0; argument < argument_count; ++argument) {
            valid = valid && host->valid(context, argument, row);
        }
        if (!valid) {
            if (!host->write_result(context, row, false, 0, 0)) goto cleanup;
            continue;
        }
        int64_t max_edits = host->integer(context, ARG_MAX_EDITS, row);
        if (max_edits < 0 || (uint64_t)max_edits > UINT32_MAX) {
            INPUT_ERROR("ducksassy: k must be nonnegative");
        }
        uint32_t alphabet = SASSY_C_IUPAC;
        sassy_c_crispr_options crispr_options = {0};
        if (crispr) {
            int64_t pam_length = host->integer(context, ARG_PAM_LENGTH, row);
            double max_n_fraction = host->real(context, ARG_MAX_N_FRACTION, row);
            if (pam_length <= 0 || (uint64_t)pam_length > UINT32_MAX ||
                !(max_n_fraction >= 0.0 && max_n_fraction <= 1.0)) {
                INPUT_ERROR("ducksassy: pam_length must be positive and max_n_frac must be in [0,1]");
            }
            crispr_options.struct_size = sizeof(crispr_options);
            crispr_options.pam_length = (uint32_t)pam_length;
            crispr_options.allow_pam_edits = host->boolean(context, ARG_ALLOW_PAM_EDITS, row) ? 1U : 0U;
            crispr_options.include_cigar = 1;
            crispr_options.max_n_frac = (float)max_n_fraction;
        } else {
            sassy_c_slice label = host->string(context, ARG_ALPHABET, row);
            if (equal_label(label, "ascii")) alphabet = SASSY_C_ASCII;
            else if (equal_label(label, "dna")) alphabet = SASSY_C_DNA;
            else if (equal_label(label, "iupac")) alphabet = SASSY_C_IUPAC;
            else INPUT_ERROR("ducksassy: alphabet must be ascii, dna, or iupac");
        }
        uint32_t reverse_complement = host->boolean(context, ARG_REVERSE_COMPLEMENT, row) ? 1U : 0U;
        sassy_c_searcher **searcher = &worker->searchers[alphabet][reverse_complement];
        if (!*searcher && sassy_c_searcher_new(alphabet, reverse_complement, searcher) != SASSY_C_OK) {
            INPUT_ERROR(sassy_c_last_error());
        }
        bool text_cigar = output_hits, packed_cigar = false;
        if (operation->kind == OP_MATCHES) {
            sassy_c_slice format = host->string(context, ARG_CIGAR_FORMAT, row);
            text_cigar = equal_label(format, "text") || equal_label(format, "both");
            packed_cigar = equal_label(format, "packed") || equal_label(format, "both");
            if (!text_cigar && !packed_cigar) INPUT_ERROR("ducksassy: cigar_format must be text, packed, or both");
        }
        sassy_c_options options = {
            .struct_size = sizeof(options),
            .all_endpoints = host->boolean(context, ARG_ALL_ENDPOINTS, row) ? 1U : 0U,
            .include_cigar = text_cigar ? 1U : 0U,
            .reserved = packed_cigar ? SASSY_C_PACKED_CIGAR : 0U
        };
        sassy_c_slice text = host->string(context, ARG_TEXT, row);
        sassy_c_slice single_pattern;
        const sassy_c_slice *patterns = &single_pattern;
        size_t pattern_count = 1;
        if (operation->panel) {
            panel_entry entry = host->list(context, row);
            if (entry.length > PANEL_LIMIT || entry.offset > entry.child_count ||
                entry.length > entry.child_count - entry.offset) {
                INPUT_ERROR("ducksassy: invalid panel bounds or more than 4096 patterns");
            }
            pattern_count = (size_t)entry.length;
            if (pattern_count > worker->pattern_capacity) {
                sassy_c_slice *resized = realloc(worker->patterns, pattern_count * sizeof(*resized));
                if (!resized) INPUT_ERROR("ducksassy: pattern descriptor allocation failed");
                worker->patterns = resized;
                worker->pattern_capacity = pattern_count;
            }
            for (size_t index = 0; index < pattern_count; ++index) {
                uint64_t child_row = entry.offset + index;
                if (!host->valid(context, ARG_PANEL_CHILD, child_row)) {
                    INPUT_ERROR("ducksassy: a pattern panel cannot contain NULL elements");
                }
                worker->patterns[index] = host->string(context, ARG_PANEL_CHILD, child_row);
            }
            patterns = worker->patterns;
        } else {
            single_pattern = host->string(context, ARG_PATTERN, row);
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
            host->error(context, sassy_c_last_error());
            if (status == SASSY_C_PANIC) {
                sassy_c_searcher_free(*searcher);
                *searcher = NULL;
            }
            goto cleanup;
        }
        hit_batch_view batch = {.text = text_cigar, .packed = packed_cigar};
        if (sassy_c_result_view(result, &batch.hits, &batch.hit_count, &batch.cigars,
                               &batch.cigar_bytes) != SASSY_C_OK) INPUT_ERROR(sassy_c_last_error());
        if (packed_cigar && sassy_c_result_ops_view(result, &batch.spans, &batch.ops,
                               &batch.op_count) != SASSY_C_OK) INPUT_ERROR(sassy_c_last_error());
        if (output_hits) {
            if (*total_hits > CHUNK_HIT_LIMIT || batch.hit_count > CHUNK_HIT_LIMIT - *total_hits) {
                INPUT_ERROR("ducksassy: chunk exceeds 1048576 output hits; reduce the search scope or use count/contains");
            }
            for (size_t index = 0; index < batch.hit_count; ++index) {
                const sassy_c_hit *hit = &batch.hits[index];
                if (text_cigar && (hit->cigar_length > UINT32_MAX || hit->cigar_offset > batch.cigar_bytes ||
                    hit->cigar_length > batch.cigar_bytes - hit->cigar_offset)) {
                    INPUT_ERROR("ducksassy: invalid CIGAR slab bounds returned by Rust");
                }
                if (packed_cigar && (!batch.spans || batch.spans[index].offset > batch.op_count ||
                    batch.spans[index].length > batch.op_count - batch.spans[index].offset)) {
                    INPUT_ERROR("ducksassy: invalid packed CIGAR slab bounds returned by Rust");
                }
            }
            if (!host->write_hits(context, &batch, *total_hits)) goto cleanup;
        }
        if (!host->write_result(context, row, true, *total_hits, batch.hit_count)) goto cleanup;
        if (output_hits) *total_hits += batch.hit_count;
        sassy_c_result_recycle(*searcher, result);
        result = NULL;
    }
    success = true;
cleanup:
    sassy_c_result_free(result);
    if (worker->patterns) memset(worker->patterns, 0, worker->pattern_capacity * sizeof(*worker->patterns));
    return success;
}
#undef INPUT_ERROR

bool grep_validate(const grep_input *data, const char **error) {
    if (data->pattern.len == 0 || data->pattern.len > 4096 || data->k >= data->pattern.len) {
        *error = "sassy_grep: pattern must contain 1..4096 bytes and 0 <= k < pattern length";
        return false;
    }
    for (size_t i = 0; i < data->pattern.len; ++i) {
        if (data->pattern.data[i] > 127) {
            *error = "sassy_grep: pattern must be ASCII";
            return false;
        }
    }
    return true;
}

void grep_state_destroy(void *pointer) {
    grep_state *state = pointer;
    if (!state) return;
    sassy_c_result_free(state->result);
    sassy_c_searcher_free(state->searcher);
    free(state);
}

/* Return one window at a time so LIMIT need not scan the complete text. */
static int grep_load_window(const grep_input *data, grep_state *state, const char **error) {
    if (state->core_start >= data->text.len) return 0;
    const size_t overlap = data->pattern.len + (size_t)data->k;
    state->core_begin = state->core_start;
    state->window_start = state->core_begin > overlap ? state->core_begin - overlap : 0;
    const size_t remaining = data->text.len - state->core_begin;
    const size_t core_length = remaining < GREP_CORE_BYTES ? remaining : GREP_CORE_BYTES;
    const size_t core_end = state->core_begin + core_length;
    const size_t right_remaining = data->text.len - core_end;
    const size_t right_overlap = right_remaining < overlap ? right_remaining : overlap;
    const size_t window_end = core_end + right_overlap;
    sassy_c_slice window = {data->text.data + state->window_start, window_end - state->window_start};
    sassy_c_options options = {.struct_size = sizeof(options), .all_endpoints = 1, .include_cigar = 1};
    if (sassy_c_search(state->searcher, data->pattern, window, data->k, &options,
                       &state->result) != SASSY_C_OK) {
        *error = sassy_c_last_error();
        return -1;
    }
    size_t cigar_bytes = 0;
    if (sassy_c_result_view(state->result, &state->hits, &state->hit_count,
                            &state->cigars, &cigar_bytes) != SASSY_C_OK) {
        *error = sassy_c_last_error();
        return -1;
    }
    state->hit_index = 0;
    state->core_start = core_end;
    return 1;
}

int grep_next(const grep_input *data, grep_state *state, sassy_c_hit *hit,
              const uint8_t **cigar, const char **error) {
    for (;;) {
        if (state->result && state->hit_index == state->hit_count) {
            sassy_c_result_recycle(state->searcher, state->result);
            state->result = NULL;
            state->hits = NULL;
            state->cigars = NULL;
            return 2;
        }
        if (!state->result) {
            int loaded = grep_load_window(data, state, error);
            if (loaded != 1) return loaded;
        }
        while (state->hit_index < state->hit_count) {
            *hit = state->hits[state->hit_index++];
            uint64_t end = hit->text_end + state->window_start;
            if (end <= state->core_begin || end > state->core_start) continue;
            hit->text_start += state->window_start;
            hit->text_end = end;
            *cigar = state->cigars + hit->cigar_offset;
            return 1;
        }
    }
}
