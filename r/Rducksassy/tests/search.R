library(Rducksassy)

local({
  con <- rducksassy_connect()
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)

  found <- DBI::dbGetQuery(con, "
    SELECT sassy_contains('timeout', 'request timedout', 1, 'ascii', false) AS found")
  stopifnot(isTRUE(found$found))

  hits <- DBI::dbGetQuery(con, "
    SELECT * FROM sassy_grep('timeout', 'request timedout timeout', 1) LIMIT 1")
  stopifnot(nrow(hits) == 1L, hits$cost <= 1L)

  guides <- DBI::dbGetQuery(con, "
    SELECT len(sassy_crispr_matches('ACGTNGG', 'TTACGTAGGTT', 0)) AS n")
  stopifnot(as.numeric(guides$n) == 1)

  backends <- DBI::dbGetQuery(con, "SELECT * FROM sassy_backend_info()")
  stopifnot(sum(backends$selected) == 1L)
})
