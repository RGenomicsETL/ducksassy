-- Run after loading the v2 extension. The final statement must fail binding.
SELECT CASE WHEN __sassy_count('ACGA', 'ACGA', 0, 'dna', false, false) = 1
    THEN true ELSE error('native scalar probe') END;
CREATE TEMP MACRO __sassy_count(p, t, k) AS 42;
SELECT CASE WHEN __sassy_count('ACGA', 'ACGA', 0) = 42
    THEN true ELSE error('TEMP macro precedence') END;
SELECT __sassy_count('ACGA', 'ACGA', 0, 'dna', false, false);
