# Session cookie, CSRF token, and proxy-aware request details.
#
# Sessions are stateless on the server: everything a session needs (here,
# only the CSRF token) lives in a cookie signed with HMAC-SHA256 using
# SECRET_KEY. The browser can read the cookie but cannot change it without
# breaking the signature. Because no session lives in R's memory, any replica
# can handle any request (see nginx/default.conf).
#
# plumber2 0.2.0 has a built-in encrypted session cookie (api_session_cookie),
# but it fixes the Secure flag once at startup. This app decides Secure per
# request, from X-Forwarded-Proto behind nginx, so it uses these small
# helpers instead.

SESSION_COOKIE_NAME <- "survey_session"

# ---- Signed cookie values --------------------------------------------------
# A cookie value looks like <payload>.<signature>, where payload is the
# session as JSON in base64url, and signature is the hex HMAC-SHA256 of payload.

# base64url is base64 with "-" and "_" instead of "+" and "/", and without
# "=" padding, so it is safe in a cookie value without further encoding.
base64url_encode <- function(text) {
  encoded <- openssl::base64_encode(charToRaw(enc2utf8(text)))
  chartr("+/", "-_", gsub("=", "", encoded, fixed = TRUE))
}

base64url_decode <- function(text) {
  padding <- strrep("=", (4 - nchar(text) %% 4) %% 4)
  rawToChar(openssl::base64_decode(paste0(chartr("-_", "+/", text), padding)))
}

hmac_sha256 <- function(text, key) {
  as.character(openssl::sha256(text, key = key))
}

sign_session <- function(session, key) {
  payload <- base64url_encode(jsonlite::toJSON(session, auto_unbox = TRUE))
  paste0(payload, ".", hmac_sha256(payload, key))
}

# Return the session (a list) if the cookie value is intact, otherwise NULL.
# Missing, malformed, and tampered cookies are all treated the same way.
verify_session <- function(cookie, key) {
  if (!is.character(cookie) || length(cookie) != 1 || is.na(cookie)) {
    return(NULL)
  }
  parts <- strsplit(cookie, ".", fixed = TRUE)[[1]]
  if (length(parts) != 2) {
    return(NULL)
  }
  if (!constant_time_equal(hmac_sha256(parts[1], key), parts[2])) {
    return(NULL)
  }
  tryCatch(jsonlite::fromJSON(base64url_decode(parts[1])), error = function(e) NULL)
}

# Compare two strings without returning early at the first difference, so the
# time taken does not reveal how much of a guessed token or signature was right.
constant_time_equal <- function(a, b) {
  if (!is.character(a) || !is.character(b) || length(a) != 1 || length(b) != 1 ||
      is.na(a) || is.na(b) || nchar(a) == 0) {
    return(FALSE)
  }
  a <- charToRaw(a)
  b <- charToRaw(b)
  if (length(a) != length(b)) {
    return(FALSE)
  }
  sum(as.integer(xor(a, b))) == 0
}

# ---- CSRF protection -------------------------------------------------------
# One random token per session, kept in the signed session cookie and repeated
# as a hidden form field. A POST must send both, and they must match.

new_csrf_token <- function() {
  paste(openssl::rand_bytes(32), collapse = "")
}

# Return this visitor's CSRF token. If the request has no valid session
# cookie, start a new session: create a token and set the cookie.
csrf_token_for <- function(request, response, key, secure) {
  session <- verify_session(request$cookies[[SESSION_COOKIE_NAME]], key)
  token <- session$csrf_token
  if (is.character(token) && length(token) == 1 && grepl("^[0-9a-f]{64}$", token)) {
    return(token)
  }
  token <- new_csrf_token()
  response$set_cookie(
    SESSION_COOKIE_NAME,
    sign_session(list(csrf_token = token), key),
    encode = FALSE,  # the value is already cookie-safe
    path = "/",
    http_only = TRUE,
    same_site = "Lax",
    secure = secure
  )
  token
}

csrf_token_is_valid <- function(request, submitted, key) {
  session <- verify_session(request$cookies[[SESSION_COOKIE_NAME]], key)
  constant_time_equal(session$csrf_token, submitted)
}

# ---- Proxy awareness -------------------------------------------------------
# Return the client IP and scheme ("http" or "https") of a request.
#
# With TRUST_PROXY=1 (Rungs 2 and 3, behind nginx) the app trusts exactly one
# proxy hop. The client IP is the LAST address in X-Forwarded-For, the one
# nginx added. Anything before it came from the client and could be forged.
# The scheme comes from X-Forwarded-Proto, which nginx always overwrites.
#
# With TRUST_PROXY=0 (Rung 1, the app reached directly) both headers are
# ignored, and the direct connection is used instead.
#
# This plays the role of Werkzeug's ProxyFix in the Flask prototype. reqres
# (under plumber2) has a "trust" switch, but it takes the FIRST address in
# X-Forwarded-For, which the client controls, so it is left off.
request_origin <- function(request, trust_proxy) {
  ip <- request$ip            # the address of the direct connection
  scheme <- request$protocol  # always "http" here: R does not serve TLS itself
  if (trust_proxy) {
    forwarded_for <- request$get_header("X-Forwarded-For")
    if (length(forwarded_for) > 0) {
      hops <- trimws(unlist(strsplit(forwarded_for, ",", fixed = TRUE)))
      ip <- hops[length(hops)]
    }
    forwarded_proto <- request$get_header("X-Forwarded-Proto")
    if (length(forwarded_proto) > 0) {
      scheme <- tolower(trimws(forwarded_proto[length(forwarded_proto)]))
    }
  }
  list(ip = ip, scheme = scheme)
}
