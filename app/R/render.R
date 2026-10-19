# whisker (Mustache) template helpers.
#
# Escaping: {{value}} escapes &, <, >, and " (the equivalent of Jinja's
# autoescaping), so user input is always inserted with double braces. Triple
# braces {{{value}}} insert HTML unescaped. They are used only for HTML that
# our own templates already rendered (the page body inside base.html). whisker
# does not escape single quotes, so templates always quote attributes with
# double quotes. Never build HTML from user input with paste() or glue.

# Template text, filled in by init_templates() at startup.
templates <- new.env(parent = emptyenv())

read_text_file <- function(path) {
  paste(readLines(path, warn = FALSE, encoding = "UTF-8"), collapse = "\n")
}

init_templates <- function(dir, reload) {
  templates$dir <- dir
  templates$reload <- reload
  templates$cache <- list()
  for (file in list.files(dir, pattern = "\\.html$")) {
    templates$cache[[sub("\\.html$", "", file)]] <- read_text_file(file.path(dir, file))
  }
}

get_template <- function(name) {
  # Development (reload = TRUE): read the file from disk on every request, so
  # template edits show up on a browser refresh without restarting R.
  # Production: use the copy read once at startup.
  if (templates$reload) {
    read_text_file(file.path(templates$dir, paste0(name, ".html")))
  } else {
    templates$cache[[name]]
  }
}

# Render templates/<name>.html, then place it inside base.html.
render_page <- function(name, data, title, footer) {
  body <- whisker::whisker.render(get_template(name), data)
  whisker::whisker.render(get_template("base"), c(list(title = title, body = body), footer))
}

# ---- Data for the templates ------------------------------------------------
# Mustache has no logic, so the templates get plain lists with flags such as
# "selected" or "checked" already worked out. whisker treats FALSE, NULL, and
# empty vectors as false, but "" and 0 as true.

form_page_data <- function(values, errors, csrf_token) {
  list(
    csrf_token = csrf_token,
    errors = errors,
    has_errors = length(errors) > 0,
    has_field_errors = length(setdiff(names(errors), "form")) > 0,
    name = values$name,
    comments = values$comments,
    name_max = NAME_MAX,
    comments_max = COMMENTS_MAX,
    languages = lapply(LANGUAGES, function(language) {
      list(value = language, selected = identical(values$language, language))
    }),
    levels = lapply(EXPERIENCE_LEVELS, function(level) {
      list(
        value = level,
        label = experience_label(level),
        checked = identical(as.character(values$container_experience), as.character(level)),
        first = level == EXPERIENCE_LEVELS[1]
      )
    }),
    environments = lapply(ENVIRONMENTS, function(environment) {
      list(value = environment, checked = environment %in% values$environments)
    })
  )
}

results_page_data <- function(results) {
  recent <- results$recent
  list(
    total = results$total,
    languages = count_rows(results$languages, LANGUAGES),
    experience = lapply(count_rows(results$experience, EXPERIENCE_LEVELS), function(row) {
      c(row, label = experience_label(row$choice))
    }),
    environments = count_rows(results$environments, ENVIRONMENTS),
    has_recent = nrow(recent) > 0,
    recent = lapply(seq_len(nrow(recent)), function(i) {
      list(
        created_at = sub("T", " ", sub("Z$", "", recent$created_at[i])),
        name = if (is.na(recent$name[i])) "anonymous" else recent$name[i],
        language = recent$language[i],
        container_experience = recent$container_experience[i],
        environments = paste(jsonlite::fromJSON(recent$environments[i]), collapse = ", "),
        comments = if (is.na(recent$comments[i])) "" else recent$comments[i]
      )
    })
  )
}

# One row per possible choice, in the fixed order, including choices that
# nobody picked yet (count 0).
count_rows <- function(counts, choices) {
  lapply(choices, function(choice) {
    n <- counts$n[as.character(counts$choice) == as.character(choice)]
    list(choice = choice, n = if (length(n)) n else 0L)
  })
}

# "never used" and "use daily" for ratings 1 and 5, FALSE (no label) otherwise.
experience_label <- function(choice) {
  label <- EXPERIENCE_LABELS[as.character(choice)]
  if (is.na(label)) FALSE else unname(label)
}
