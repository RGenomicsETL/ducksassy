-- Query is pattern, reference is text, POS is text_start (zero-based).
-- Packed operations are in forward-reference order; text CIGAR stays in pattern order.
WITH cases(text, strand, cigar, ops, span) AS (
    VALUES
    ('GGACGTTGCACC', '+', '8=', [135::UINTEGER], 8),
    ('GGACGTTTGCACC', '+', '3=1D5=', [55::UINTEGER, 18, 87], 9),
    ('GGACGTGCACC', '+', '3=1I4=', [55::UINTEGER, 17, 71], 7),
    ('GGTGCAACGTCC', '-', '8=', [135::UINTEGER], 8),
    ('GGTGCAAACGTCC', '-', '3=1D5=', [87::UINTEGER, 18, 55], 9),
    ('GGTGCACGTCC', '-', '3=1I4=', [71::UINTEGER, 17, 55], 7)
), observed AS (
    SELECT c.*, h AS hit
    FROM cases c, UNNEST(sassy_matches('ACGTTGCA', c.text, 1,
        alphabet := 'dna', cigar_format := 'both')) AS t(h)
    WHERE h.strand = c.strand AND h.text_start = 2 AND h.pattern_start = 0
)
SELECT CASE WHEN count(*) = 6 AND bool_and(
    hit.cigar = cigar AND hit.cigar_ops = ops AND hit.text_end - hit.text_start = span
    AND list_sum(list_transform(hit.cigar_ops, x -> IF((x & 15) IN (7,8,2), x >> 4, 0))) = span
    AND list_sum(list_transform(hit.cigar_ops, x -> IF((x & 15) IN (7,8,1), x >> 4, 0))) =
        hit.pattern_end - hit.pattern_start)
    THEN true ELSE error('packed CIGAR order, axes or geometry') END FROM observed;

SELECT CASE WHEN (sassy_matches('ACGTTGCA', 'GGACGTTTGCACC', 1,
            alphabet := 'dna', cigar_format := 'packed'))[1].cigar IS NULL
    AND (sassy_matches('ACGTTGCA', 'GGACGTTTGCACC', 1,
            alphabet := 'dna', cigar_format := 'packed'))[1].cigar_ops = [55::UINTEGER, 18, 87]
    AND (sassy_matches_many(['ACGTTGCA', 'ACGTTGCA'], 'GGACGTTGCACC', 0,
            alphabet := 'dna', cigar_format := 'packed'))[2].cigar_ops = [135::UINTEGER]
    AND (sassy_matches_many(['ACGTTGCA'], 'GGACGTTGCACC', 0,
            alphabet := 'dna', cigar_format := 'both'))[1].cigar = '8='
    AND (sassy_matches('ACGTTGCA', 'GGACGTTGCACC', 0, alphabet := 'dna'))[1].cigar_ops IS NULL
    AND (sassy_matches('ACGTTGCA', 'GGACGTTGCACC', 0, alphabet := 'dna'))[1].cigar = '8='
    AND sassy_matches('ACGTTGCA', NULL, 0, cigar_format := 'packed') IS NULL
    AND sassy_matches('ACGTTGCA', 'GGGGGGGGGG', 0, cigar_format := 'packed') = []
    THEN true ELSE error('packed, panel, default or NULL contract') END;

WITH formats AS (
    SELECT i, CASE i % 3 WHEN 0 THEN 'text' WHEN 1 THEN 'packed'
                        ELSE 'both' END AS format
    FROM range(4096) t(i)
), results AS (
    SELECT i, format, sassy_matches('ACGTTGCA', 'GGACGTTGCACC', 0,
        alphabet := 'dna', cigar_format := format)[1] AS hit
    FROM formats
)
SELECT CASE WHEN count(*) = 4096 AND bool_and(
    hit.text_start = 2 AND
    CASE format WHEN 'text' THEN hit.cigar = '8=' AND hit.cigar_ops IS NULL
                WHEN 'packed' THEN hit.cigar IS NULL AND hit.cigar_ops = [135::UINTEGER]
                ELSE hit.cigar = '8=' AND hit.cigar_ops = [135::UINTEGER] END)
    THEN true ELSE error('row-varying cigar_format') END FROM results;

WITH inputs AS (
    SELECT i, CASE WHEN i % 3 = 0 THEN 'GGACGTTGCACC'
                   WHEN i % 3 = 1 THEN 'GGTGCAAACGTCC'
                   ELSE 'GGGGGGGGGG' END AS text
    FROM range(4096) t(i)
), outputs AS (
    SELECT i, sassy_matches('ACGTTGCA', text, 1, alphabet := 'dna',
        cigar_format := 'packed') AS hits
    FROM inputs
)
SELECT CASE WHEN count(*) = 4096 AND bool_and(
    CASE WHEN i % 3 = 2 THEN hits = []
         WHEN i % 3 = 0 THEN hits[1].cigar_ops = [135::UINTEGER]
         ELSE hits[1].cigar_ops = [87::UINTEGER, 18, 55] END)
    THEN true ELSE error('packed CIGAR output growth') END FROM outputs;
