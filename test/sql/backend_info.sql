-- Diagnostics do not initialize the native search backend.
SELECT CASE WHEN list(name ORDER BY name) = ['avx2', 'avx512', 'neon', 'scalar', 'wasm128']
    AND count(*) FILTER (WHERE selected) = 0
    AND bool_and(typeof(compiled) = 'BOOLEAN' AND typeof(supported) = 'BOOLEAN')
    THEN true ELSE error('initial backend diagnostics') END
FROM sassy_backend_info();

SELECT CASE WHEN compiled AND supported AND NOT selected
    THEN true ELSE error('scalar backend availability') END
FROM sassy_backend_info() WHERE name = 'scalar';

SELECT CASE WHEN sassy_count('ACGA', 'TTACGATT', 0, alphabet := 'dna', rc := false) = 1
    THEN true ELSE error('backend initialization search') END;

SELECT CASE WHEN count(*) FILTER (WHERE selected) = 1
    AND bool_and(NOT selected OR (compiled AND supported))
    THEN true ELSE error('selected backend eligibility') END
FROM sassy_backend_info();

SELECT CASE WHEN count(*) = 8193 * 5 AND count(*) FILTER (WHERE backend.selected) = 8193
    AND count(*) FILTER (WHERE backend.name IS NULL) = 0
    THEN true ELSE error('multi-chunk backend diagnostics') END
FROM (SELECT UNNEST(__sassy_backend_info()) AS backend FROM range(8193));
