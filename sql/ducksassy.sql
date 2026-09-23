-- Public binding bootstrap. Install both extensions explicitly beforehand.
-- No network installation, filesystem parser, or re-entrant query in the C callback.
LOAD duckhts;
LOAD ducksassy;

CREATE OR REPLACE TEMP MACRO sassy_backend_info() AS TABLE
    SELECT backend.* FROM UNNEST(__sassy_backend_info()) AS entries(backend);

CREATE OR REPLACE TEMP MACRO sassy_matches(pattern, text, k,
    alphabet := 'iupac', rc := true, all_endpoints := false) AS
    __sassy_matches(pattern, text, k::BIGINT, alphabet::VARCHAR, rc::BOOLEAN,
        all_endpoints::BOOLEAN);
CREATE OR REPLACE TEMP MACRO sassy_matches_many(patterns, text, k,
    alphabet := 'iupac', rc := true, all_endpoints := false) AS
    __sassy_matches_many(patterns, text, k::BIGINT, alphabet::VARCHAR, rc::BOOLEAN,
        all_endpoints::BOOLEAN);
-- Packed mode leaves cigar NULL and emits SAM-oriented BAM uint32 ops.
-- Both mode retains the pattern-oriented text and emits packed ops.
CREATE OR REPLACE TEMP MACRO sassy_matches_packed(pattern, text, k,
    alphabet := 'iupac', rc := true, all_endpoints := false) AS
    __sassy_matches_packed(pattern, text, k::BIGINT, alphabet::VARCHAR, rc::BOOLEAN,
        all_endpoints::BOOLEAN);
CREATE OR REPLACE TEMP MACRO sassy_matches_many_packed(patterns, text, k,
    alphabet := 'iupac', rc := true, all_endpoints := false) AS
    __sassy_matches_many_packed(patterns, text, k::BIGINT, alphabet::VARCHAR, rc::BOOLEAN,
        all_endpoints::BOOLEAN);
CREATE OR REPLACE TEMP MACRO sassy_matches_both(pattern, text, k,
    alphabet := 'iupac', rc := true, all_endpoints := false) AS
    __sassy_matches_both(pattern, text, k::BIGINT, alphabet::VARCHAR, rc::BOOLEAN,
        all_endpoints::BOOLEAN);
CREATE OR REPLACE TEMP MACRO sassy_matches_many_both(patterns, text, k,
    alphabet := 'iupac', rc := true, all_endpoints := false) AS
    __sassy_matches_many_both(patterns, text, k::BIGINT, alphabet::VARCHAR, rc::BOOLEAN,
        all_endpoints::BOOLEAN);
-- Partial searches use Sassy's overhang penalty alpha=0.5.
CREATE OR REPLACE TEMP MACRO sassy_matches_packed_overhang(pattern, text, k,
    alphabet := 'iupac', rc := true, all_endpoints := false) AS
    __sassy_matches_packed_overhang(pattern, text, k::BIGINT, alphabet::VARCHAR, rc::BOOLEAN,
        all_endpoints::BOOLEAN);
CREATE OR REPLACE TEMP MACRO sassy_matches_both_overhang(pattern, text, k,
    alphabet := 'iupac', rc := true, all_endpoints := false) AS
    __sassy_matches_both_overhang(pattern, text, k::BIGINT, alphabet::VARCHAR, rc::BOOLEAN,
        all_endpoints::BOOLEAN);
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
    CASE WHEN duckhts_htslib_version() IS NOT NULL
    THEN __sassy_crispr_matches(guide, text, k::BIGINT, pam_length::BIGINT,
                               rc::BOOLEAN, allow_pam_edits::BOOLEAN,
                               max_n_frac::DOUBLE)
    ELSE error('ducksassy requires DuckHTS') END;

CREATE OR REPLACE TEMP MACRO sassy_crispr_matches_many(guides, text, k, pam_length := 3,
    allow_pam_edits := false, max_n_frac := 0.2, rc := true) AS
    CASE WHEN duckhts_htslib_version() IS NOT NULL
    THEN __sassy_crispr_matches_many(guides, text, k::BIGINT, pam_length::BIGINT,
                                    rc::BOOLEAN, allow_pam_edits::BOOLEAN,
                                    max_n_frac::DOUBLE)
    ELSE error('ducksassy requires DuckHTS') END;

CREATE OR REPLACE TEMP MACRO sassy_search_fasta(path, pattern, k, alphabet := 'dna', rc := true,
    all_endpoints := false) AS TABLE
    SELECT r.*, unnest(sassy_matches(pattern, r.sequence, k, alphabet := alphabet,
        rc := rc, all_endpoints := all_endpoints)) AS hit
    FROM read_fasta(path, scan_mode := 'sequential') r;

CREATE OR REPLACE TEMP MACRO sassy_panel_search_fasta(path, patterns, k, alphabet := 'dna', rc := true,
    all_endpoints := false) AS TABLE
    SELECT r.*, unnest(sassy_matches_many(patterns, r.sequence, k, alphabet := alphabet,
        rc := rc, all_endpoints := all_endpoints)) AS hit
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
    alphabet := 'iupac', rc := true, all_endpoints := false) AS TABLE
    SELECT r.*, unnest(sassy_matches(pattern, r.sequence, k,
        alphabet := alphabet, rc := rc, all_endpoints := all_endpoints)) AS hit
    FROM read_fastq(path, scan_mode := 'sequential') AS r;

CREATE OR REPLACE TEMP MACRO sassy_panel_search_fastq(path, patterns, k,
    alphabet := 'iupac', rc := true, all_endpoints := false) AS TABLE
    SELECT r.*, unnest(sassy_matches_many(patterns, r.sequence, k,
        alphabet := alphabet, rc := rc, all_endpoints := all_endpoints)) AS hit
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
    alphabet := 'iupac', rc := true, all_endpoints := false) AS TABLE
    SELECT r.*, unnest(sassy_matches(pattern, r.sequence, k,
        alphabet := alphabet, rc := rc, all_endpoints := all_endpoints)) AS hit
    FROM query_table(input_table) AS r;
