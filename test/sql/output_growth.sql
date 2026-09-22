-- Long CIGARs require arena storage. More than 2048 hits per input chunk
-- forces output growth after some CIGARs have already been written.
CREATE TEMP TABLE growth_inputs AS
SELECT i AS row_id,
       CASE WHEN i % 5 = 0 THEN NULL
            WHEN i % 5 = 1 THEN 'zzzz'
            ELSE repeat('ab!de!gh!jk!mn!#', 32) END AS text
FROM range(4097) AS rows(i);

CREATE TEMP TABLE growth_results AS
SELECT row_id, sassy_matches('abcdefghijklmno', text, 5,
                            alphabet := 'ascii', rc := false) AS hits
FROM growth_inputs;

SELECT CASE WHEN count(*) FILTER (WHERE row_id % 5 = 0 AND hits IS NULL) = 820
             AND count(*) FILTER (WHERE row_id % 5 = 1 AND len(hits) = 0) = 820
             AND count(*) FILTER (WHERE row_id % 5 > 1 AND len(hits) = 32) = 2457
            THEN true ELSE error('output growth: NULL, empty or populated lists') END
FROM growth_results;

CREATE TEMP TABLE growth_actual AS
SELECT row_id, hit.*
FROM (SELECT row_id, unnest(hits) AS hit FROM growth_results);

CREATE TEMP TABLE growth_expected AS
SELECT row_id, 0::UBIGINT AS pattern_idx,
       (j * 16)::UBIGINT AS text_start, (j * 16 + 15)::UBIGINT AS text_end,
       0::UBIGINT AS pattern_start, 15::UBIGINT AS pattern_end,
       5::INTEGER AS cost, '+' AS strand, '2=1X2=1X2=1X2=1X2=1X' AS cigar
FROM growth_inputs CROSS JOIN range(32) AS matches(j)
WHERE row_id % 5 > 1;

SELECT CASE WHEN count(*) = 0 THEN true ELSE error('output growth: corrupted hit fields') END
FROM (
    (SELECT * FROM growth_actual EXCEPT ALL SELECT * FROM growth_expected)
    UNION ALL
    (SELECT * FROM growth_expected EXCEPT ALL SELECT * FROM growth_actual)
);

-- A later invocation must not reuse pointers from an earlier result chunk.
SELECT CASE WHEN bool_and(hits IS NOT DISTINCT FROM
                    sassy_matches('abcdefghijklmno', text, 5,
                                  alphabet := 'ascii', rc := false))
            THEN true ELSE error('output growth: repeated invocation') END
FROM growth_results JOIN growth_inputs USING (row_id);
