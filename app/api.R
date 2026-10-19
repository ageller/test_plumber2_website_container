# plumber2 route definitions: survey form, thanks page, results summary, and
# health check. The stylesheet (/static/style.css) is served by api_statics()
# in app/run.R, not by a route here.
#
# app/run.R loads the helpers in app/R/ and creates `config` before plumber2
# parses this file, so every handler can use them.
#
# Every handler here finishes in a few milliseconds. That matters: one R
# process handles one request at a time, so a slow handler would block every
# other user whose request lands on the same replica. Slow work in a real
# project (a long model fit, a big report) would go into an asynchronous
# handler (plumber2's @async tag) or a background job, never into a plain
# handler like these.

# The container hostname. /healthz and the page footer show it, so you can
# see which replica answered.
INSTANCE <- Sys.info()[["nodename"]]

# Render a page with the "Request as seen by R" footer (a teaching aid: compare
# it in Rung 1, where R is reached directly, and Rung 2, behind nginx).
page <- function(request, template, title, data = list()) {
  origin <- request_origin(request, config$trust_proxy)
  footer <- list(
    client_ip = origin$ip,
    scheme = origin$scheme,
    host = request$host,
    forwarded_for = paste(request$get_header("X-Forwarded-For"), collapse = ", "),
    trust_proxy = if (config$trust_proxy) "yes" else "no",
    instance = INSTANCE
  )
  if (footer$forwarded_for == "") footer$forwarded_for <- "not sent"
  render_page(template, data, title, footer)
}

# TRUE when the visitor's browser connected over HTTPS (decides the Secure
# cookie flag). Always FALSE in this demo, which serves plain HTTP only.
is_https <- function(request) {
  request_origin(request, config$trust_proxy)$scheme == "https"
}

#* Show the survey form
#* @get /
#* @serializer html
function(request, response) {
  token <- csrf_token_for(request, response, config$secret_key, is_https(request))
  page(request, "form", "Container workflow survey", form_page_data(EMPTY_FORM, list(), token))
}

#* Validate and save a submission, then redirect to /thanks
#* @post /
#* @parser form
#* @serializer html
function(request, response, body) {
  result <- validate_submission(body)
  errors <- result$errors
  if (!csrf_token_is_valid(request, single_value(body, "csrf_token"), config$secret_key)) {
    errors$form <- paste(
      "This form could not be verified (the page may have expired).",
      "Please submit it again."
    )
  }
  if (length(errors) > 0) {
    token <- csrf_token_for(request, response, config$secret_key, is_https(request))
    response$status <- 400L
    return(page(
      request, "form", "Container workflow survey",
      form_page_data(result$values, errors, token)
    ))
  }

  with_db(config$database_path, function(con) insert_submission(con, result$values))

  # POST/redirect/GET: reloading the thanks page does not resubmit the form.
  response$status <- 303L
  response$set_header("Location", "/thanks")
  Break
}

#* Confirmation page
#* @get /thanks
#* @serializer html
function(request) {
  page(request, "thanks", "Thank you")
}

#* Totals, counts per answer, and the 10 most recent submissions
#* @get /results
#* @serializer html
function(request) {
  results <- with_db(config$database_path, get_results)
  page(request, "results", "Results", results_page_data(results))
}

#* Health check: 200 if the database answers SELECT 1, otherwise 503
#* @get /healthz
#* @serializer unboxedJSON
function(response, server) {
  # "instance" is a teaching aid: repeated calls through nginx show different
  # replicas answering. A real project might remove it, because it reveals
  # internal container names.
  ok <- tryCatch(
    with_db(config$database_path, function(con) {
      isTRUE(DBI::dbGetQuery(con, "SELECT 1 AS ok")$ok == 1)
    }),
    error = function(e) {
      server$log("error", paste("Health check failed:", conditionMessage(e)))
      FALSE
    }
  )
  if (!ok) {
    response$status <- 503L
    return(list(status = "error", instance = INSTANCE))
  }
  list(status = "ok", instance = INSTANCE)
}
