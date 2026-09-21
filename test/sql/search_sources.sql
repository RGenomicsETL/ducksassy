-- Search wrappers preserve the columns emitted by DuckHTS's FASTA reader.
CREATE TEMP TABLE fasta_hits AS
SELECT name, hit.pattern_idx, hit.text_start, hit.text_end, hit.strand, hit.cost
FROM sassy_search_fasta('test/data/references.fasta', 'ACGTAGG', 0,
                        alphabet := 'iupac', rc := false);
CREATE TEMP TABLE expected_fasta AS
SELECT * FROM (VALUES
    ('forward', 0, 2, 9, '+', 0),
    ('masked', 0, 2, 9, '+', 0),
    ('ambiguous', 0, 2, 9, '+', 0)
) AS expected(name, pattern_idx, text_start, text_end, strand, cost);
SELECT CASE WHEN count(*) = 0 THEN true ELSE error('FASTA hit multiset') END
FROM (
    (SELECT * FROM fasta_hits EXCEPT ALL SELECT * FROM expected_fasta)
    UNION ALL
    (SELECT * FROM expected_fasta EXCEPT ALL SELECT * FROM fasta_hits)
) differences;
SELECT CASE WHEN actual.sequence IS NOT DISTINCT FROM original.sequence
                 AND actual.description IS NOT DISTINCT FROM original.description
            THEN true ELSE error('FASTA reader-column fidelity') END
FROM sassy_search_fasta('test/data/references.fasta', 'ACGTAGG', 0,
                        alphabet := 'iupac', rc := false) actual
JOIN read_fasta('test/data/references.fasta', scan_mode := 'sequential') original USING (name)
WHERE name = 'masked';
SELECT CASE WHEN count(*) = 4 AND count(*) FILTER (WHERE hit.pattern_idx = 1 AND name = 'reverse') = 1
            THEN true ELSE error('FASTA panel indices') END
FROM sassy_panel_search_fasta('test/data/references.fasta', ['ACGTAGG', 'CCTACGT'], 0,
                              alphabet := 'iupac', rc := false);

-- Row-varying motifs, arbitrary sequence column names and reference offsets.
CREATE TEMP TABLE relation_hits AS
WITH targets(record_id, start0, payload) AS (VALUES
    ('a', 100, 'TTACGTAGGAA'),
    ('b', 200, 'TTCCTACGTAA'),
    ('negative', 300, 'CCCCCCCCCC'),
    ('missing', 400, NULL::VARCHAR)
), motifs(motif_id, motif) AS (VALUES
    ('forward', 'ACGTAGG'), ('reverse', 'CCTACGT')
)
SELECT record_id, motif_id, targets.start0 + hit.text_start AS start0,
       targets.start0 + hit.text_end AS end0
FROM targets CROSS JOIN motifs
CROSS JOIN LATERAL unnest(sassy_matches(motif, payload, 0, rc := false)) AS matches(hit);
CREATE TEMP TABLE expected_relations AS
SELECT * FROM (VALUES ('a', 'forward', 102, 109), ('b', 'reverse', 202, 209))
AS expected(record_id, motif_id, start0, end0);
SELECT CASE WHEN count(*) = 0 THEN true ELSE error('direct relational search') END
FROM (
    (SELECT * FROM relation_hits EXCEPT ALL SELECT * FROM expected_relations)
    UNION ALL
    (SELECT * FROM expected_relations EXCEPT ALL SELECT * FROM relation_hits)
) differences;

WITH targets(record_id, payload) AS (VALUES
    ('a', 'TTACGTAGGAA'), ('b', 'TTCCTACGTAA'),
    ('negative', 'CCCCCCCCCC'), ('missing', NULL::VARCHAR)
)
SELECT CASE WHEN count(*) = 4 AND count(hit) = 1
            THEN true ELSE error('left lateral preserves unmatched and NULL inputs') END
FROM targets
LEFT JOIN LATERAL unnest(sassy_matches('ACGTAGG', payload, 0, rc := false)) AS matches(hit) ON true;

WITH selected_records AS (
    SELECT * FROM read_fasta('test/data/references.fasta', scan_mode := 'sequential')
    WHERE name = 'masked'
)
SELECT CASE WHEN count(*) = 1 THEN true ELSE error('CTE through query_table') END
FROM sassy_search_table('selected_records', 'ACGTAGG', 0, rc := false);
