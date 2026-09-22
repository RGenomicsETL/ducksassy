-- Executed by test/run_sql.py after installing the local artifact and DuckHTS.
SELECT CASE WHEN sassy_contains('ACGA', 'TTACGATT', 0, rc := false)
    THEN true ELSE error('contains') END;
SELECT CASE WHEN sassy_count('ACGA', 'TTTTTTTT', 0, rc := false) = 0
    THEN true ELSE error('no hit') END;
SELECT CASE WHEN sassy_matches(NULL::VARCHAR, 'ACGA', 0) IS NULL
    THEN true ELSE error('NULL propagation') END;
SELECT CASE WHEN sassy_matches('ACGA', '', 0, rc := false) = []
    THEN true ELSE error('empty text') END;
SELECT CASE WHEN sassy_matches_many([]::VARCHAR[], 'ACGA', 0, rc := false) = []
    THEN true ELSE error('empty panel') END;
SELECT CASE WHEN (sassy_matches('ACGA', 'TTACGATT', 0, rc := false)[1]).text_start = 2
    AND (sassy_matches('ACGA', 'TTACGATT', 0, rc := false)[1]).cigar = '4='
    THEN true ELSE error('coordinates and CIGAR') END;
SELECT CASE WHEN (sassy_matches('ACGA', 'TTTCGTTT', 0)[1]).strand = '-'
    THEN true ELSE error('reverse complement') END;
SELECT CASE WHEN sassy_count('ABC', 'XXXABCXXX', 1, alphabet := 'ascii', rc := false) = 1
    AND sassy_count('ABC', 'XXXABCXXX', 1, alphabet := 'ascii', rc := false, all_endpoints := true) = 3
    THEN true ELSE error('endpoint mode') END;
SELECT CASE WHEN sassy_count('ACGN', 'TTACGATT', 0, rc := false) = 1
    THEN true ELSE error('IUPAC') END;
SELECT CASE WHEN sassy_count_many(['ACGA','ACGA'], 'TTACGATT', 0, rc := false) = 2
    AND (sassy_matches_many(['ACGA','ACGA'], 'TTACGATT', 0, rc := false)[2]).pattern_idx = 1
    THEN true ELSE error('duplicate panel IDs') END;
SELECT CASE WHEN sassy_contains('ACGA'::BLOB, 'TTACGATT'::BLOB, 0, rc := false)
    THEN true ELSE error('BLOB overload') END;
SELECT CASE WHEN sassy_contains('CGT', repeat('A', 1048576) || 'CGT', 0,
                                alphabet := 'dna', rc := false)
    THEN true ELSE error('long sequence search') END;

-- Multiple chunks, changing inputs, filtering/dictionary candidates and NULLs.
CREATE TEMP TABLE sequences AS
    SELECT i AS record_id, CASE WHEN i % 5 = 0 THEN NULL ELSE 'TTACGATT' END AS sequence
    FROM range(8193) t(i);
SELECT CASE WHEN count(*) = 6554 THEN true ELSE error('multiple chunks') END
FROM sassy_search_table('sequences', 'ACGA', 0, rc := false);
SELECT CASE WHEN sum(sassy_count('ACGA', sequence, 0, rc := false)) = 3277
    THEN true ELSE error('filtered vectors') END
FROM sequences WHERE record_id % 2 = 0;
SET threads = 4;
SELECT CASE WHEN sum(sassy_count_many(['ACGA','ACGA'], sequence, 0, rc := false)) = 13108
    THEN true ELSE error('parallel panel reduction') END FROM sequences;

SELECT CASE WHEN count(*) = 2 THEN true ELSE error('DuckHTS FASTQ composition') END
FROM sassy_search_fastq('test/data/reads.fastq', 'ACGA', 0, rc := false);
SELECT CASE WHEN count(*) = 4 THEN true ELSE error('DuckHTS panel composition') END
FROM sassy_panel_search_fastq('test/data/reads.fastq', ['ACGA','ACGA'], 0, rc := false);
