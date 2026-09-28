-- Value APIs are independent of file readers. Embedded NUL bytes are data.
SELECT CASE WHEN sassy_count('a' || chr(0) || 'b', 'xa' || chr(0) || 'by', 0,
    alphabet := 'ascii', rc := false) = 1 THEN true ELSE error('embedded NUL lost') END;
SELECT CASE WHEN len(sassy_crispr_matches('ACGTNGG', 'ACGTAGG', 0, rc := false)) = 1
    THEN true ELSE error('value CRISPR failed') END;

SELECT CASE WHEN sassy_count_many(list_select(
    ['ACGTTGCAACGTTGCA'::BLOB, 'TTTT'::BLOB, 'ACGTTGCAACGTTGCA'::BLOB], [3,1,3]),
    'ACGTTGCAACGTTGCA'::BLOB, 0, rc := false) = 3
    THEN true ELSE error('selected BLOB panel mismatch') END;

CREATE TEMP VIEW value_reads AS SELECT 'ACGT' AS sequence;
SELECT CASE WHEN count(*) = 1 THEN true ELSE error('value relation search') END
FROM sassy_search_table('value_reads', 'ACGT', 0, rc := false);
DROP VIEW value_reads;

-- Filtered/repeated list and string inputs exercise scalar flattening, child
-- validity and non-inline strings across multiple output chunks.
SET threads = 4;
CREATE TEMP TABLE host_inputs AS
SELECT i, CASE WHEN i % 7 = 0 THEN NULL ELSE 'ACGTTGCAACGTTGCA' END AS text,
       CASE WHEN i % 11 = 0 THEN NULL ELSE ['ACGTTGCAACGTTGCA', 'ACGTTGCAACGTTGCA'] END AS panel
FROM range(300000) t(i);
SELECT CASE WHEN count(*) = 0 THEN true ELSE error('filtered panel mismatch') END
FROM host_inputs WHERE i % 3 = 0 AND
    sassy_count_many(panel, text, 0, rc := false) IS DISTINCT FROM
        CASE WHEN text IS NULL OR panel IS NULL THEN NULL ELSE 2::UBIGINT END;
SELECT CASE WHEN count(*) = 0 THEN true ELSE error('filtered text mismatch') END
FROM host_inputs WHERE i % 5 = 0 AND
    sassy_contains('ACGTTGCAACGTTGCA', text, 0, rc := false) IS DISTINCT FROM
        CASE WHEN text IS NULL THEN NULL ELSE true END;
DROP TABLE host_inputs;
