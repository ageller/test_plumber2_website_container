# Helpers for the tests: start and stop a real server with callr, and talk to
# it with httr2. testthat loads helper-*.R files before the tests and runs
# the tests with tests/testthat as the working directory.

project_root <- normalizePath(file.path("..", ".."))

# Long enough for production mode. Used only by these tests.
TEST_SECRET_KEY <- "test-only-secret-key-that-is-long-enough"

# Settings for a test server. Every variable the app reads is set explicitly,
# so the values from docker-compose.dev.yml (including the dev_data database)
# never leak into a test.
server_env <- function(port, database_path, ...) {
  vars <- c(
    APP_ENV = "production",
    SECRET_KEY = TEST_SECRET_KEY,
    DATABASE_PATH = database_path,
    TRUST_PROXY = "0",
    PORT = as.character(port)
  )
  overrides <- c(...)
  vars[names(overrides)] <- overrides
  c(callr::rcmd_safe_env(), vars)
}

# Start app/run.R in a background R process on a free port, with its own
# temporary database unless database_path is given. With wait = FALSE it
# returns at once; call wait_until_healthy() before sending requests.
start_server <- function(..., database_path = tempfile(fileext = ".db"), wait = TRUE) {
  port <- httpuv::randomPort()
  server <- list(
    url = paste0("http://127.0.0.1:", port),
    database_path = database_path,
    stdout = tempfile("server-", fileext = ".out"),
    stderr = tempfile("server-", fileext = ".err")
  )
  server$process <- callr::r_bg(
    function(root) {
      setwd(root)
      source(file.path("app", "run.R"))
    },
    args = list(root = project_root),
    env = server_env(port, database_path, ...),
    stdout = server$stdout,
    stderr = server$stderr,
    supervise = TRUE  # killed automatically if the test process dies
  )
  if (wait) wait_until_healthy(server)
  server
}

stop_server <- function(server) {
  server$process$kill()
}

# Start a server that is stopped automatically when the calling test (or test
# file, if called at the top level) finishes.
local_server <- function(..., .env = parent.frame()) {
  server <- start_server(...)
  withr::defer(stop_server(server), envir = .env)
  server
}

wait_until_healthy <- function(server, timeout = 30) {
  deadline <- Sys.time() + timeout
  while (Sys.time() < deadline) {
    if (!server$process$is_alive()) {
      stop("Test server exited early:\n", server_log(server))
    }
    status <- tryCatch(
      httr2::resp_status(httr2::req_perform(app_request(server, "/healthz"))),
      error = function(e) NA
    )
    if (identical(status, 200L)) {
      return(invisible(server))
    }
    Sys.sleep(0.2)
  }
  stop("Test server did not become healthy within ", timeout, " seconds:\n", server_log(server))
}

# Everything the server wrote to stdout and stderr so far.
server_log <- function(server) {
  read <- function(path) if (file.exists(path)) readLines(path, warn = FALSE) else character()
  paste(c(read(server$stdout), read(server$stderr)), collapse = "\n")
}

# A request that never throws on 4xx or 5xx and never follows redirects, so
# tests can check status codes and Location headers directly.
app_request <- function(server, path = "/") {
  httr2::request(paste0(server$url, path)) |>
    httr2::req_error(is_error = function(resp) FALSE) |>
    httr2::req_options(followlocation = FALSE) |>
    httr2::req_timeout(10)
}

# GET the form and keep what a browser keeps: the session cookie, and the
# CSRF token from the hidden form field.
open_form <- function(server) {
  response <- httr2::req_perform(app_request(server, "/"))
  html <- httr2::resp_body_string(response)
  list(
    response = response,
    cookie = sub(";.*$", "", httr2::resp_header(response, "set-cookie")),
    token = regmatches(html, regexec('name="csrf_token" value="([0-9a-f]+)"', html))[[1]][2]
  )
}

# A valid set of answers. Override fields with name = value, or drop a field
# with name = NULL.
valid_answers <- function(...) {
  utils::modifyList(
    list(
      name = "Test User",
      language = "R",
      container_experience = "3",
      environments = c("Laptop", "AWS"),
      comments = "Hello from the tests."
    ),
    list(...)
  )
}

# A POST of the form, built the way a browser sends it. Several values for one
# field (such as environments) become repeated keys:
# environments=Laptop&environments=AWS.
submit_request <- function(server, session, answers) {
  fields <- c(answers, list(csrf_token = session$token))
  request <- app_request(server, "/") |>
    httr2::req_body_form(!!!fields, .multi = "explode")
  if (!is.null(session$cookie)) {
    request <- httr2::req_headers(request, Cookie = session$cookie)
  }
  request
}

submit_form <- function(server, session, answers) {
  httr2::req_perform(submit_request(server, session, answers))
}

# The rows the server saved, read directly from its SQLite file.
saved_submissions <- function(server) {
  con <- DBI::dbConnect(RSQLite::SQLite(), server$database_path)
  on.exit(DBI::dbDisconnect(con))
  DBI::dbGetQuery(con, "SELECT * FROM submissions ORDER BY id")
}
