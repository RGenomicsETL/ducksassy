-- Public binding bootstrap. Install both extensions explicitly beforehand.
-- No network installation, filesystem parser, or re-entrant query in the C callback.
LOAD duckhts;
LOAD ducksassy;

CREATE OR REPLACE TEMP MACRO sassy_backend_info() AS TABLE
    SELECT backend.* FROM UNNEST(__sassy_backend_info()) AS entries(backend);

-- Retaining this dependency in public expressions also makes binding fail clearly
-- when DuckHTS is missing. The __sassy_* kernel functions are low-level internals.
CREATE OR REPLACE TEMP MACRO sassy_require_duckhts(limit_value) AS
    CASE WHEN length(duckhts_htslib_version()) > 0 THEN limit_value::BIGINT
         ELSE error('ducksassy requires a loaded DuckHTS extension') END;

CREATE OR REPLACE TEMP MACRO sassy_matches(pattern, text, k,
    alphabet := 'iupac', rc := true, all_endpoints := false,
    max_hits := 10000, max_text_bytes := 1048576) AS
    __sassy_matches(pattern, text, k::BIGINT, alphabet::VARCHAR, rc::BOOLEAN,
        all_endpoints::BOOLEAN, max_hits::BIGINT, sassy_require_duckhts(max_text_bytes));
CREATE OR REPLACE TEMP MACRO sassy_matches_many(patterns, text, k,
    alphabet := 'iupac', rc := true, all_endpoints := false,
    max_hits := 10000, max_text_bytes := 1048576) AS
    __sassy_matches_many(patterns, text, k::BIGINT, alphabet::VARCHAR, rc::BOOLEAN,
        all_endpoints::BOOLEAN, max_hits::BIGINT, sassy_require_duckhts(max_text_bytes));
CREATE OR REPLACE TEMP MACRO sassy_count(pattern, text, k,
    alphabet := 'iupac', rc := true, all_endpoints := false,
    max_hits := 10000, max_text_bytes := 1048576) AS
    __sassy_count(pattern, text, k::BIGINT, alphabet::VARCHAR, rc::BOOLEAN,
        all_endpoints::BOOLEAN, max_hits::BIGINT, sassy_require_duckhts(max_text_bytes));
CREATE OR REPLACE TEMP MACRO sassy_count_many(patterns, text, k,
    alphabet := 'iupac', rc := true, all_endpoints := false,
    max_hits := 10000, max_text_bytes := 1048576) AS
    __sassy_count_many(patterns, text, k::BIGINT, alphabet::VARCHAR, rc::BOOLEAN,
        all_endpoints::BOOLEAN, max_hits::BIGINT, sassy_require_duckhts(max_text_bytes));
CREATE OR REPLACE TEMP MACRO sassy_contains(pattern, text, k,
    alphabet := 'iupac', rc := true, all_endpoints := false,
    max_hits := 10000, max_text_bytes := 1048576) AS
    __sassy_contains(pattern, text, k::BIGINT, alphabet::VARCHAR, rc::BOOLEAN,
        all_endpoints::BOOLEAN, max_hits::BIGINT, sassy_require_duckhts(max_text_bytes));
CREATE OR REPLACE TEMP MACRO sassy_contains_many(patterns, text, k,
    alphabet := 'iupac', rc := true, all_endpoints := false,
    max_hits := 10000, max_text_bytes := 1048576) AS
    __sassy_contains_many(patterns, text, k::BIGINT, alphabet::VARCHAR, rc::BOOLEAN,
        all_endpoints::BOOLEAN, max_hits::BIGINT, sassy_require_duckhts(max_text_bytes));

CREATE OR REPLACE TEMP MACRO sassy_crispr_matches(guide, text, k, pam_length := 3,
    allow_pam_edits := false, max_n_frac := 0.2, rc := true,
    max_hits := 1000000, max_text_bytes := 1048576) AS
    CASE WHEN duckhts_htslib_version() IS NOT NULL
    THEN __sassy_crispr_matches(guide, text, k::BIGINT, pam_length::BIGINT,
                               rc::BOOLEAN, allow_pam_edits::BOOLEAN,
                               max_hits::BIGINT, max_text_bytes::BIGINT, max_n_frac::DOUBLE)
    ELSE error('ducksassy requires DuckHTS') END;

CREATE OR REPLACE TEMP MACRO sassy_crispr_matches_many(guides, text, k, pam_length := 3,
    allow_pam_edits := false, max_n_frac := 0.2, rc := true,
    max_hits := 1000000, max_text_bytes := 1048576) AS
    CASE WHEN duckhts_htslib_version() IS NOT NULL
    THEN __sassy_crispr_matches_many(guides, text, k::BIGINT, pam_length::BIGINT,
                                    rc::BOOLEAN, allow_pam_edits::BOOLEAN,
                                    max_hits::BIGINT, max_text_bytes::BIGINT, max_n_frac::DOUBLE)
    ELSE error('ducksassy requires DuckHTS') END;

