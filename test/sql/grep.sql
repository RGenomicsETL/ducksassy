-- A window boundary may split a match. The table scan must preserve the
-- whole-value all-endpoints result, including its alignment trace.
WITH expected AS (
    SELECT hit.text_start AS text_start, hit.text_end AS text_end,
           hit.cost AS cost, hit.cigar AS cigar
    FROM unnest(sassy_matches('error',
        repeat('x', 1021) || 'error' || repeat('x', 1022) || 'errot',
        1, alphabet := 'ascii', rc := false, all_endpoints := true)) AS matches(hit)
), actual AS (
    SELECT * FROM sassy_grep('error',
        repeat('x', 1021) || 'error' || repeat('x', 1022) || 'errot', 1)
), differences AS (
    (SELECT * FROM expected EXCEPT ALL SELECT * FROM actual)
    UNION ALL
    (SELECT * FROM actual EXCEPT ALL SELECT * FROM expected)
)
SELECT CASE WHEN count(*) = 0 THEN true
            ELSE error('sassy_grep differs from whole-value search') END
FROM differences;

SELECT CASE WHEN count(*) = 1 AND min(text_start) = 1 AND min(text_end) = 4
    THEN true ELSE error('sassy_grep embedded NUL bytes') END
FROM sassy_grep('a' || chr(0) || 'b', 'xa' || chr(0) || 'by', 0);

-- A long flat run exercises many overlapping windows and repeated endpoints.
WITH expected AS (
    SELECT hit.text_start AS text_start, hit.text_end AS text_end,
           hit.cost AS cost, hit.cigar AS cigar
    FROM unnest(sassy_matches('aaaa', repeat('a', 4097), 1,
        alphabet := 'ascii', rc := false, all_endpoints := true)) AS matches(hit)
), actual AS (
    SELECT * FROM sassy_grep('aaaa', repeat('a', 4097), 1)
), differences AS (
    (SELECT * FROM expected EXCEPT ALL SELECT * FROM actual)
    UNION ALL
    (SELECT * FROM actual EXCEPT ALL SELECT * FROM expected)
)
SELECT CASE WHEN count(*) = 0 THEN true
            ELSE error('sassy_grep loses repeated endpoints') END
FROM differences;
