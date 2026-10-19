# SQLite helpers: connections, pragmas, and queries.
#
# Why SQLite is acceptable for this demo: everything runs on one host, the
# write volume is tiny, and the whole database is one file in a named Docker
# volume. WAL mode plus a busy timeout lets several R processes share it:
# readers do not block each other or the writer, and a writer waits its turn
# (up to 5 seconds) instead of failing.
#
# This works with several replicas only because they all run on the same
# host and see the same local filesystem. SQLite's file locking is not
# reliable on a network file share (for example AWS EFS or Azure Files), so
# never put the database file on one.
#
# What would change for a real project: store data in a managed database
# (for example PostgreSQL run by a cloud provider or central IT) or send it to
# an API such as REDCap. Either one gives you backups, access control, and
# audit trails that a file in a volume does not, and lets the app scale past
# one host.

# Open a connection with the settings every connection must have.
db_connect <- function(path) {
  # synchronous = NULL stops RSQLite from running its own PRAGMA while
  # connecting, before busy_timeout is set (that fails with "database is
  # locked" when another replica is writing). It is set below instead.
  con <- DBI::dbConnect(RSQLite::SQLite(), path, synchronous = NULL)
  tryCatch(
    {
      # busy_timeout comes first, so the statements after it (and every query
      # on this connection) wait for a lock held by another replica instead of
      # failing immediately.
      DBI::dbExecute(con, "PRAGMA busy_timeout=5000;")
      DBI::dbGetQuery(con, "PRAGMA journal_mode=WAL;")
      # NORMAL is the recommended setting for WAL mode: safe against
      # corruption, and faster than FULL.
      DBI::dbExecute(con, "PRAGMA synchronous=NORMAL;")
      DBI::dbExecute(con, "PRAGMA foreign_keys=ON;")
    },
    error = function(e) {
      DBI::dbDisconnect(con)
      stop(e)
    }
  )
  con
}

# Open a connection, pass it to fn, and always close it afterwards, even if
# fn fails. Handlers use this, so every request gets its own connection and
# no connection outlives a request.
with_db <- function(path, fn) {
  con <- db_connect(path)
  on.exit(DBI::dbDisconnect(con), add = TRUE)
  fn(con)
}

# Create the database file and table if needed. Safe to run on every start.
init_db <- function(path, schema_file) {
  dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
  schema <- paste(readLines(schema_file, warn = FALSE), collapse = "\n")
  with_db(path, function(con) DBI::dbExecute(con, schema))
  invisible(TRUE)
}

# Save one validated submission (see validate_submission()).
insert_submission <- function(con, values) {
  DBI::dbExecute(
    con,
    "INSERT INTO submissions
       (created_at, name, language, container_experience, environments, comments)
     VALUES (?, ?, ?, ?, ?, ?)",
    params = list(
      format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
      if (values$name == "") NA_character_ else values$name,
      values$language,
      values$container_experience,
      as.character(jsonlite::toJSON(values$environments)),
      if (values$comments == "") NA_character_ else values$comments
    )
  )
}

# Everything the results page needs. Each count is a data frame with the
# columns "choice" and "n", covering only the choices someone picked.
get_results <- function(con) {
  list(
    total = DBI::dbGetQuery(con, "SELECT COUNT(*) AS n FROM submissions")$n,
    languages = DBI::dbGetQuery(
      con,
      "SELECT language AS choice, COUNT(*) AS n FROM submissions GROUP BY language"
    ),
    experience = DBI::dbGetQuery(
      con,
      "SELECT container_experience AS choice, COUNT(*) AS n
         FROM submissions GROUP BY container_experience"
    ),
    # Each row stores a JSON array; json_each turns it into one row per item.
    environments = DBI::dbGetQuery(
      con,
      "SELECT json_each.value AS choice, COUNT(*) AS n
         FROM submissions, json_each(submissions.environments)
         GROUP BY json_each.value"
    ),
    recent = DBI::dbGetQuery(
      con,
      "SELECT created_at, name, language, container_experience, environments, comments
         FROM submissions ORDER BY id DESC LIMIT 10"
    )
  )
}
