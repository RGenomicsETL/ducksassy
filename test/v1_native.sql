-- LOAD alone exposes native functions, including on a read-only primary database.
SELECT CASE WHEN count(*) = 10 AND bool_and(function_type IN ('scalar', 'table') AND internal)
    THEN true ELSE error('native public catalog') END
FROM (SELECT DISTINCT function_name, function_type, internal FROM duckdb_functions()
      WHERE function_name LIKE 'sassy_%');
SELECT CASE WHEN count(*) = 2 AND bool_and(parameter_types[3:] =
    ['BIGINT', 'BIGINT', 'BOOLEAN', 'DOUBLE', 'BOOLEAN'])
    THEN true ELSE error('native CRISPR positional contract') END
FROM duckdb_functions() WHERE function_name = 'sassy_crispr_matches' AND len(parameter_types) = 7;
SELECT CASE WHEN count(*) = 0 THEN true ELSE error('loader macro DDL') END
FROM duckdb_functions() WHERE function_name LIKE '%sassy%' AND function_type LIKE '%macro%';

SELECT CASE WHEN sassy_count('ACGA', 'TTACGA', 0) = 1
    AND sassy_count('ACGA'::BLOB, 'TTACGA'::BLOB, 0) = 1
    AND sassy_count('AN', 'AT', 0) > 0
    AND sassy_contains('ACGA', 'TTACGA', 0)
    AND sassy_matches('ACGA', 'ACGA', 0)[1].cigar = '4='
    AND sassy_matches('ACGA', 'ACGA', 0)[1].cigar_ops IS NULL
    AND sassy_count_many(['ACGA', 'ACGA'], 'ACGA', 0) = 2
    AND sassy_contains_many(['ACGA']::BLOB[], 'ACGA'::BLOB, 0)
    AND sassy_count_many([]::VARCHAR[], 'ACGA', 0) = 0
    AND sassy_matches_many([]::BLOB[], 'ACGA'::BLOB, 0) = []
    AND sassy_matches_many(NULL::VARCHAR[], 'ACGA', 0) IS NULL
    AND sassy_matches('ACGA', NULL, 0) IS NULL
    AND sassy_count('ACGA', 'ACGA', NULL) IS NULL
    THEN true ELSE error('native defaults, panel or NULL') END;
SELECT CASE WHEN len(sassy_crispr_matches('ACGTNGG', 'ACGTAGG', 0)) = 1
    AND len(sassy_crispr_matches_many(['ACGTNGG']::BLOB[], 'ACGTAGG'::BLOB, 0)) = 1
    AND len(sassy_crispr_matches('ACGTNGG', 'ACGTAGG', 0, 3, false, 0.2, false)) = 1
    THEN true ELSE error('native CRISPR defaults') END;
SELECT CASE WHEN sassy_count('a' || chr(0) || 'b', 'xa' || chr(0) || 'by', 0, 'ascii', false) = 1
    AND (SELECT count(*) FROM sassy_grep('a' || chr(0) || 'b', 'xa' || chr(0) || 'by', 0)) = 1
    AND (SELECT text_end FROM sassy_grep('\x41', 'x\x41y', 0)) = 5
    THEN true ELSE error('native VARCHAR byte preservation') END;
SELECT CASE WHEN count(*) = 5 AND count(*) FILTER (WHERE selected) = 1
    THEN true ELSE error('native backend table') END FROM sassy_backend_info();

SET threads=4;
CREATE TEMP TABLE native_inputs AS
SELECT i, CASE WHEN i % 11 = 0 THEN NULL WHEN i % 3 = 0 THEN 'GGACGTTGCACC'
              WHEN i % 3 = 1 THEN 'GGTGCAAACGTCC' ELSE 'GGGGGGGGGG' END AS text,
       CASE i % 3 WHEN 0 THEN 'text' WHEN 1 THEN 'packed' ELSE 'both' END AS format
FROM range(300000) t(i);
SELECT CASE WHEN count(*) = 0 THEN true ELSE error('native filtered mixed packed output') END
FROM (
    SELECT i, text, format, sassy_matches_many(['ACGTTGCA', 'ACGTTGCA'], text, 1,
        'dna', true, false, format) AS hits
    FROM native_inputs WHERE i % 5 = 0
) WHERE CASE WHEN text IS NULL THEN hits IS NOT NULL
             WHEN i % 3 = 2 THEN hits IS DISTINCT FROM []
             WHEN i % 3 = 0 THEN hits[1].cigar IS DISTINCT FROM '8=' OR hits[1].cigar_ops IS NOT NULL
             ELSE hits[1].cigar IS NOT NULL OR hits[1].cigar_ops IS DISTINCT FROM [87::UINTEGER, 18, 55] END;
DROP TABLE native_inputs;
