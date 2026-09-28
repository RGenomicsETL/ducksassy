-- Native positional calls compose with DuckHTS and relations through lateral joins.
CREATE TEMP TABLE fasta_hits AS
SELECT r.name, hit.pattern_idx, hit.text_start, hit.text_end, hit.strand, hit.cost
FROM read_fasta('test/data/references.fasta', scan_mode := 'sequential') r
CROSS JOIN LATERAL unnest(sassy_matches('ACGTAGG', r.sequence, 0, 'iupac', false)) AS m(hit);
CREATE TEMP TABLE expected_fasta AS
SELECT * FROM (VALUES ('forward', 0, 2, 9, '+', 0), ('masked', 0, 2, 9, '+', 0),
    ('ambiguous', 0, 2, 9, '+', 0)) AS e(name, pattern_idx, text_start, text_end, strand, cost);
SELECT CASE WHEN count(*) = 0 THEN true ELSE error('native FASTA multiset') END
FROM ((SELECT * FROM fasta_hits EXCEPT ALL SELECT * FROM expected_fasta)
      UNION ALL (SELECT * FROM expected_fasta EXCEPT ALL SELECT * FROM fasta_hits));
SELECT CASE WHEN count(*) = 3 AND bool_and(hit.cigar IS NULL AND hit.cigar_ops = [119::UINTEGER])
    THEN true ELSE error('native FASTA packed') END
FROM read_fasta('test/data/references.fasta', scan_mode := 'sequential') r
CROSS JOIN LATERAL unnest(sassy_matches('ACGTAGG', r.sequence, 0, 'iupac', false, false, 'packed')) AS m(hit);
SELECT CASE WHEN count(*) = 4 AND count(*) FILTER (WHERE hit.pattern_idx = 1 AND name = 'reverse') = 1
    THEN true ELSE error('native FASTA panel') END
FROM read_fasta('test/data/references.fasta', scan_mode := 'sequential') r
CROSS JOIN LATERAL unnest(sassy_matches_many(['ACGTAGG','CCTACGT'], r.sequence, 0, 'iupac', false)) AS m(hit);
SELECT CASE WHEN count(*) = 2 THEN true ELSE error('native FASTQ') END
FROM read_fastq('test/data/reads.fastq', scan_mode := 'sequential') r
CROSS JOIN LATERAL unnest(sassy_matches('ACGA', r.sequence, 0, 'iupac', false)) AS m(hit);
SELECT CASE WHEN count(*) = 4 THEN true ELSE error('native FASTQ panel') END
FROM read_fastq('test/data/reads.fastq', scan_mode := 'sequential') r
CROSS JOIN LATERAL unnest(sassy_matches_many(['ACGA','ACGA'], r.sequence, 0, 'iupac', false)) AS m(hit);
CREATE TEMP TABLE crispr_hits AS
SELECT name, hit.pattern_idx, hit.text_start, hit.text_end, hit.strand, hit.cost, hit.cigar
FROM read_fasta('test/data/references.fasta', scan_mode := 'sequential') r
CROSS JOIN LATERAL unnest(sassy_crispr_matches('ACGTNGG', r.sequence, 0)) AS m(hit);
CREATE TEMP TABLE expected_crispr AS
SELECT * FROM (VALUES ('forward',0,2,9,'+',0,'7='), ('masked',0,2,9,'+',0,'7='),
    ('reverse',0,2,9,'-',0,'7=')) AS e(name,pattern_idx,text_start,text_end,strand,cost,cigar);
SELECT CASE WHEN count(*) = 0 THEN true ELSE error('native CRISPR multiset') END
FROM ((SELECT * FROM crispr_hits EXCEPT ALL SELECT * FROM expected_crispr)
      UNION ALL (SELECT * FROM expected_crispr EXCEPT ALL SELECT * FROM crispr_hits));
SELECT CASE WHEN count(*) = 6 AND count(*) FILTER (WHERE hit.pattern_idx = 1) = 3
    THEN true ELSE error('native CRISPR panel') END
FROM read_fasta('test/data/references.fasta', scan_mode := 'sequential') r
CROSS JOIN LATERAL unnest(sassy_crispr_matches_many(['ACGTNGG','ACGTNGG'], r.sequence, 0)) AS m(hit);
SELECT CASE WHEN len(sassy_crispr_matches('ACGTNGG','ACGTAAG',1,3,false,0.2,false)) = 0
    AND len(sassy_crispr_matches('ACGTNGG','ACGTAAG',1,3,true,0.2,false)) > 0
    AND len(sassy_crispr_matches('ACGTNGG','ACGTnGG',0,3,false,0.0,false)) = 0
    AND len(sassy_crispr_matches('ACGTNGG','ACGTnGG',0,3,false,1.0/7,false)) = 1
    THEN true ELSE error('native PAM edits and N fraction') END;
WITH targets(id, bases) AS (VALUES ('a','TTACGTAGGAA'),('b','TTCCTACGTAA'),('none','CCCC'),('null',NULL))
SELECT CASE WHEN count(*) = 4 AND count(hit) = 1 THEN true ELSE error('native left lateral') END
FROM targets LEFT JOIN LATERAL unnest(sassy_matches('ACGTAGG', bases, 0, 'iupac', false)) AS m(hit) ON true;
CREATE TEMP TABLE crispr_stream AS
SELECT i, CASE WHEN i % 7 = 0 THEN NULL ELSE 'ACGTNGG' END AS guide,
    CASE WHEN i % 11 = 0 THEN NULL WHEN i % 4 = 0 THEN 'ACGTnGG'
         WHEN i % 4 = 1 THEN 'CCTACGT' WHEN i % 4 = 2 THEN 'ACGTAGG' ELSE 'CCCCCCC' END AS target,
    i % 3 != 0 AS rc,
    CASE WHEN i % 13 = 0 THEN NULL WHEN i % 5 = 0 THEN 0.0 ELSE 1.0 END AS n_frac,
    (i % 7 != 0 AND i % 11 != 0 AND i % 13 != 0 AND
     (i % 4 = 2 OR (i % 4 = 0 AND i % 5 != 0) OR (i % 4 = 1 AND i % 3 != 0)))::INTEGER AS expected
FROM range(300000) rows(i);
SET threads=4;
SELECT CASE WHEN count(*) = 300000 AND bool_and(
    coalesce(len(sassy_crispr_matches(guide, target, 0, 3, false, n_frac, rc)), 0) = expected)
    THEN true ELSE error('native CRISPR vector options') END FROM crispr_stream;
WITH guides(guide,pam_length) AS (VALUES ('ACGTNGG',3),('ACGTAGG',2))
SELECT CASE WHEN count(*) = 2 AND bool_and(hit.text_start = 2) THEN true ELSE error('native PAM column') END
FROM guides CROSS JOIN LATERAL unnest(sassy_crispr_matches(guide,'TTACGTAGGAA',0,pam_length,false,0.2,false)) AS m(hit);
