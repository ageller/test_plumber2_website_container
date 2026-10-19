# Entry point: read the configuration, prepare the database, build the API,
# and start the server. It plays the role of wsgi.py (plus gunicorn's logging
# settings) in the Flask prototype.
#
# Run it from the project root, which is the working directory (/app) in the
# image:
#   Rscript app/run.R
#
# One R process handles one request at a time. Several users are served at
# once by running several of these processes (Compose replicas) behind nginx.

options(warn = 1)  # print warnings as they happen, not at the end
suppressPackageStartupMessages(library(plumber2))

# Helpers: config.R, db.R, render.R, security.R, validation.R.
for (file in list.files(file.path("app", "R"), pattern = "\\.R$", full.names = TRUE)) {
  source(file)
}

# Stops with a clear message (and a non-zero exit status) if, for example,
# SECRET_KEY is unsafe in production.
config <- read_config()

init_db(config$database_path, file.path("app", "schema.sql"))
init_templates(file.path("app", "templates"), reload = config$development)

# ---- Logging ---------------------------------------------------------------

utc_time <- function(time = Sys.time()) {
  format(time, "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
}

# One access line per request on stdout, like gunicorn's access log:
#   2026-10-19T15:09:12Z GET /results 200 4ms 172.18.0.1
# Form contents, cookies, and the secret key are never logged.
log_access <- function(request, response, ...) {
  duration_ms <- 1000 * as.numeric(difftime(Sys.time(), request$start_time, units = "secs"))
  cat(
    sprintf(
      "%s %s %s %d %.0fms %s\n",
      utc_time(), toupper(request$method), request$path, as.integer(response$status),
      duration_ms, request_origin(request, config$trust_proxy)$ip
    ),
    file = stdout()
  )
}

# Everything else plumber2 (through fiery) reports. Errors and warnings go to
# stderr, other events such as "start" to stdout. Error details stay in the
# log: the browser only sees a plain "Internal Server Error" page. fiery's own
# access-log event ("request") is skipped, because log_access() writes that line.
log_event <- function(event, message, request = NULL, time = Sys.time(), ...) {
  if (event == "request") {
    return(invisible(NULL))
  }
  text <- if (inherits(message, "condition")) conditionMessage(message) else paste(message, collapse = " ")
  out <- if (event %in% c("error", "warning")) stderr() else stdout()
  cat(utc_time(time), " [", event, "] ", text, "\n", sep = "", file = out)
}

# ---- Build and start the API ----------------------------------------------

# doc_type = NULL: no generated API documentation pages. This is a website.
pa <- api(file.path("app", "api.R"), host = "0.0.0.0", port = config$port, doc_type = NULL)

# fiery (the server under plumber2) would otherwise set a "fiery_id" cookie on
# every response to tell clients apart. This app keeps no per-client state on
# the server, so it does not need one.
pa$set_client_id_converter(function(request) "")

pa <- api_logger(pa, logger = log_event)
pa <- api_on(pa, "after-request", log_access)

cat(
  utc_time(), " [config] APP_ENV=", config$app_env,
  " TRUST_PROXY=", as.integer(config$trust_proxy),
  " DATABASE_PATH=", config$database_path, "\n",
  sep = ""
)

# Blocks until the process is stopped. In the container, tini (the image's
# entrypoint) passes SIGTERM on to R, which then exits at once.
api_run(pa)
