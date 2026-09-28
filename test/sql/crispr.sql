-- The eight input records include ambiguity, masking, both indel directions and a PAM edit.
SELECT CASE WHEN count(*) = 8 THEN true ELSE error('CRISPR physical input count') END
FROM read_fasta('test/data/references.fasta', scan_mode := 'sequential');
CREATE TEMP TABLE crispr_hits AS
SELECT name, hit.pattern_idx, hit.text_start, hit.text_end, hit.strand, hit.cost, hit.cigar
FROM sassy_crispr_search_fasta('test/data/references.fasta', 'ACGTNGG', 0);
CREATE TEMP TABLE expected_crispr AS
SELECT * FROM (VALUES
    ('forward', 0, 2, 9, '+', 0, '7='),
    ('masked', 0, 2, 9, '+', 0, '7='),
    ('reverse', 0, 2, 9, '-', 0, '7=')
) AS expected(name, pattern_idx, text_start, text_end, strand, cost, cigar);
SELECT CASE WHEN count(*) = 0 THEN true ELSE error('CRISPR exact hit multiset') END
FROM (
    (SELECT * FROM crispr_hits EXCEPT ALL SELECT * FROM expected_crispr)
    UNION ALL
    (SELECT * FROM expected_crispr EXCEPT ALL SELECT * FROM crispr_hits)
) differences;
SELECT CASE WHEN count(*) = 6 AND count(*) FILTER (WHERE hit.pattern_idx = 1) = 3
            THEN true ELSE error('CRISPR duplicate panel indices') END
FROM sassy_crispr_panel_search_fasta('test/data/references.fasta', ['ACGTNGG', 'ACGTNGG'], 0);

SELECT CASE WHEN len(sassy_crispr_matches('ACGTNGG', 'ACGTAAG', 1, rc := false)) = 0
            AND len(sassy_crispr_matches('ACGTNGG', 'ACGTAAG', 1, rc := false, allow_pam_edits := true)) > 0
            THEN true ELSE error('PAM edit policy') END;
SELECT CASE WHEN count(*) = 2 THEN true ELSE error('insertion and deletion hits') END
FROM sassy_crispr_search_fasta('test/data/references.fasta', 'ACGTNGG', 1, rc := false)
WHERE (name = 'insertion' AND hit.text_start = 2 AND hit.text_end = 10 AND hit.cost = 1)
   OR (name = 'deletion' AND hit.text_start = 2 AND hit.text_end = 8 AND hit.cost = 1);
SELECT CASE WHEN len(sassy_crispr_matches('ACGTNGG', 'ACGTnGG', 0, rc := false, max_n_frac := 0)) = 0
            AND len(sassy_crispr_matches('ACGTNGG', 'ACGTnGG', 0, rc := false, max_n_frac := 1.0/7)) = 1
            THEN true ELSE error('N fraction over complete target match') END;
SELECT CASE WHEN len(sassy_crispr_matches('ANNN', 'A', 3)) = 0
            THEN true ELSE error('short PAM prefix must not panic') END;
SELECT CASE WHEN sassy_crispr_matches(NULL::VARCHAR, 'ACGTAGG', 0) IS NULL
            AND sassy_crispr_matches('ACGTNGG', 'ACGTAGG', 0, max_n_frac := NULL) IS NULL
            AND len(sassy_crispr_matches_many([]::VARCHAR[], 'ACGTAGG', 0)) = 0
            THEN true ELSE error('CRISPR NULL and empty panel') END;
SELECT CASE WHEN sassy_crispr_matches('ACGTNGG'::BLOB, 'ACGTAGG'::BLOB, 0, rc := false)
                 = sassy_crispr_matches('ACGTNGG', 'ACGTAGG', 0, rc := false)
            THEN true ELSE error('CRISPR BLOB overload') END;

CREATE TEMP VIEW crispr_records AS
SELECT * FROM read_fasta('test/data/references.fasta', scan_mode := 'sequential');
SELECT CASE WHEN count(*) = 3 THEN true ELSE error('CRISPR named relation') END
FROM sassy_crispr_search_table('crispr_records', 'ACGTNGG', 0);
SELECT CASE WHEN count(*) = 6 THEN true ELSE error('CRISPR panel relation') END
FROM sassy_crispr_panel_search_table('crispr_records', ['ACGTNGG', 'ACGTNGG'], 0);

-- Row-varying options and NULLs across multiple DuckDB vectors and workers.
CREATE TEMP TABLE crispr_stream AS
SELECT i,
       CASE WHEN i % 7 = 0 THEN NULL ELSE 'ACGTNGG' END AS guide,
       CASE WHEN i % 11 = 0 THEN NULL
            WHEN i % 4 = 0 THEN 'ACGTnGG'
            WHEN i % 4 = 1 THEN 'CCTACGT'
            WHEN i % 4 = 2 THEN 'ACGTAGG'
            ELSE 'CCCCCCC' END AS target,
       i % 3 != 0 AS rc,
       CASE WHEN i % 13 = 0 THEN NULL WHEN i % 5 = 0 THEN 0.0 ELSE 1.0 END AS n_frac,
       (i % 7 != 0 AND i % 11 != 0 AND i % 13 != 0 AND
        (i % 4 = 2 OR (i % 4 = 0 AND i % 5 != 0) OR (i % 4 = 1 AND i % 3 != 0)))::INTEGER AS expected
FROM range(8193) rows(i);
SET threads=1;
CREATE TEMP TABLE crispr_single_thread AS
SELECT i, coalesce(len(sassy_crispr_matches(guide, target, 0, rc := rc, max_n_frac := n_frac)), 0) AS actual
FROM crispr_stream;
SET threads=4;
SELECT CASE WHEN count(*) = 8193 AND bool_and(single.actual = expected)
                 AND bool_and(coalesce(len(sassy_crispr_matches(guide, target, 0, rc := rc, max_n_frac := n_frac)), 0) = expected)
            THEN true ELSE error('CRISPR multi-vector options and NULLs') END
FROM crispr_stream JOIN crispr_single_thread single USING (i);

-- Heterogeneous PAMs live in separate guide rows, without a materialized panel.
WITH guides(guide_id, guide, pam_length) AS (VALUES
    ('g1', 'ACGTNGG', 3), ('g2', 'ACGTAGG', 2)
), targets(record_id, reference_start0, bases) AS (VALUES
    ('locus', 1000, 'TTACGTAGGAA')
)
SELECT CASE WHEN count(*) = 2 AND bool_and(reference_start0 + hit.text_start = 1002)
            THEN true ELSE error('guide/target relations with row-varying PAM length') END
FROM guides CROSS JOIN targets
CROSS JOIN LATERAL unnest(sassy_crispr_matches(guide, bases, 0,
    pam_length := pam_length, rc := false)) AS matches(hit);
