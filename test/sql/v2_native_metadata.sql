-- v2 names native parameters; stable v1 only exposes positional parameters.
SELECT CASE WHEN count(*) = 2 AND bool_and(parameters =
    ['guide', 'text', 'k', 'pam_length', 'rc', 'allow_pam_edits', 'max_n_frac'])
    AND bool_and(parameter_types[3:] = ['BIGINT', 'BIGINT', 'BOOLEAN', 'BOOLEAN', 'DOUBLE'])
    THEN true ELSE error('CRISPR native parameter contract') END
FROM duckdb_functions() WHERE function_name = '__sassy_crispr_matches';
