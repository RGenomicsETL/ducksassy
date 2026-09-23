-- Explicit bootstrap for v2. File macros use a locally installed DuckHTS.
LOAD duckhts;
LOAD ducksassy;

CREATE OR REPLACE TEMP MACRO sassy_backend_info() AS TABLE
    SELECT backend.* FROM UNNEST(__sassy_backend_info()) AS entries(backend);

-- Text CIGAR follows pattern orientation; packed ops follow SAM reference orientation.
-- The stable result struct includes nullable cigar_ops for every format.
CREATE OR REPLACE TEMP MACRO sassy_matches(pattern, text, k,
    alphabet := 'iupac', rc := true, all_endpoints := false, cigar_format := 'text') AS
    __sassy_matches(pattern, text, k::BIGINT, alphabet::VARCHAR, rc::BOOLEAN,
        all_endpoints::BOOLEAN, cigar_format::VARCHAR);
CREATE OR REPLACE TEMP MACRO sassy_matches_many(patterns, text, k,
    alphabet := 'iupac', rc := true, all_endpoints := false, cigar_format := 'text') AS
    __sassy_matches_many(patterns, text, k::BIGINT, alphabet::VARCHAR, rc::BOOLEAN,
        all_endpoints::BOOLEAN, cigar_format::VARCHAR);
CREATE OR REPLACE TEMP MACRO sassy_count(pattern, text, k,
    alphabet := 'iupac', rc := true, all_endpoints := false) AS
    __sassy_count(pattern, text, k::BIGINT, alphabet::VARCHAR, rc::BOOLEAN,
        all_endpoints::BOOLEAN);
CREATE OR REPLACE TEMP MACRO sassy_count_many(patterns, text, k,
    alphabet := 'iupac', rc := true, all_endpoints := false) AS
    __sassy_count_many(patterns, text, k::BIGINT, alphabet::VARCHAR, rc::BOOLEAN,
        all_endpoints::BOOLEAN);
CREATE OR REPLACE TEMP MACRO sassy_contains(pattern, text, k,
    alphabet := 'iupac', rc := true, all_endpoints := false) AS
    __sassy_contains(pattern, text, k::BIGINT, alphabet::VARCHAR, rc::BOOLEAN,
        all_endpoints::BOOLEAN);
CREATE OR REPLACE TEMP MACRO sassy_contains_many(patterns, text, k,
    alphabet := 'iupac', rc := true, all_endpoints := false) AS
    __sassy_contains_many(patterns, text, k::BIGINT, alphabet::VARCHAR, rc::BOOLEAN,
        all_endpoints::BOOLEAN);

CREATE OR REPLACE TEMP MACRO sassy_crispr_matches(guide, text, k, pam_length := 3,
    allow_pam_edits := false, max_n_frac := 0.2, rc := true) AS
    __sassy_crispr_matches(guide, text, k::BIGINT, pam_length::BIGINT,
                           rc::BOOLEAN, allow_pam_edits::BOOLEAN, max_n_frac::DOUBLE);

CREATE OR REPLACE TEMP MACRO sassy_crispr_matches_many(guides, text, k, pam_length := 3,
    allow_pam_edits := false, max_n_frac := 0.2, rc := true) AS
    __sassy_crispr_matches_many(guides, text, k::BIGINT, pam_length::BIGINT,
                                rc::BOOLEAN, allow_pam_edits::BOOLEAN, max_n_frac::DOUBLE);

CREATE OR REPLACE TEMP MACRO sassy_search_fasta(path, pattern, k, alphabet := 'dna', rc := true,
    all_endpoints := false, cigar_format := 'text') AS TABLE
    SELECT r.*, unnest(sassy_matches(pattern, r.sequence, k, alphabet := alphabet,
        rc := rc, all_endpoints := all_endpoints, cigar_format := cigar_format)) AS hit
    FROM read_fasta(path, scan_mode := 'sequential') r;

