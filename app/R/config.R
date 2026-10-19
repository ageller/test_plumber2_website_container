# Read and check configuration from environment variables.
#
# All configuration comes from the environment (see .env.example), with the
# same variable names in every environment. read_config() stops with a clear
# message if a setting is unusable, so a misconfigured container fails at
# startup instead of misbehaving later.

# The value shipped in .env.example. Production refuses to start with it.
PLACEHOLDER_SECRET_KEY <- "change-me"
MIN_SECRET_KEY_LENGTH <- 32

read_config <- function() {
  app_env <- Sys.getenv("APP_ENV", "production")
  if (!app_env %in% c("production", "development")) {
    stop("APP_ENV must be 'production' or 'development', not '", app_env, "'.", call. = FALSE)
  }

  trust_proxy <- Sys.getenv("TRUST_PROXY", "0")
  if (!trust_proxy %in% c("0", "1")) {
    stop("TRUST_PROXY must be 0 or 1, not '", trust_proxy, "'.", call. = FALSE)
  }

  port <- suppressWarnings(as.integer(Sys.getenv("PORT", "8000")))
  if (is.na(port)) {
    stop("PORT must be a whole number.", call. = FALSE)
  }

  development <- app_env == "development"
  list(
    app_env = app_env,
    development = development,
    secret_key = check_secret_key(Sys.getenv("SECRET_KEY"), development),
    database_path = Sys.getenv("DATABASE_PATH", "/data/survey.db"),
    trust_proxy = trust_proxy == "1",
    port = port
  )
}

# Refuse to start in production without a real SECRET_KEY. The message never
# includes the key itself.
check_secret_key <- function(key, development) {
  if (development) {
    if (key == "") {
      # Development only: a throwaway key so sessions and CSRF still work.
      message("SECRET_KEY is not set. Using a random key for this development run only.")
      key <- paste(openssl::rand_bytes(32), collapse = "")
    }
    return(key)
  }
  if (key == "" || key == PLACEHOLDER_SECRET_KEY || nchar(key) < MIN_SECRET_KEY_LENGTH) {
    stop(
      "SECRET_KEY is missing, shorter than ", MIN_SECRET_KEY_LENGTH,
      " characters, or still set to the example placeholder. ",
      "Set a real random value in .env before starting in production mode.",
      call. = FALSE
    )
  }
  key
}
