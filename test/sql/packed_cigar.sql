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
    FROM cases c, UNNEST(sassy_matches_both('ACGTTGCA', c.text, 1, alphabet := 'dna')) AS t(h)
    WHERE h.strand = c.strand AND h.text_start = 2 AND h.pattern_start = 0
)
SELECT CASE WHEN count(*) = 6 AND bool_and(
    hit.cigar = cigar AND hit.cigar_ops = ops AND hit.text_end - hit.text_start = span
    AND list_sum(list_transform(hit.cigar_ops, x -> IF((x & 15) IN (7,8,2), x >> 4, 0))) = span
    AND list_sum(list_transform(hit.cigar_ops, x -> IF((x & 15) IN (7,8,1), x >> 4, 0))) =
        hit.pattern_end - hit.pattern_start)
    THEN true ELSE error('packed CIGAR order, axes or geometry') END FROM observed;

SELECT CASE WHEN (sassy_matches_packed('ACGTTGCA', 'GGACGTTTGCACC', 1, alphabet := 'dna'))[1].cigar IS NULL
    AND (sassy_matches_packed('ACGTTGCA', 'GGACGTTTGCACC', 1, alphabet := 'dna'))[1].cigar_ops = [55::UINTEGER, 18, 87]
    AND (sassy_matches_many_packed(['ACGTTGCA', 'ACGTTGCA'], 'GGACGTTGCACC', 0,
            alphabet := 'dna'))[2].cigar_ops = [135::UINTEGER]
    AND (sassy_matches_many_both(['ACGTTGCA'], 'GGACGTTGCACC', 0,
            alphabet := 'dna'))[1].cigar = '8='
    AND sassy_matches_packed('ACGTTGCA', NULL, 0) IS NULL
    AND sassy_matches_packed('ACGTTGCA', 'GGGGGGGGGG', 0) = []
    THEN true ELSE error('packed-only, panel or NULL contract') END;

WITH partials(text, strand, start_pos, end_pos) AS (
    VALUES ('ATCGGGGGGGGGG', '+', 4, 8), ('CGATGGGGGGGGG', '-', 0, 4)
), observed AS (
    SELECT p.*, hit FROM partials p,
         UNNEST(sassy_matches_both_overhang('ATCGATCG', p.text, 2)) t(hit)
    WHERE hit.strand = p.strand AND hit.pattern_start = p.start_pos
          AND hit.pattern_end = p.end_pos AND hit.text_start = 0 AND hit.cigar = '4='
)
SELECT CASE WHEN count(*) = 2 AND bool_and(
    hit.cigar_ops = [68::UINTEGER, 71] AND hit.text_end - hit.text_start = 4
    AND list_sum(list_transform(hit.cigar_ops, x -> IF((x & 15) IN (7,8,2), x >> 4, 0))) = 4
    AND list_sum(list_transform(hit.cigar_ops, x -> IF((x & 15) IN (7,8,1), x >> 4, 0))) = 4)
    THEN true ELSE error('partial alignment and SAM clip orientation') END FROM observed;

WITH inputs AS (
    SELECT i, CASE WHEN i % 3 = 0 THEN 'GGACGTTGCACC'
                   WHEN i % 3 = 1 THEN 'GGTGCAAACGTCC'
                   ELSE 'GGGGGGGGGG' END AS text
    FROM range(4096) t(i)
), outputs AS (
    SELECT i, sassy_matches_packed('ACGTTGCA', text, 1, alphabet := 'dna') AS hits
    FROM inputs
)
SELECT CASE WHEN count(*) = 4096 AND bool_and(
    CASE WHEN i % 3 = 2 THEN hits = []
         WHEN i % 3 = 0 THEN hits[1].cigar_ops = [135::UINTEGER]
         ELSE hits[1].cigar_ops = [87::UINTEGER, 18, 55] END)
    THEN true ELSE error('packed CIGAR output growth') END FROM outputs;