CREATE OR REPLACE TEMP MACRO sassy_panel_search_fasta(path, patterns, k, alphabet := 'dna', rc := true,
    all_endpoints := false, cigar_format := 'text') AS TABLE
    SELECT r.*, unnest(sassy_matches_many(patterns, r.sequence, k, alphabet := alphabet,
        rc := rc, all_endpoints := all_endpoints, cigar_format := cigar_format)) AS hit
    FROM read_fasta(path, scan_mode := 'sequential') r;

CREATE OR REPLACE TEMP MACRO sassy_crispr_search_fasta(path, guide, k, pam_length := 3,
    allow_pam_edits := false, max_n_frac := 0.2, rc := true) AS TABLE
    SELECT r.*, unnest(sassy_crispr_matches(guide, r.sequence, k, pam_length := pam_length,
        allow_pam_edits := allow_pam_edits, max_n_frac := max_n_frac, rc := rc)) AS hit
    FROM read_fasta(path, scan_mode := 'sequential') r;

CREATE OR REPLACE TEMP MACRO sassy_crispr_panel_search_fasta(path, guides, k, pam_length := 3,
    allow_pam_edits := false, max_n_frac := 0.2, rc := true) AS TABLE
    SELECT r.*, unnest(sassy_crispr_matches_many(guides, r.sequence, k, pam_length := pam_length,
        allow_pam_edits := allow_pam_edits, max_n_frac := max_n_frac, rc := rc)) AS hit
    FROM read_fasta(path, scan_mode := 'sequential') r;

CREATE OR REPLACE TEMP MACRO sassy_search_fastq(path, pattern, k,
    alphabet := 'iupac', rc := true, all_endpoints := false, cigar_format := 'text') AS TABLE
    SELECT r.*, unnest(sassy_matches(pattern, r.sequence, k,
        alphabet := alphabet, rc := rc, all_endpoints := all_endpoints,
        cigar_format := cigar_format)) AS hit
    FROM read_fastq(path, scan_mode := 'sequential') AS r;

CREATE OR REPLACE TEMP MACRO sassy_panel_search_fastq(path, patterns, k,
    alphabet := 'iupac', rc := true, all_endpoints := false, cigar_format := 'text') AS TABLE
    SELECT r.*, unnest(sassy_matches_many(patterns, r.sequence, k,
        alphabet := alphabet, rc := rc, all_endpoints := all_endpoints,
        cigar_format := cigar_format)) AS hit
    FROM read_fastq(path, scan_mode := 'sequential') AS r;

-- The named input table/view must expose a sequence column. All other columns
-- are preserved, so caller-supplied read/sample/locus identifiers remain intact.
CREATE OR REPLACE TEMP MACRO sassy_crispr_search_table(t, guide, k, pam_length := 3,
    allow_pam_edits := false, max_n_frac := 0.2, rc := true) AS TABLE
    SELECT r.*, unnest(sassy_crispr_matches(guide, r.sequence, k, pam_length := pam_length,
        allow_pam_edits := allow_pam_edits, max_n_frac := max_n_frac, rc := rc)) AS hit
    FROM query_table(t) r;

CREATE OR REPLACE TEMP MACRO sassy_crispr_panel_search_table(t, guides, k, pam_length := 3,
    allow_pam_edits := false, max_n_frac := 0.2, rc := true) AS TABLE
    SELECT r.*, unnest(sassy_crispr_matches_many(guides, r.sequence, k, pam_length := pam_length,
        allow_pam_edits := allow_pam_edits, max_n_frac := max_n_frac, rc := rc)) AS hit
    FROM query_table(t) r;

CREATE OR REPLACE TEMP MACRO sassy_search_table(input_table, pattern, k,
    alphabet := 'iupac', rc := true, all_endpoints := false, cigar_format := 'text') AS TABLE
    SELECT r.*, unnest(sassy_matches(pattern, r.sequence, k,
        alphabet := alphabet, rc := rc, all_endpoints := all_endpoints,
        cigar_format := cigar_format)) AS hit
    FROM query_table(input_table) AS r;
