#' Open a DuckDB connection with Ducksassy and DuckHTS
#'
#' Uses the DuckDB C API v2 preview host supplied by \pkg{duckdb.2.0.dev}.
#' The connection allows loading the extensions built by the R packages.
#' Automatic extension downloads are disabled.
#'
#' @param dbdir Database file or \code{":memory:"}.
#' @param read_only Open an existing database read-only.
#' @return A DBI connection. Close it with \code{DBI::dbDisconnect(con, shutdown = TRUE)}.
#' @export
#' @examples
#' con <- rducksassy_connect()
#' DBI::dbGetQuery(con, "SELECT * FROM sassy_grep('timeout', 'request timedout', 1)")
#' DBI::dbDisconnect(con, shutdown = TRUE)
rducksassy_connect <- function(dbdir = ":memory:", read_only = FALSE) {
  driver <- duckdb.2.0.dev::duckdb(
    dbdir = dbdir, read_only = read_only, shared_home = FALSE,
    config = list(allow_unsigned_extensions = "true",
                  autoinstall_known_extensions = "false",
                  autoload_known_extensions = "false")
  )
  con <- DBI::dbConnect(driver)
  loaded <- FALSE
  on.exit(if (!loaded) DBI::dbDisconnect(con, shutdown = TRUE))
  rducksassy_load(con)
  loaded <- TRUE
  con
}

#' Load Ducksassy and its SQL bindings
#'
#' Loads the package-built DuckHTS and Ducksassy extensions into an existing
#' DuckDB v2 preview connection. The connection must permit unsigned extensions.
#'
#' @param con An existing DuckDB v2 preview DBI connection.
#' @return Invisibly, the supplied connection.
#' @export
rducksassy_load <- function(con) {
  # Use the packaged extension directly: loading Rduckhts's R namespace also
  # loads the stable duckdb driver, whose DBI methods conflict with the preview.
  duckhts <- system.file("duckhts_extension", "build", "duckhts.duckdb_extension",
                         package = "Rduckhts", mustWork = TRUE)
  DBI::dbExecute(con, "SET GLOBAL lambda_syntax='ENABLE_SINGLE_ARROW'")
  DBI::dbExecute(con, paste("LOAD", DBI::dbQuoteString(con, duckhts)))
  extension <- system.file("libs", .Platform$r_arch, "ducksassy.duckdb_extension",
                           package = "Rducksassy", mustWork = TRUE)
  DBI::dbExecute(con, paste("LOAD", DBI::dbQuoteString(con, extension)))
  bindings <- system.file("sql", "ducksassy.sql", package = "Rducksassy", mustWork = TRUE)
  DBI::dbExecute(con, paste(readLines(bindings, warn = FALSE), collapse = "\n"))
  invisible(con)
}
