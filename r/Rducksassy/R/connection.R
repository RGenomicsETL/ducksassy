#' Open a DuckDB connection with Ducksassy loaded
#'
#' Creates an isolated DuckDB database handle, opens a DBI connection, and
#' loads the extension bundled with Rducksassy. The database handle permits
#' unsigned extensions because locally built DuckDB extensions are not signed.
#'
#' @param dbdir Database file path or `":memory:"`.
#' @param read_only Open an existing database without write access.
#' @param config Named DuckDB configuration values.
#' @param ... Additional arguments passed to [duckdb::duckdb()].
#'
#' @return A live DuckDB DBI connection. Disconnect it with
#'   `DBI::dbDisconnect(con, shutdown = TRUE)`.
#' @export
#' @examples
#' con <- rducksassy_connect()
#' DBI::dbGetQuery(con, "SELECT sassy_contains('ACGT', 'TTACGT', 0)")
#' DBI::dbDisconnect(con, shutdown = TRUE)
rducksassy_connect <- function(dbdir = ":memory:", read_only = FALSE,
                               config = list(), ...) {
  config$allow_unsigned_extensions <- "true"
  driver <- duckdb::duckdb(
    dbdir = dbdir,
    read_only = read_only,
    config = config,
    shared_home = FALSE,
    ...
  )
  con <- DBI::dbConnect(driver)
  loaded <- FALSE
  on.exit({
    if (!loaded) DBI::dbDisconnect(con, shutdown = TRUE)
  }, add = TRUE)
  rducksassy_load(con)
  loaded <- TRUE
  con
}

#' Load Ducksassy into a DuckDB connection
#'
#' Loads the extension bundled with Rducksassy into an existing compatible
#' DuckDB DBI connection.
#'
#' @param con A DuckDB DBI connection.
#'
#' @return `con`, invisibly.
#' @export
#' @examples
#' driver <- duckdb::duckdb(
#'   config = list(allow_unsigned_extensions = "true"),
#'   shared_home = FALSE
#' )
#' con <- DBI::dbConnect(driver)
#' rducksassy_load(con)
#' DBI::dbDisconnect(con, shutdown = TRUE)
rducksassy_load <- function(con) {
  extension <- list.files(
    system.file("libs", package = "Rducksassy", mustWork = TRUE),
    pattern = "^ducksassy[.]duckdb_extension$",
    full.names = TRUE,
    recursive = TRUE
  )
  if (length(extension) != 1L) {
    stop("Could not locate the packaged Ducksassy extension.", call. = FALSE)
  }
  DBI::dbExecute(con, paste("LOAD", DBI::dbQuoteString(con, extension)))
  invisible(con)
}
