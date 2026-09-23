-- Test-only adapters let shared named-argument fixtures exercise positional v1 calls.
-- The extension registers none of these macros.
CREATE TEMP MACRO sassy_matches_opts(pattern, text, k,
    alphabet := 'iupac', rc := true, all_endpoints := false, cigar_format := 'text') AS
    sassy_matches(pattern, text, k::BIGINT, alphabet::VARCHAR, rc::BOOLEAN,
        all_endpoints::BOOLEAN, cigar_format::VARCHAR);
CREATE TEMP MACRO sassy_matches_many_opts(patterns, text, k,
    alphabet := 'iupac', rc := true, all_endpoints := false, cigar_format := 'text') AS
    sassy_matches_many(patterns, text, k::BIGINT, alphabet::VARCHAR, rc::BOOLEAN,
        all_endpoints::BOOLEAN, cigar_format::VARCHAR);
CREATE TEMP MACRO sassy_count_opts(pattern, text, k,
    alphabet := 'iupac', rc := true, all_endpoints := false) AS
    sassy_count(pattern, text, k::BIGINT, alphabet::VARCHAR, rc::BOOLEAN, all_endpoints::BOOLEAN);
CREATE TEMP MACRO sassy_count_many_opts(patterns, text, k,
    alphabet := 'iupac', rc := true, all_endpoints := false) AS
    sassy_count_many(patterns, text, k::BIGINT, alphabet::VARCHAR, rc::BOOLEAN, all_endpoints::BOOLEAN);
CREATE TEMP MACRO sassy_contains_opts(pattern, text, k,
    alphabet := 'iupac', rc := true, all_endpoints := false) AS
    sassy_contains(pattern, text, k::BIGINT, alphabet::VARCHAR, rc::BOOLEAN, all_endpoints::BOOLEAN);
CREATE TEMP MACRO sassy_contains_many_opts(patterns, text, k,
    alphabet := 'iupac', rc := true, all_endpoints := false) AS
    sassy_contains_many(patterns, text, k::BIGINT, alphabet::VARCHAR, rc::BOOLEAN, all_endpoints::BOOLEAN);
CREATE TEMP MACRO sassy_crispr_matches_opts(guide, text, k, pam_length := 3,
    allow_pam_edits := false, max_n_frac := 0.2, rc := true) AS
    sassy_crispr_matches(guide, text, k::BIGINT, pam_length::BIGINT,
        allow_pam_edits::BOOLEAN, max_n_frac::DOUBLE, rc::BOOLEAN);
CREATE TEMP MACRO sassy_crispr_matches_many_opts(guides, text, k, pam_length := 3,
    allow_pam_edits := false, max_n_frac := 0.2, rc := true) AS
    sassy_crispr_matches_many(guides, text, k::BIGINT, pam_length::BIGINT,
        allow_pam_edits::BOOLEAN, max_n_frac::DOUBLE, rc::BOOLEAN);
