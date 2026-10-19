# Two server processes sharing one SQLite file stand in for two replicas
# sharing the survey_data volume in docker-compose.yml.

test_that("two replicas sharing one database save every concurrent submission exactly once", {
  database_path <- tempfile(fileext = ".db")

  # Start both at the same time, like Compose starting replicas, so they also
  # create the schema concurrently.
  replicas <- list(
    start_server(database_path = database_path, wait = FALSE),
    start_server(database_path = database_path, wait = FALSE)
  )
  withr::defer(lapply(replicas, stop_server))
  lapply(replicas, wait_until_healthy)

  # One browser session, started on replica 1 and then used on both. This
  # works because the session lives in a signed cookie, not in R's memory.
  session <- open_form(replicas[[1]])

  n <- 60
  names <- sprintf("concurrent-%02d", seq_len(n))
  requests <- lapply(seq_len(n), function(i) {
    replica <- replicas[[(i - 1) %% 2 + 1]]  # alternate between the replicas
    submit_request(replica, session, valid_answers(name = names[i]))
  })
  responses <- httr2::req_perform_parallel(
    requests, on_error = "continue", max_active = 20, progress = FALSE
  )

  ok <- vapply(responses, function(r) inherits(r, "httr2_response") && httr2::resp_status(r) == 303, logical(1))
  expect_true(all(ok), info = paste(sum(!ok), "of", n, "requests failed"))

  rows <- saved_submissions(replicas[[1]])
  expect_equal(nrow(rows), n)
  expect_setequal(rows$name, names)
  expect_false(anyDuplicated(rows$name) > 0)

  logs <- paste(vapply(replicas, server_log, character(1)), collapse = "\n")
  expect_no_match(logs, "database is locked")
  expect_no_match(logs, "\\[error\\]")
  # Both replicas did part of the work.
  for (replica in replicas) {
    expect_match(server_log(replica), "POST / 303")
  }
})
