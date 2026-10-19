# Form questions and server-side validation, as pure functions.
#
# validate_submission() takes the parsed form body (a named list of character
# vectors) and returns list(values = ..., errors = ...):
#   - errors is an empty list when the submission is valid. Then values holds
#     the cleaned answers, ready for insert_submission().
#   - otherwise errors is a named list with one message per problem field, and
#     values echoes what the user sent, so the form can be shown again with
#     their input kept.

LANGUAGES <- c("Python", "R", "Julia", "JavaScript", "Other")
EXPERIENCE_LEVELS <- 1:5
EXPERIENCE_LABELS <- c("1" = "never used", "5" = "use daily")
ENVIRONMENTS <- c("Laptop", "Local server", "AWS", "Azure", "Other")
NAME_MAX <- 80
COMMENTS_MAX <- 500

EMPTY_FORM <- list(
  name = "",
  language = "",
  container_experience = "",
  environments = character(),
  comments = ""
)

# A field that should hold one value. A missing field becomes "", and if a
# field is sent more than once, only the first value counts.
single_value <- function(form, key) {
  value <- form[[key]]
  if (length(value) == 0 || is.na(value[[1]])) {
    return("")
  }
  value <- as.character(value[[1]])
  # Replace bytes that are not valid UTF-8, so nchar() and trimws() cannot fail.
  if (!validUTF8(value)) {
    value <- iconv(value, "UTF-8", "UTF-8", sub = "?")
  }
  value
}

validate_submission <- function(form) {
  values <- list(
    name = trimws(single_value(form, "name")),
    language = single_value(form, "language"),
    container_experience = single_value(form, "container_experience"),
    # Each ticked checkbox arrives as a repeated "environments" key in the
    # URL-encoded body. The form parser collects them into one character vector.
    environments = as.character(unlist(form[["environments"]])),
    # Browsers send newlines as \r\n but count them as one character.
    comments = trimws(gsub("\r\n", "\n", single_value(form, "comments"), fixed = TRUE))
  )
  errors <- list()

  if (nchar(values$name) > NAME_MAX) {
    errors$name <- paste0("Name must be ", NAME_MAX, " characters or fewer.")
  }
  if (!values$language %in% LANGUAGES) {
    errors$language <- "Choose a language from the list."
  }
  if (!values$container_experience %in% as.character(EXPERIENCE_LEVELS)) {
    errors$container_experience <- "Choose a rating from 1 to 5."
  }
  if (length(values$environments) == 0) {
    errors$environments <- "Choose at least one environment."
  } else if (!all(values$environments %in% ENVIRONMENTS)) {
    errors$environments <- "Choose environments from the list only."
  }
  if (nchar(values$comments) > COMMENTS_MAX) {
    errors$comments <- paste0("Comments must be ", COMMENTS_MAX, " characters or fewer.")
  }

  if (length(errors) == 0) {
    values$container_experience <- as.integer(values$container_experience)
    # Store environments in the fixed list order, without duplicates.
    values$environments <- ENVIRONMENTS[ENVIRONMENTS %in% values$environments]
  }
  list(values = values, errors = errors)
}
