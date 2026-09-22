library(Rducksassy)
con <- rducksassy_connect()
result <- DBI::dbGetQuery(con, "
  SELECT sassy_contains('timeout', 'request timedout', 1,
                        alphabet := 'ascii', rc := false) AS found")
stopifnot(isTRUE(result$found))
hits <- DBI::dbGetQuery(con, "
  SELECT * FROM sassy_grep('timeout', 'request timedout timeout', 1) LIMIT 1")
stopifnot(nrow(hits) == 1L, hits$cost <= 1L)
fasta <- tempfile(fileext = ".fa")
writeLines(c(">reference", "ACGTAGG"), fasta)
query <- paste0("SELECT count(*) AS n FROM sassy_crispr_search_fasta(",
                DBI::dbQuoteString(con, fasta), ", 'ACGTNGG', 0)")
stopifnot(as.numeric(DBI::dbGetQuery(con, query)$n) == 1)
unlink(fasta)
bam <- system.file("extdata", "crispr_reads.bam", package = "Rducksassy", mustWork = TRUE)
query <- paste0(
  "SELECT r.QNAME, hit.strand, hit.text_start, hit.text_end FROM read_bam(",
  DBI::dbQuoteString(con, bam), ") AS r CROSS JOIN LATERAL ",
  "UNNEST(sassy_crispr_matches('ACGTNGG', r.SEQ, 0)) AS matches(hit) ",
  "WHERE (r.FLAG & 2304) = 0 ORDER BY r.QNAME")
bam_hits <- DBI::dbGetQuery(con, query)
stopifnot(identical(bam_hits$QNAME, c("forward", "reverse")),
          identical(bam_hits$strand, c("+", "-")),
          all(bam_hits$text_start == 0), all(bam_hits$text_end == 7))
DBI::dbDisconnect(con, shutdown = TRUE)
