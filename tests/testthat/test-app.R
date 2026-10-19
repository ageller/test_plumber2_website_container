# Tests against a running server (production mode, temporary database).
# One server is shared by the tests in this file and stopped at its end.

server <- local_server()

test_that("/healthz returns 200 and names the instance", {
  response <- httr2::req_perform(app_request(server, "/healthz"))
  expect_equal(httr2::resp_status(response), 200)
  body <- httr2::resp_body_json(response)
  expect_equal(body$status, "ok")
  expect_type(body$instance, "character")
})

test_that("the form sets a signed HttpOnly, SameSite=Lax session cookie", {
  session <- open_form(server)
  expect_equal(httr2::resp_status(session$response), 200)
  expect_match(session$token, "^[0-9a-f]{64}$")
  set_cookie <- httr2::resp_header(session$response, "set-cookie")
  expect_match(set_cookie, "^survey_session=")
  expect_match(set_cookie, "HttpOnly")
  expect_match(set_cookie, "SameSite=Lax")
  # Plain HTTP and TRUST_PROXY=0, so no Secure flag.
  expect_no_match(set_cookie, "Secure")
})

test_that("a valid submission is saved and redirects to /thanks", {
  before <- nrow(saved_submissions(server))
  response <- submit_form(server, open_form(server), valid_answers(name = "Valid Vera"))
  expect_equal(httr2::resp_status(response), 303)
  expect_equal(httr2::resp_header(response, "location"), "/thanks")

  rows <- saved_submissions(server)
  expect_equal(nrow(rows), before + 1)
  saved <- rows[nrow(rows), ]
  expect_equal(saved$name, "Valid Vera")
  expect_equal(saved$language, "R")
  expect_equal(saved$container_experience, 3L)
  expect_equal(saved$environments, '["Laptop","AWS"]')
  expect_match(saved$created_at, "^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}Z$")

  thanks <- httr2::req_perform(app_request(server, "/thanks"))
  expect_equal(httr2::resp_status(thanks), 200)
})

test_that("repeated environments keys in the form body are all saved", {
  answers <- valid_answers(name = "Repeat Ray", environments = c("Azure", "Laptop", "Azure"))
  response <- submit_form(server, open_form(server), answers)
  expect_equal(httr2::resp_status(response), 303)
  rows <- saved_submissions(server)
  expect_equal(rows$environments[nrow(rows)], '["Laptop","Azure"]')
})

test_that("invalid submissions are rejected and nothing is saved", {
  session <- open_form(server)
  bad_submissions <- list(
    "bad language" = list(session, valid_answers(language = "Cobol")),
    "rating too high" = list(session, valid_answers(container_experience = "6")),
    "rating too low" = list(session, valid_answers(container_experience = "0")),
    "unknown environment" = list(session, valid_answers(environments = c("AWS", "Mars"))),
    "oversize comment" = list(session, valid_answers(comments = strrep("x", 501))),
    "missing CSRF token" = list(modifyList(session, list(token = NULL)), valid_answers()),
    "wrong CSRF token" = list(modifyList(session, list(token = strrep("0", 64))), valid_answers()),
    "no session cookie" = list(modifyList(session, list(cookie = NULL)), valid_answers()),
    "forged session cookie" = list(
      modifyList(session, list(cookie = paste0("survey_session=", sub("\\.[0-9a-f]+$", ".00", sub("^survey_session=", "", session$cookie))))),
      valid_answers()
    )
  )
  before <- nrow(saved_submissions(server))
  for (case in names(bad_submissions)) {
    args <- bad_submissions[[case]]
    response <- submit_form(server, args[[1]], args[[2]])
    expect_equal(httr2::resp_status(response), 400, info = case)
    expect_match(httr2::resp_body_string(response), 'class="alert"', info = case)
  }
  expect_equal(nrow(saved_submissions(server)), before)
})

test_that("a rejected form is shown again with the user's input kept", {
  response <- submit_form(
    server, open_form(server),
    valid_answers(language = "Cobol", name = "Kept Kim", comments = "still here")
  )
  html <- httr2::resp_body_string(response)
  expect_match(html, 'value="Kept Kim"')
  expect_match(html, "still here")
  expect_match(html, "Choose a language from the list.")
})

