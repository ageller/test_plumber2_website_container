# Unit tests for app/R/security.R and the SECRET_KEY rules in app/R/config.R
# (no server).

source(file.path(project_root, "app", "R", "security.R"), local = TRUE)
source(file.path(project_root, "app", "R", "config.R"), local = TRUE)

key <- "unit-test-key-0123456789abcdef0123456789"

test_that("a signed session cookie round-trips", {
  session <- list(csrf_token = new_csrf_token())
  cookie <- sign_session(session, key)
  expect_match(cookie, "^[A-Za-z0-9_-]+\\.[0-9a-f]{64}$")  # cookie-safe characters only
  expect_equal(verify_session(cookie, key), session)
})

test_that("tampered, forged, and malformed cookies are rejected", {
  cookie <- sign_session(list(csrf_token = new_csrf_token()), key)
  parts <- strsplit(cookie, ".", fixed = TRUE)[[1]]

  # A different payload with the original signature.
  forged_payload <- base64url_encode('{"csrf_token":"attacker"}')
  expect_null(verify_session(paste0(forged_payload, ".", parts[2]), key))
  # The original payload with a changed signature.
  flipped <- chartr("0123456789abcdef", "123456789abcdef0", parts[2])
  expect_null(verify_session(paste0(parts[1], ".", flipped), key))
  # Signed with a different key.
  expect_null(verify_session(sign_session(list(csrf_token = "x"), "another-key"), key))
  # Not a cookie at all.
  for (bad in list(NULL, NA_character_, "", "no-dot", "a.b.c", c(cookie, cookie))) {
    expect_null(verify_session(bad, key))
  }
})

test_that("CSRF tokens are random 64-character hex strings", {
  token <- new_csrf_token()
  expect_match(token, "^[0-9a-f]{64}$")
  expect_false(identical(token, new_csrf_token()))
})

test_that("the constant-time comparison works", {
  token <- new_csrf_token()
  expect_true(constant_time_equal(token, token))
  expect_false(constant_time_equal(token, new_csrf_token()))
  expect_false(constant_time_equal(token, substr(token, 1, 63)))
  expect_false(constant_time_equal("", ""))
  expect_false(constant_time_equal(NULL, token))
  expect_false(constant_time_equal(token, NA_character_))
  expect_false(constant_time_equal(token, c(token, token)))
})

# A request as plumber2 would see it, coming from `remote` with these headers.
fake_request <- function(headers = list(), remote = "172.18.0.3") {
  rook <- fiery::fake_request("http://localhost:5000/", headers = headers, remote_address = remote)
  reqres::Request$new(rook)
}

test_that("with TRUST_PROXY=1, one proxy hop is trusted", {
  request <- fake_request(list(
    # The client forged the first address. nginx appended the real one.
    X_Forwarded_For = "203.0.113.66, 198.51.100.7",
    X_Forwarded_Proto = "https"
  ))
  expect_equal(request_origin(request, trust_proxy = TRUE), list(ip = "198.51.100.7", scheme = "https"))
})

test_that("with TRUST_PROXY=0, proxy headers are ignored", {
  request <- fake_request(list(X_Forwarded_For = "198.51.100.7", X_Forwarded_Proto = "https"))
  expect_equal(request_origin(request, trust_proxy = FALSE), list(ip = "172.18.0.3", scheme = "http"))
})

test_that("without proxy headers, the direct connection is used either way", {
  expect_equal(request_origin(fake_request(), trust_proxy = TRUE), list(ip = "172.18.0.3", scheme = "http"))
})

test_that("production refuses a missing, placeholder, or short SECRET_KEY", {
  expect_error(check_secret_key("", development = FALSE), "SECRET_KEY")
  expect_error(check_secret_key("change-me", development = FALSE), "SECRET_KEY")
  expect_error(check_secret_key(strrep("x", 31), development = FALSE), "SECRET_KEY")
  expect_equal(check_secret_key(strrep("x", 32), development = FALSE), strrep("x", 32))
})

test_that("development replaces a missing SECRET_KEY with a random one", {
  expect_message(dev_key <- check_secret_key("", development = TRUE), "SECRET_KEY")
  expect_match(dev_key, "^[0-9a-f]{64}$")
  expect_equal(check_secret_key("short", development = TRUE), "short")
})
