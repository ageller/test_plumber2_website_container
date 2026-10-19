# Unit tests for app/R/validation.R (no server).

source(file.path(project_root, "app", "R", "validation.R"), local = TRUE)

# A form body as the form parser delivers it: a named list of character vectors.
form <- function(...) {
  utils::modifyList(
    list(
      name = "  Ada  ",
      language = "R",
      container_experience = "4",
      environments = c("AWS", "Laptop"),
      comments = "Fine."
    ),
    list(...)
  )
}

test_that("a valid form passes and the values are cleaned", {
  result <- validate_submission(form())
  expect_length(result$errors, 0)
  expect_equal(result$values$name, "Ada")
  expect_equal(result$values$language, "R")
  expect_identical(result$values$container_experience, 4L)
  # Stored in the fixed list order.
  expect_equal(result$values$environments, c("Laptop", "AWS"))
})

test_that("optional fields may be left out", {
  result <- validate_submission(form(name = NULL, comments = NULL))
  expect_length(result$errors, 0)
  expect_equal(result$values$name, "")
  expect_equal(result$values$comments, "")
})

test_that("an unknown language is rejected", {
  result <- validate_submission(form(language = "Cobol"))
  expect_named(result$errors, "language")
  expect_length(validate_submission(form(language = NULL))$errors, 1)
})

test_that("ratings outside 1 to 5 are rejected", {
  for (rating in c("0", "6", "-1", "3.5", "three", "")) {
    expect_named(validate_submission(form(container_experience = rating))$errors, "container_experience")
  }
  expect_length(validate_submission(form(container_experience = "1"))$errors, 0)
  expect_length(validate_submission(form(container_experience = "5"))$errors, 0)
})

test_that("unknown or missing environments are rejected", {
  expect_named(validate_submission(form(environments = c("AWS", "Mars")))$errors, "environments")
  expect_named(validate_submission(form(environments = NULL))$errors, "environments")
})

test_that("several environments are handled, without duplicates", {
  # Repeated checkbox keys arrive as one vector.
  result <- validate_submission(form(environments = c("Other", "AWS", "Laptop", "AWS")))
  expect_length(result$errors, 0)
  expect_equal(result$values$environments, c("Laptop", "AWS", "Other"))

  single <- validate_submission(form(environments = "Azure"))
  expect_equal(single$values$environments, "Azure")
})

test_that("oversize text is rejected", {
  expect_named(validate_submission(form(comments = strrep("x", 501)))$errors, "comments")
  expect_length(validate_submission(form(comments = strrep("x", 500)))$errors, 0)
  expect_named(validate_submission(form(name = strrep("x", 81)))$errors, "name")
  expect_length(validate_submission(form(name = strrep("x", 80)))$errors, 0)
})

test_that("browser newlines (\\r\\n) count as one character", {
  comments <- paste(rep("x", 250), collapse = "\r\n")  # 250 + 249 newlines
  result <- validate_submission(form(comments = comments))
  expect_length(result$errors, 0)
  expect_equal(nchar(result$values$comments), 499)
})

test_that("non-ASCII text is counted in characters, and invalid UTF-8 does not crash", {
  expect_length(validate_submission(form(name = strrep("é", 80)))$errors, 0)
  invalid <- rawToChar(as.raw(c(0x41, 0xff, 0x42)))
  expect_no_error(validate_submission(form(name = invalid, comments = invalid)))
})

test_that("invalid submissions keep the user's input for re-display", {
  result <- validate_submission(form(language = "Cobol", comments = "keep me"))
  expect_equal(result$values$comments, "keep me")
  expect_equal(result$values$environments, c("AWS", "Laptop"))
})