test_that("/results shows the saved submissions, with HTML in user input escaped", {
  answers <- valid_answers(name = "<script>alert('x')</script>", comments = "<b>bold</b> & co")
  expect_equal(httr2::resp_status(submit_form(server, open_form(server), answers)), 303)

  response <- httr2::req_perform(app_request(server, "/results"))
  expect_equal(httr2::resp_status(response), 200)
  html <- httr2::resp_body_string(response)
  total <- nrow(saved_submissions(server))
  expect_match(html, paste0('class="total">', total, "<"))
  expect_match(html, "Valid Vera")
  expect_match(html, "&lt;script&gt;alert('x')&lt;/script&gt;", fixed = TRUE)
  expect_match(html, "&lt;b&gt;bold&lt;/b&gt; &amp; co", fixed = TRUE)
  expect_no_match(html, "<script>", fixed = TRUE)
  expect_no_match(html, "<b>bold", fixed = TRUE)
})

test_that("the stylesheet is served from app/static", {
  response <- httr2::req_perform(app_request(server, "/static/style.css"))
  expect_equal(httr2::resp_status(response), 200)
  expect_match(httr2::resp_content_type(response), "text/css")
  css <- paste(readLines(file.path(project_root, "app", "static", "style.css")), collapse = "\n")
  expect_equal(trimws(httr2::resp_body_string(response)), trimws(css))
  # Production: no Cache-Control: no-cache.
  expect_false(httr2::resp_header_exists(response, "cache-control"))

  missing <- httr2::req_perform(app_request(server, "/static/nope.css"))
  expect_equal(httr2::resp_status(missing), 404)
})

test_that("in development the stylesheet is sent with Cache-Control: no-cache", {
  dev_server <- local_server(APP_ENV = "development")
  response <- httr2::req_perform(app_request(dev_server, "/static/style.css"))
  expect_equal(httr2::resp_status(response), 200)
  expect_equal(httr2::resp_header(response, "cache-control"), "no-cache")
})

test_that("each request is logged as one access line, without form contents", {
  submit_form(server, open_form(server), valid_answers(name = "Secret Sam"))
  log <- server_log(server)
  expect_match(log, "\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}Z POST / 303 \\d+ms 127\\.0\\.0\\.1")
  expect_no_match(log, "Secret Sam")
  expect_no_match(log, TEST_SECRET_KEY, fixed = TRUE)
})

test_that("behind a proxy (TRUST_PROXY=1) the forwarded client and scheme are used", {
  proxied <- local_server(TRUST_PROXY = "1")
  response <- app_request(proxied, "/") |>
    httr2::req_headers(
      `X-Forwarded-For` = "203.0.113.66, 198.51.100.7",
      `X-Forwarded-Proto` = "https"
    ) |>
    httr2::req_perform()
  # Secure cookie, because the browser connected to the proxy over HTTPS.
  expect_match(httr2::resp_header(response, "set-cookie"), "Secure")
  html <- httr2::resp_body_string(response)
  expect_match(html, "<code>198.51.100.7</code>", fixed = TRUE)
  expect_match(html, "<code>https</code>", fixed = TRUE)

  # Without TRUST_PROXY the same headers are ignored.
  direct <- app_request(server, "/") |>
    httr2::req_headers(`X-Forwarded-For` = "198.51.100.7", `X-Forwarded-Proto` = "https") |>
    httr2::req_perform()
  expect_no_match(httr2::resp_header(direct, "set-cookie"), "Secure")
  expect_match(httr2::resp_body_string(direct), "<code>127.0.0.1</code>", fixed = TRUE)
})

test_that("production mode refuses to start with a missing, placeholder, or short SECRET_KEY", {
  for (bad_key in c("", "change-me", "too-short")) {
    result <- callr::rscript(
      file.path("app", "run.R"),
      env = server_env(httpuv::randomPort(), tempfile(fileext = ".db"), SECRET_KEY = bad_key),
      wd = project_root,
      fail_on_status = FALSE,
      show = FALSE,
      timeout = 60
    )
    expect_true(result$status != 0, info = bad_key)
    expect_match(result$stderr, "SECRET_KEY is missing, shorter than 32 characters, or still set to the example placeholder", info = bad_key)
  }
})
