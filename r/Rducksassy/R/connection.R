#' Open a DuckDB connection with Ducksassy and DuckHTS
#'
#' Requires a DuckDB host with C API v2 support and the suggested
#' \code{Rduckhts} package for its installed extension files.
#' The connection allows loading the extensions built by the R packages.
#' Automatic extension downloads are disabled.
#'
#' @param dbdir Database file or \code{":memory:"}.
#' @param read_only Open an existing database read-only.
#' @param driver Driver constructor, defaulting to \code{duckdb::duckdb}.
#'   Supply another DuckDB DBI driver constructor for a host with C API v2
#'   support. It receives \code{dbdir}, \code{read_only} and \code{config}.
#' @return A DBI connection. Close it with \code{DBI::dbDisconnect(con, shutdown = TRUE)}.
#' @export
#' @examples
#' if (requireNamespace("duckdb.2.0.dev", quietly = TRUE) &&
#'     nzchar(system.file(package = "Rduckhts"))) {
#'   # Returns NULL on a preview engine this build does not support.
#'   con <- tryCatch(rducksassy_connect(driver = duckdb.2.0.dev::duckdb),
#'                   rducksassy_incompatible_host = function(e) NULL)
#'   if (!is.null(con)) {
#'     print(DBI::dbGetQuery(con, "SELECT * FROM sassy_grep('timeout', 'request timedout', 1)"))
#'     DBI::dbDisconnect(con, shutdown = TRUE)
#'   }
#' }
rducksassy_connect <- function(dbdir = ":memory:", read_only = FALSE,
                              driver = getOption("Rducksassy.driver")) {
  if (is.null(driver)) driver <- duckdb::duckdb
  driver_args <- list(
    dbdir = dbdir, read_only = read_only,
    config = list(allow_unsigned_extensions = "true",
                  autoinstall_known_extensions = "false",
                  autoload_known_extensions = "false")
  )
  supported <- names(formals(driver))
  if ("shared_home" %in% supported) driver_args$shared_home <- FALSE
  if ("allow_extensions" %in% supported) driver_args$allow_extensions <- TRUE
  con <- DBI::dbConnect(do.call(driver, driver_args))
  loaded <- FALSE
  on.exit(if (!loaded) DBI::dbDisconnect(con, shutdown = TRUE))
  rducksassy_load(con)
  loaded <- TRUE
  con
}

#' Load Ducksassy and its SQL bindings
#'
#' Loads the package-built DuckHTS and Ducksassy extensions into an existing
#' DuckDB connection. The host must support C API v2 and permit unsigned extensions.
#' Install the suggested \code{Rduckhts} package to supply its extension files;
#' its R namespace is not loaded.
#'
#' The C API v2 preview is not stable between DuckDB engine commits, so the
#' extension only loads into the engines it was built for. Other engines raise
#' an error of class \code{rducksassy_incompatible_host}. Set
#' \code{options(Rducksassy.allow_untested_host = TRUE)} to load anyway, at the
#' risk of crashing the R session.
#'
#' @param con An existing DuckDB DBI connection with C API v2 support.
#' @return Invisibly, the supplied connection.
#' @export
rducksassy_load <- function(con) {
  # Load the packaged native extension without importing a second DBI driver.
  duckhts <- system.file("duckhts_extension", "build", "duckhts.duckdb_extension",
                         package = "Rduckhts")
  if (!nzchar(duckhts)) {
    stop("Install Rduckhts to supply the DuckHTS extension required by this helper.", call. = FALSE)
  }
  extension <- system.file("libs", .Platform$r_arch, "ducksassy.duckdb_extension",
                           package = "Rducksassy", mustWork = TRUE)
  # The C API v2 preview changes its function table between engine commits;
  # loading into an unmatched engine can crash the R session.
  host <- DBI::dbGetQuery(con, "SELECT source_id FROM pragma_version()")$source_id
  supported <- readLines(system.file("host_revisions", package = "Rducksassy", mustWork = TRUE))
  if (!substr(host, 1L, 10L) %in% supported &&
      !isTRUE(getOption("Rducksassy.allow_untested_host"))) {
    stop(structure(class = c("rducksassy_incompatible_host", "error", "condition"), list(
      message = paste0(
        "This DuckDB engine (", host, ") is not one Ducksassy was built for (",
        paste(supported, collapse = ", "), "). The C API v2 preview is not stable ",
        "between engine commits, so loading could crash R. Install the matching ",
        "duckdb.2.0.dev, or set options(Rducksassy.allow_untested_host = TRUE) to try anyway."),
      call = NULL)))
  }
  tryCatch(
    DBI::dbExecute(con, paste("LOAD", DBI::dbQuoteString(con, extension))),
    error = function(error) stop("Could not load Ducksassy; the host must support DuckDB C API v2.\n",
                                 conditionMessage(error), call. = FALSE)
  )
  DBI::dbExecute(con, "SET GLOBAL lambda_syntax='ENABLE_SINGLE_ARROW'")
  DBI::dbExecute(con, paste("LOAD", DBI::dbQuoteString(con, duckhts)))
  bindings <- system.file("sql", "ducksassy.sql", package = "Rducksassy", mustWork = TRUE)
  DBI::dbExecute(con, paste(readLines(bindings, warn = FALSE), collapse = "\n"))
  invisible(con)
}