CREATE OR REPLACE TEMP MACRO sassy_search_fasta(path, pattern, k, alphabet := 'dna', rc := true,
    all_endpoints := false, max_hits := 1000000, max_text_bytes := 1048576) AS TABLE
    SELECT r.*, unnest(sassy_matches(pattern, r.sequence, k, alphabet := alphabet,
        rc := rc, all_endpoints := all_endpoints, max_hits := max_hits,
        max_text_bytes := max_text_bytes)) AS hit
    FROM read_fasta(path, scan_mode := 'sequential') r;

CREATE OR REPLACE TEMP MACRO sassy_panel_search_fasta(path, patterns, k, alphabet := 'dna', rc := true,
    all_endpoints := false, max_hits := 1000000, max_text_bytes := 1048576) AS TABLE
    SELECT r.*, unnest(sassy_matches_many(patterns, r.sequence, k, alphabet := alphabet,
        rc := rc, all_endpoints := all_endpoints, max_hits := max_hits,
        max_text_bytes := max_text_bytes)) AS hit
    FROM read_fasta(path, scan_mode := 'sequential') r;

CREATE OR REPLACE TEMP MACRO sassy_crispr_search_fasta(path, guide, k, pam_length := 3,
    allow_pam_edits := false, max_n_frac := 0.2, rc := true,
    max_hits := 1000000, max_text_bytes := 1048576) AS TABLE
    SELECT r.*, unnest(sassy_crispr_matches(guide, r.sequence, k, pam_length := pam_length,
        allow_pam_edits := allow_pam_edits, max_n_frac := max_n_frac, rc := rc,
        max_hits := max_hits, max_text_bytes := max_text_bytes)) AS hit
    FROM read_fasta(path, scan_mode := 'sequential') r;

CREATE OR REPLACE TEMP MACRO sassy_crispr_panel_search_fasta(path, guides, k, pam_length := 3,
    allow_pam_edits := false, max_n_frac := 0.2, rc := true,
    max_hits := 1000000, max_text_bytes := 1048576) AS TABLE
    SELECT r.*, unnest(sassy_crispr_matches_many(guides, r.sequence, k, pam_length := pam_length,
        allow_pam_edits := allow_pam_edits, max_n_frac := max_n_frac, rc := rc,
        max_hits := max_hits, max_text_bytes := max_text_bytes)) AS hit
    FROM read_fasta(path, scan_mode := 'sequential') r;

CREATE OR REPLACE TEMP MACRO sassy_search_fastq(path, pattern, k,
    alphabet := 'iupac', rc := true, all_endpoints := false,
    max_hits := 10000, max_text_bytes := 1048576) AS TABLE
    SELECT r.*, unnest(sassy_matches(pattern, r.sequence, k,
        alphabet := alphabet, rc := rc, all_endpoints := all_endpoints,
        max_hits := max_hits, max_text_bytes := max_text_bytes)) AS hit
    FROM read_fastq(path, scan_mode := 'sequential') AS r;

CREATE OR REPLACE TEMP MACRO sassy_panel_search_fastq(path, patterns, k,
    alphabet := 'iupac', rc := true, all_endpoints := false,
    max_hits := 10000, max_text_bytes := 1048576) AS TABLE
    SELECT r.*, unnest(sassy_matches_many(patterns, r.sequence, k,
        alphabet := alphabet, rc := rc, all_endpoints := all_endpoints,
        max_hits := max_hits, max_text_bytes := max_text_bytes)) AS hit
    FROM read_fastq(path, scan_mode := 'sequential') AS r;

-- The named input table/view must expose a sequence column. All other columns
-- are preserved, so caller-supplied read/sample/locus identifiers remain intact.
CREATE OR REPLACE TEMP MACRO sassy_crispr_search_table(t, guide, k, pam_length := 3,
    allow_pam_edits := false, max_n_frac := 0.2, rc := true,
    max_hits := 1000000, max_text_bytes := 1048576) AS TABLE
    SELECT r.*, unnest(sassy_crispr_matches(guide, r.sequence, k, pam_length := pam_length,
        allow_pam_edits := allow_pam_edits, max_n_frac := max_n_frac, rc := rc,
        max_hits := max_hits, max_text_bytes := max_text_bytes)) AS hit
    FROM query_table(t) r;

CREATE OR REPLACE TEMP MACRO sassy_crispr_panel_search_table(t, guides, k, pam_length := 3,
    allow_pam_edits := false, max_n_frac := 0.2, rc := true,
    max_hits := 1000000, max_text_bytes := 1048576) AS TABLE
    SELECT r.*, unnest(sassy_crispr_matches_many(guides, r.sequence, k, pam_length := pam_length,
        allow_pam_edits := allow_pam_edits, max_n_frac := max_n_frac, rc := rc,
        max_hits := max_hits, max_text_bytes := max_text_bytes)) AS hit
    FROM query_table(t) r;

CREATE OR REPLACE TEMP MACRO sassy_search_table(input_table, pattern, k,
    alphabet := 'iupac', rc := true, all_endpoints := false,
    max_hits := 10000, max_text_bytes := 1048576) AS TABLE
    SELECT r.*, unnest(sassy_matches(pattern, r.sequence, k,
        alphabet := alphabet, rc := rc, all_endpoints := all_endpoints,
        max_hits := max_hits, max_text_bytes := max_text_bytes)) AS hit
    FROM query_table(input_table) AS r;
